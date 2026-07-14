import React, { useEffect, useState } from "react";
import { supabase } from "../supabase";
import { listParties } from "../lib/db";
import { currentFiscalYear } from "../lib/fiscalYear";
import { createBillWithPosting, refreshDocumentPaymentStatuses } from "../lib/posting";
import { cancelBillDocument, deleteDocumentDraft, postBillDraft, saveBillDraft } from "../lib/lifecycle";
import LifecycleActionModal from "../components/LifecycleActionModal";
import DocumentActivityModal from "../components/DocumentActivityModal";
import PaymentModal from "./PaymentModal";
import { useBusinessProfile } from "../lib/businessProfile";

const VAT_RATE = 13;
const blankLine = () => ({ itemId: "", description: "", quantity: "1", unit: "pcs", rate: "", vatRate: VAT_RATE });

// ── helpers ───────────────────────────────────────────────────
function calcAmount(l) { return (parseFloat(l.quantity)||0) * (parseFloat(l.rate)||0); }
function calcVat(l) { return calcAmount(l) * ((parseFloat(l.vatRate)||0)/100); }

// NOTE: bill creation now goes through createBillWithPosting()
// (see ../lib/posting.js), which inserts the bill AND its balanced
// purchase voucher (Dr Inventory Asset or Purchase Expense / Dr VAT / Cr Vendor) in
// one transaction. The old non-posting insert was removed.

async function fetchItems() {
  const { data } = await supabase.from("inventory_items").select("id,name,unit,cost_price,average_cost,current_stock,hsn_code,track_inventory,item_type").eq("is_active",true).order("name");
  return data || [];
}

async function listBills() {
  const { data, error } = await supabase
    .from("purchase_bills")
    .select("*, purchase_bill_lines(*)")
    .order("bill_date", { ascending: false });
  if (error) throw error;
  return data;
}

// ── Bill print view ───────────────────────────────────────────
function BillPrint({ bill, bizName, profile, onClose }) {
  return (
    <div className="print-overlay">
      <div className="print-actions no-print">
        <button className="btn" onClick={() => window.print()}>🖨 Print / Save PDF</button>
        <button className="link" onClick={onClose}>← Back</button>
      </div>
      <div className="invoice-paper">
        <div className="inv-header">
          <div>
            <div className="inv-biz-name">{bizName || "Your Business"}</div>
            {profile?.address && <div className="inv-biz-sub">{profile.address}{profile.city ? ", "+profile.city : ""}</div>}
            {profile?.pan_vat && <div className="inv-biz-sub">PAN/VAT: {profile.pan_vat}</div>}
            <div className="inv-biz-sub">Purchase Record</div>
          </div>
          <div className="inv-title-block">
            <div className="inv-title">PURCHASE BILL</div>
            <div className="inv-title-sub">खरिद बिल</div>
          </div>
        </div>

        <div className="inv-meta">
          <div className="inv-meta-left">
            <div><b>Vendor:</b></div>
            <div>{bill.vendor_name}</div>
            {bill.vendor_address && <div>{bill.vendor_address}</div>}
            {bill.vendor_pan && <div>PAN: {bill.vendor_pan}</div>}
          </div>
          <div className="inv-meta-right">
            <div><span>Bill No:</span><b>{bill.fiscal_year}-PB-{String(bill.bill_number).padStart(4,"0")}</b></div>
            <div><span>Date:</span><b>{bill.bill_date}</b></div>
            {bill.due_date && <div><span>Due:</span><b>{bill.due_date}</b></div>}
            {bill.vendor_bill_ref && <div><span>Vendor Ref:</span><b>{bill.vendor_bill_ref}</b></div>}
          </div>
        </div>

        <table className="inv-table">
          <thead>
            <tr><th>#</th><th>Description</th><th>Unit</th><th className="r">Qty</th><th className="r">Rate</th><th className="r">Amount</th><th className="r">VAT%</th><th className="r">VAT</th><th className="r">Total</th></tr>
          </thead>
          <tbody>
            {bill.purchase_bill_lines.map((l,i) => (
              <tr key={l.id}>
                <td>{i+1}</td><td>{l.description}</td><td>{l.unit}</td>
                <td className="r">{l.quantity}</td>
                <td className="r">{Number(l.rate).toLocaleString()}</td>
                <td className="r">{Number(l.amount).toLocaleString()}</td>
                <td className="r">{l.vat_rate}%</td>
                <td className="r">{Number(l.vat_amount).toLocaleString()}</td>
                <td className="r">{Number(l.line_total).toLocaleString()}</td>
              </tr>
            ))}
          </tbody>
          <tfoot>
            <tr><td colSpan={5}></td><td className="r"><b>Subtotal</b></td><td colSpan={2}></td><td className="r"><b>{Number(bill.subtotal).toLocaleString()}</b></td></tr>
            <tr><td colSpan={5}></td><td className="r"><b>Input VAT</b></td><td colSpan={2}></td><td className="r"><b>{Number(bill.vat_amount).toLocaleString()}</b></td></tr>
            <tr className="inv-total-row"><td colSpan={5}></td><td className="r"><b>TOTAL</b></td><td colSpan={2}></td><td className="r"><b>{Number(bill.total).toLocaleString()}</b></td></tr>
          </tfoot>
        </table>

        {bill.notes && <div className="inv-notes"><b>Notes:</b> {bill.notes}</div>}
        <div className="inv-footer">
          <div className="inv-sign"><div className="inv-sign-line"></div><div>Received by</div></div>
          <div className="inv-footer-note">Input VAT claimable against output VAT</div>
        </div>
      </div>
    </div>
  );
}

// ── Main Purchases page ───────────────────────────────────────
export default function Purchases() {
  const [bills, setBills] = useState([]);
  const [parties, setParties] = useState([]);
  const [items, setItems] = useState([]);
  const [loading, setLoading] = useState(true);
  const [showForm, setShowForm] = useState(false);
  const [printBill, setPrintBill] = useState(null);
  const [payModal, setPayModal] = useState(null);
  const [activityDoc, setActivityDoc] = useState(null);
  const [cancelDoc, setCancelDoc] = useState(null);
  const [editingDraftId, setEditingDraftId] = useState(null);
  const [err, setErr] = useState(null);
  const [busy, setBusy] = useState(false);
  const [filter, setFilter] = useState("all");
  const { profile } = useBusinessProfile();
  const bizName = profile?.biz_name || "";

  const emptyForm = () => ({
    fiscalYear: currentFiscalYear(),
    vendorId: "", vendorName: "", vendorAddress: "", vendorPan: "",
    vendorBillRef: "", billDate: new Date().toISOString().slice(0, 10),
    dueDate: "", notes: "",
  });
  const [form, setForm] = useState(emptyForm);
  const [lines, setLines] = useState([blankLine(), blankLine()]);

  const resetEditor = () => {
    setEditingDraftId(null);
    setForm(emptyForm());
    setLines([blankLine(), blankLine()]);
    setErr(null);
  };

  const load = async () => {
    setLoading(true);
    try {
      await refreshDocumentPaymentStatuses();
      const [billRows, partyRows, itemRows] = await Promise.all([listBills(), listParties(), fetchItems()]);
      setBills(billRows || []);
      setParties(partyRows || []);
      setItems(itemRows || []);
    } catch (error) {
      setErr(error.message);
    }
    setLoading(false);
  };

  useEffect(() => { load(); }, []);

  const selectVendor = (vendorId) => {
    const vendor = parties.find((party) => party.id === vendorId);
    if (vendor) {
      setForm((current) => ({
        ...current,
        vendorId,
        vendorName: vendor.accounts?.name || "",
        vendorAddress: vendor.address || "",
        vendorPan: vendor.pan_vat_number || "",
      }));
    } else {
      setForm((current) => ({ ...current, vendorId: "", vendorName: "", vendorAddress: "", vendorPan: "" }));
    }
  };

  const updateLine = (index, patch) => setLines((current) => current.map((line, lineIndex) => lineIndex === index ? { ...line, ...patch } : line));
  const addLine = () => setLines((current) => [...current, blankLine()]);
  const removeLine = (index) => setLines((current) => current.filter((_, lineIndex) => lineIndex !== index));
  const subtotal = lines.reduce((sum, line) => sum + calcAmount(line), 0);
  const vatTotal = lines.reduce((sum, line) => sum + calcVat(line), 0);
  const grandTotal = subtotal + vatTotal;

  const buildDocument = () => {
    if (!form.vendorName.trim()) throw new Error("Vendor name is required.");
    const validLines = lines.filter((line) => line.description.trim() && Number(line.quantity) > 0 && Number(line.rate) >= 0);
    if (validLines.length === 0) throw new Error("Add at least one valid line item.");
    const postLines = validLines.map((line) => ({
      item_id: line.itemId || null,
      hsn_code: items.find((item) => item.id === line.itemId)?.hsn_code || null,
      description: line.description.trim(),
      quantity: parseFloat(line.quantity) || 1,
      unit: line.unit || "pcs",
      rate: parseFloat(line.rate) || 0,
      amount: calcAmount(line),
      vat_rate: parseFloat(line.vatRate) || 0,
      vat_amount: calcVat(line),
      line_total: calcAmount(line) + calcVat(line),
    }));
    const header = {
      fiscal_year: form.fiscalYear,
      bill_date: form.billDate,
      due_date: form.dueDate || null,
      vendor_id: form.vendorId || null,
      vendor_name: form.vendorName.trim(),
      vendor_address: form.vendorAddress.trim() || null,
      vendor_pan: form.vendorPan.trim() || null,
      vendor_bill_ref: form.vendorBillRef.trim() || null,
      notes: form.notes.trim() || null,
    };
    return { header, postLines };
  };

  const persist = async (mode) => {
    setBusy(true);
    setErr(null);
    try {
      const { header, postLines } = buildDocument();
      let billId;
      if (mode === "draft") {
        billId = await saveBillDraft(header, postLines, editingDraftId);
      } else if (editingDraftId) {
        billId = await saveBillDraft(header, postLines, editingDraftId);
        await postBillDraft(billId);
      } else {
        billId = await createBillWithPosting(header, postLines);
      }
      resetEditor();
      setShowForm(false);
      await load();
      if (mode === "post") {
        const { data: bill, error } = await supabase
          .from("purchase_bills")
          .select("*, purchase_bill_lines(*)")
          .eq("id", billId)
          .single();
        if (error) throw error;
        setPrintBill(bill);
      }
    } catch (error) {
      setErr(error.message);
    }
    setBusy(false);
  };

  const editDraft = (bill) => {
    setEditingDraftId(bill.id);
    setForm({
      fiscalYear: bill.fiscal_year,
      vendorId: bill.vendor_id || "",
      vendorName: bill.vendor_name || "",
      vendorAddress: bill.vendor_address || "",
      vendorPan: bill.vendor_pan || "",
      vendorBillRef: bill.vendor_bill_ref || "",
      billDate: bill.bill_date,
      dueDate: bill.due_date || "",
      notes: bill.notes || "",
    });
    setLines((bill.purchase_bill_lines || []).map((line) => ({
      itemId: line.item_id || "",
      description: line.description || "",
      quantity: String(line.quantity ?? 1),
      unit: line.unit || "pcs",
      rate: String(line.rate ?? 0),
      vatRate: Number(line.vat_rate ?? VAT_RATE),
    })));
    setShowForm(true);
    setErr(null);
    window.scrollTo({ top: 0, behavior: "smooth" });
  };

  const postDraft = async (bill) => {
    setBusy(true);
    setErr(null);
    try {
      await postBillDraft(bill.id);
      await load();
    } catch (error) {
      setErr(error.message);
    }
    setBusy(false);
  };

  const removeDraft = async (bill) => {
    setBusy(true);
    setErr(null);
    try {
      await deleteDocumentDraft("bill", bill.id);
      if (editingDraftId === bill.id) {
        resetEditor();
        setShowForm(false);
      }
      await load();
    } catch (error) {
      setErr(error.message);
    }
    setBusy(false);
  };

  const lifecycleOf = (bill) => bill.document_status || (["cancelled", "credited", "draft"].includes(bill.status) ? bill.status : "posted");
  const filtered = bills.filter((bill) => {
    if (filter === "all") return true;
    if (["draft", "posted", "cancelled", "credited"].includes(filter)) return lifecycleOf(bill) === filter;
    return bill.status === filter;
  });
  const activeBills = bills.filter((bill) => lifecycleOf(bill) === "posted");
  const totalOutstanding = activeBills.reduce((sum, bill) => sum + Number(bill.outstanding_amount ?? bill.net_total ?? bill.total), 0);
  const totalPaid = activeBills.reduce((sum, bill) => sum + Number(bill.amount_paid || 0), 0);
  const totalVat = activeBills.reduce((sum, bill) => sum + Number(bill.vat_amount || 0), 0);

  if (payModal) return (
    <PaymentModal docType="bill" doc={payModal} onClose={() => setPayModal(null)} onSaved={() => { setPayModal(null); load(); }} />
  );
  if (printBill) return <BillPrint bill={printBill} bizName={bizName} profile={profile} onClose={() => setPrintBill(null)} />;

  return (
    <div className="panel">
      <div className="panel-head">
        <h2>Purchases (खरिद)</h2>
        <button className="btn" onClick={() => {
          if (showForm) resetEditor();
          setShowForm((current) => !current);
        }}>{showForm ? "Close Editor" : "+ New Bill"}</button>
      </div>

      <div className="stat-row">
        <div className="stat"><span style={{ color: "var(--rust)" }}>NPR {totalOutstanding.toLocaleString()}</span>Outstanding Bills</div>
        <div className="stat"><span>NPR {totalPaid.toLocaleString()}</span>Paid Bills</div>
        <div className="stat"><span>NPR {totalVat.toLocaleString()}</span>Input VAT</div>
        <div className="stat"><span>{bills.length}</span>Total Bills</div>
      </div>

      {showForm && (
        <form className="inv-form" onSubmit={(event) => { event.preventDefault(); persist("post"); }}>
          <b style={{ display: "block", marginBottom: 10 }}>{editingDraftId ? "Edit Purchase Draft" : "New Purchase Bill"}</b>
          <div className="settings-info-box" style={{ marginBottom: 12 }}>
            A draft does not change stock or the ledger. Posting is permanent; corrections must use cancellation or a debit note.
          </div>
          <div className="inv-form-top">
            <label className="fld">Fiscal Year <input value={form.fiscalYear} onChange={(event) => setForm((current) => ({ ...current, fiscalYear: event.target.value }))} disabled={Boolean(editingDraftId)} /></label>
            <label className="fld">Vendor
              <select value={form.vendorId} onChange={(event) => selectVendor(event.target.value)}>
                <option value="">Select or type below…</option>
                {parties.filter((party) => party.party_type === "vendor" || party.party_type === "both").map((party) => <option key={party.id} value={party.id}>{party.accounts?.name}</option>)}
              </select>
            </label>
            <label className="fld">Vendor Name <input placeholder="Vendor name" value={form.vendorName} onChange={(event) => setForm((current) => ({ ...current, vendorName: event.target.value }))} required /></label>
            <label className="fld">Vendor PAN <input placeholder="PAN/VAT number" value={form.vendorPan} onChange={(event) => setForm((current) => ({ ...current, vendorPan: event.target.value }))} /></label>
            <label className="fld">Vendor Address <input placeholder="Address" value={form.vendorAddress} onChange={(event) => setForm((current) => ({ ...current, vendorAddress: event.target.value }))} /></label>
            <label className="fld">Bill Date <input type="date" value={form.billDate} onChange={(event) => setForm((current) => ({ ...current, billDate: event.target.value }))} required /></label>
            <label className="fld">Due Date <input type="date" value={form.dueDate} onChange={(event) => setForm((current) => ({ ...current, dueDate: event.target.value }))} /></label>
            <label className="fld">Vendor Bill Ref# <input placeholder="Their invoice number" value={form.vendorBillRef} onChange={(event) => setForm((current) => ({ ...current, vendorBillRef: event.target.value }))} /></label>
          </div>

          <div style={{ overflowX: "auto" }}>
            <table className="tbl inv-lines-tbl">
              <thead><tr><th>Description</th><th>Unit</th><th className="num">Qty</th><th className="num">Rate</th><th className="num">Amount</th><th className="num">VAT%</th><th className="num">VAT</th><th className="num">Total</th><th /></tr></thead>
              <tbody>
                {lines.map((line, index) => (
                  <tr key={index}>
                    <td>
                      <select style={{ width: "100%", marginBottom: 3 }} value={line.itemId || ""} onChange={(event) => {
                        const item = items.find((entry) => entry.id === event.target.value);
                        if (item) updateLine(index, { itemId: item.id, description: item.name, unit: item.unit, rate: String(item.average_cost || item.cost_price) });
                        else updateLine(index, { itemId: "", description: "", unit: "pcs", rate: "" });
                      }}>
                        <option value="">— type below or pick item —</option>
                        {items.map((item) => <option key={item.id} value={item.id}>{item.name} (Stock: {Number(item.current_stock).toLocaleString()} {item.unit})</option>)}
                      </select>
                      <input placeholder="Description" value={line.description} onChange={(event) => updateLine(index, { description: event.target.value })} />
                    </td>
                    <td><input placeholder="pcs" value={line.unit} onChange={(event) => updateLine(index, { unit: event.target.value })} style={{ width: 50 }} /></td>
                    <td><input type="number" step="0.001" className="num-input" value={line.quantity} onChange={(event) => updateLine(index, { quantity: event.target.value })} /></td>
                    <td><input type="number" step="0.01" className="num-input" value={line.rate} onChange={(event) => updateLine(index, { rate: event.target.value })} /></td>
                    <td className="num">{calcAmount(line).toLocaleString()}</td>
                    <td><input type="number" step="0.01" className="num-input" value={line.vatRate} onChange={(event) => updateLine(index, { vatRate: event.target.value })} style={{ width: 55 }} /></td>
                    <td className="num">{calcVat(line).toLocaleString()}</td>
                    <td className="num">{(calcAmount(line) + calcVat(line)).toLocaleString()}</td>
                    <td>{lines.length > 1 && <button type="button" className="link" onClick={() => removeLine(index)}>✕</button>}</td>
                  </tr>
                ))}
              </tbody>
              <tfoot><tr><td colSpan={4} className="muted">Subtotal</td><td className="num"><b>{subtotal.toLocaleString()}</b></td><td /><td className="num"><b>{vatTotal.toLocaleString()}</b></td><td className="num"><b>{grandTotal.toLocaleString()}</b></td><td /></tr></tfoot>
            </table>
          </div>
          <button type="button" className="link" onClick={addLine}>+ Add line</button>
          <label className="fld" style={{ marginTop: 12 }}>Printed notes <input placeholder="Optional notes" value={form.notes} onChange={(event) => setForm((current) => ({ ...current, notes: event.target.value }))} /></label>
          {err && <p className="msg err">{err}</p>}
          <div style={{ display: "flex", gap: 10, flexWrap: "wrap", marginTop: 10 }}>
            <button type="button" className="ghost-btn" disabled={busy} onClick={() => persist("draft")}>{busy ? "Saving…" : "Save Draft"}</button>
            <button className="btn" disabled={busy}>{busy ? "Posting…" : "Post Bill"}</button>
          </div>
        </form>
      )}

      <div className="filter-tabs">
        {["all", "draft", "posted", "open", "partial", "overdue", "paid", "credited", "cancelled"].map((value) => (
          <button key={value} className={`filter-tab${filter === value ? " active" : ""}`} onClick={() => setFilter(value)}>{value.charAt(0).toUpperCase() + value.slice(1)}</button>
        ))}
      </div>

      {err && !showForm && <p className="msg err">{err}</p>}
      {loading ? <p className="note">Loading…</p> : filtered.length === 0 ? <p className="note">No bills found.</p> : (
        <div style={{ overflowX: "auto", marginTop: 8 }}>
          <table className="tbl">
            <thead><tr><th>Bill #</th><th>Date</th><th>Vendor</th><th>Lifecycle</th><th>Payment</th><th className="num">Paid</th><th className="num">Outstanding</th><th className="num">Net / Original</th><th /></tr></thead>
            <tbody>
              {filtered.map((bill) => {
                const lifecycle = lifecycleOf(bill);
                return (
                  <tr key={bill.id}>
                    <td>{bill.fiscal_year}-PB-{String(bill.bill_number).padStart(4, "0")}</td>
                    <td>{bill.bill_date}</td>
                    <td>{bill.vendor_name}</td>
                    <td><span className={`status-${lifecycle}`}>{lifecycle}</span></td>
                    <td>{lifecycle === "posted" ? <span className={`status-${bill.status}`}>{bill.status}</span> : "—"}</td>
                    <td className="num">NPR {Number(bill.amount_paid || 0).toLocaleString()}</td>
                    <td className="num"><b>NPR {Number(bill.outstanding_amount || 0).toLocaleString()}</b></td>
                    <td className="num"><b>NPR {Number(bill.net_total ?? bill.total).toLocaleString()}</b>{Number(bill.credited_amount || 0) > 0 && <div className="muted" style={{ fontSize: 10 }}>Original {Number(bill.total).toLocaleString()}</div>}</td>
                    <td style={{ whiteSpace: "nowrap" }}>
                      {lifecycle !== "draft" && <button className="link" onClick={() => setPrintBill(bill)}>View</button>}
                      <button className="link" onClick={() => setActivityDoc(bill)}>Activity</button>
                      {lifecycle === "draft" && <>
                        <button className="link" onClick={() => editDraft(bill)}>Edit</button>
                        <button className="link" onClick={() => postDraft(bill)} disabled={busy}>Post</button>
                        <button className="link" style={{ color: "var(--rust)" }} onClick={() => removeDraft(bill)} disabled={busy}>Delete</button>
                      </>}
                      {lifecycle === "posted" && ["open", "partial", "overdue"].includes(bill.status) && <button className="link" onClick={() => setPayModal(bill)}>{Number(bill.amount_paid || 0) > 0 ? "More Payment" : "Record Payment"}</button>}
                      {lifecycle === "posted" && Number(bill.amount_paid || 0) === 0 && Number(bill.credited_amount || 0) === 0 && <button className="link" style={{ color: "var(--rust)" }} onClick={() => setCancelDoc(bill)}>Cancel</button>}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}

      {activityDoc && <DocumentActivityModal documentType="bill" document={activityDoc} title={`Bill ${activityDoc.fiscal_year}-PB-${String(activityDoc.bill_number).padStart(4, "0")}`} onClose={() => setActivityDoc(null)} />}
      {cancelDoc && (
        <LifecycleActionModal
          title={`Cancel Bill #${cancelDoc.bill_number}`}
          description="This posts a reversing payable, VAT, purchase, and inventory voucher. Cancellation fails when returned stock is no longer available."
          actionLabel="Cancel & Reverse"
          onClose={() => setCancelDoc(null)}
          onConfirm={async (reason, date) => {
            await cancelBillDocument(cancelDoc.id, reason, date);
            await load();
          }}
        />
      )}
    </div>
  );
}
