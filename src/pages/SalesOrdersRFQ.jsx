// ============================================================
// Sales Orders and RFQ (Purchase Quotations) -- one shared
// implementation, since both are pre-document commitments with the
// same lifecycle shape (draft -> confirmed/sent -> converted or
// cancelled), just mirrored across the sales/purchase side. Each
// still gets its own route/nav entry -- pass docType="so"|"rfq".
// ============================================================
import React, { useEffect, useRef, useState } from "react";
import { Link, useSearchParams } from "react-router-dom";
import { supabase } from "../supabase";
import { listParties } from "../lib/db";
import { currentFiscalYear } from "../lib/fiscalYear";
import { todayLocalDate, adToBs, BS_MONTHS_EN } from "../lib/nepaliCalendar";
import {
  saveSalesOrderDraft, confirmSalesOrder, cancelSalesOrder, convertSalesOrderToInvoice,
  saveRfqDraft, sendRfq, cancelRfq, convertRfqToBill, deleteDocumentDraft,
} from "../lib/lifecycle";
import LifecycleActionModal from "../components/LifecycleActionModal";
import { showToast, confirmDialog } from "../lib/dialogs";

const VAT_RATE = 13;
const blankLine = () => ({ itemId: "", description: "", quantity: "1", unit: "pcs", rate: "", vatRate: VAT_RATE });
const fmt = (n) => Number(n || 0).toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 });
function calcAmount(l) { return (parseFloat(l.quantity) || 0) * (parseFloat(l.rate) || 0); }
function calcVat(l) { return calcAmount(l) * ((parseFloat(l.vatRate) || 0) / 100); }

function bsDisplay(adStr) {
  if (!adStr) return "";
  const bs = adToBs(adStr);
  if (!bs) return "";
  return `${bs.day} ${BS_MONTHS_EN[bs.month]} ${bs.year} BS`;
}

async function fetchItems() {
  const { data, error } = await supabase
    .from("inventory_items")
    .select("id,name,unit,selling_price,cost_price,current_stock,committed_stock,hsn_code,track_inventory,item_type")
    .eq("is_active", true).order("name");
  if (error) return [];
  return data;
}

export default function SalesOrdersRFQ({ docType, lang = "en" }) {
  const [searchParams, setSearchParams] = useSearchParams();
  const highlightId = searchParams.get("highlight");
  const highlightRef = useRef(null);
  const isSO = docType === "so";
  const partyRole = isSO ? "customer" : "vendor";
  const table = isSO ? "sales_orders" : "purchase_quotations";
  const linesTable = isSO ? "sales_order_lines" : "purchase_quotation_lines";
  const dateField = isSO ? "order_date" : "rfq_date";
  const numberField = isSO ? "order_number" : "rfq_number";
  const prefix = isSO ? "SO" : "RFQ";
  const docLabel = isSO ? "Sales Order" : "RFQ / Purchase Quotation";
  const partyLabel = isSO ? "Customer" : "Vendor";
  const commitStatus = isSO ? "confirmed" : "sent";
  const commitLabel = isSO ? "Confirm" : "Mark as Sent";
  const convertLabel = isSO ? "Convert to Invoice" : "Convert to Bill";

  const [docs, setDocs] = useState([]);
  const [parties, setParties] = useState([]);
  const [items, setItems] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);
  const [busy, setBusy] = useState(false);

  const [showForm, setShowForm] = useState(false);
  const [editingId, setEditingId] = useState(null);
  const [partyId, setPartyId] = useState("");
  const [partyName, setPartyName] = useState("");
  const [partyAddress, setPartyAddress] = useState("");
  const [partyPan, setPartyPan] = useState("");
  const [orderDate, setOrderDate] = useState(todayLocalDate());
  const [expectedDate, setExpectedDate] = useState("");
  const [notes, setNotes] = useState("");
  const [lines, setLines] = useState([blankLine(), blankLine()]);
  const [cancelDoc, setCancelDoc] = useState(null);

  const load = async () => {
    setLoading(true);
    setError(null);
    try {
      const [docResult, partyResult, itemResult] = await Promise.all([
        supabase.from(table).select(`*, ${linesTable}(*)`).order(dateField, { ascending: false }),
        listParties(),
        fetchItems(),
      ]);
      if (docResult.error) throw docResult.error;
      setDocs(docResult.data || []);
      setParties(partyResult || []);
      setItems(itemResult || []);
    } catch (err) {
      setError(err.message);
    }
    setLoading(false);
  };

  useEffect(() => { load(); }, [docType]); // eslint-disable-line

  // Arriving via a "From SO-.../From RFQ-..." link on the Invoice/Bill
  // page (?highlight=<id>) scrolls to and briefly highlights that
  // exact row instead of leaving the user to find it in the list.
  useEffect(() => {
    if (!highlightId || docs.length === 0) return;
    highlightRef.current?.scrollIntoView({ behavior: "smooth", block: "center" });
    const timer = setTimeout(() => setSearchParams({}, { replace: true }), 2500);
    return () => clearTimeout(timer);
  }, [docs, highlightId]); // eslint-disable-line

  const resetForm = () => {
    setEditingId(null); setPartyId(""); setPartyName(""); setPartyAddress(""); setPartyPan("");
    setOrderDate(todayLocalDate()); setExpectedDate(""); setNotes(""); setLines([blankLine(), blankLine()]);
  };

  const openNew = () => { resetForm(); setShowForm(true); };

  const openEdit = (doc) => {
    setEditingId(doc.id);
    setPartyId((isSO ? doc.party_id : doc.vendor_id) || "");
    setPartyName((isSO ? doc.party_name : doc.vendor_name) || "");
    setPartyAddress((isSO ? doc.party_address : doc.vendor_address) || "");
    setPartyPan((isSO ? doc.party_pan : doc.vendor_pan) || "");
    setOrderDate(doc[dateField]);
    setExpectedDate(doc.expected_date || "");
    setNotes(doc.notes || "");
    setLines((doc[linesTable] || []).map((l) => ({
      itemId: l.item_id || "", description: l.description, quantity: String(l.quantity),
      unit: l.unit || "pcs", rate: String(l.rate), vatRate: String(l.vat_rate),
    })));
    setShowForm(true);
  };

  const updateLine = (index, patch) => setLines((cur) => cur.map((l, i) => i === index ? { ...l, ...patch } : l));
  const addLine = () => setLines((cur) => [...cur, blankLine()]);
  const removeLine = (index) => setLines((cur) => cur.filter((_, i) => i !== index));

  const subtotal = lines.reduce((sum, l) => sum + calcAmount(l), 0);
  const vatTotal = lines.reduce((sum, l) => sum + calcVat(l), 0);
  const grandTotal = subtotal + vatTotal;

  const save = async (event) => {
    event.preventDefault();
    setBusy(true); setError(null);
    try {
      const header = isSO ? {
        fiscal_year: currentFiscalYear(), order_date: orderDate, expected_date: expectedDate || null,
        party_id: partyId || null, party_name: partyName.trim(), party_address: partyAddress.trim() || null,
        party_pan: partyPan.trim() || null, notes: notes.trim() || null,
        order_date_bs: bsDisplay(orderDate),
      } : {
        fiscal_year: currentFiscalYear(), rfq_date: orderDate, expected_date: expectedDate || null,
        vendor_id: partyId || null, vendor_name: partyName.trim(), vendor_address: partyAddress.trim() || null,
        vendor_pan: partyPan.trim() || null, notes: notes.trim() || null,
        rfq_date_bs: bsDisplay(orderDate),
      };
      const payloadLines = lines.filter((l) => l.description.trim() && Number(l.quantity) > 0).map((l) => ({
        item_id: l.itemId || null, description: l.description.trim(), quantity: Number(l.quantity),
        unit: l.unit || "pcs", rate: Number(l.rate) || 0, vat_rate: Number(l.vatRate) || 0,
        hsn_code: items.find((i) => i.id === l.itemId)?.hsn_code || null,
      }));
      if (isSO) await saveSalesOrderDraft(header, payloadLines, editingId);
      else await saveRfqDraft(header, payloadLines, editingId);
      showToast(`${docLabel} draft saved.`, "success");
      setShowForm(false);
      await load();
    } catch (err) {
      setError(err.message);
    }
    setBusy(false);
  };

  const doCommit = async (doc) => {
    if (!(await confirmDialog(`${commitLabel} ${prefix}-${doc.fiscal_year}-${String(doc[numberField]).padStart(4, "0")}?${isSO ? " This reserves the ordered stock." : ""}`))) return;
    try {
      if (isSO) await confirmSalesOrder(doc.id);
      else await sendRfq(doc.id);
      showToast(`${docLabel} ${isSO ? "confirmed" : "marked as sent"}.`, "success");
      await load();
    } catch (err) { showToast(err.message, "error"); }
  };

  const doConvert = async (doc) => {
    if (!(await confirmDialog(`${convertLabel} for ${prefix}-${doc.fiscal_year}-${String(doc[numberField]).padStart(4, "0")}? You'll still need to review and post the resulting ${isSO ? "invoice" : "bill"} draft.`))) return;
    try {
      if (isSO) await convertSalesOrderToInvoice(doc.id);
      else await convertRfqToBill(doc.id);
      showToast(`Converted to a ${isSO ? "invoice" : "bill"} draft.`, "success");
      await load();
    } catch (err) { showToast(err.message, "error"); }
  };

  const doDeleteDraft = async (doc) => {
    if (!(await confirmDialog(`Delete draft ${prefix}-${doc.fiscal_year}-${String(doc[numberField]).padStart(4, "0")}? This cannot be undone.`))) return;
    try {
      await deleteDocumentDraft(isSO ? "sales_order" : "rfq", doc.id);
      showToast("Draft deleted.", "success");
      await load();
    } catch (err) { showToast(err.message, "error"); }
  };

  return (
    <div className="panel">
      <div className="panel-head">
        <h2>{docLabel}s</h2>
        <button className="btn" onClick={() => { showForm ? setShowForm(false) : openNew(); }}>{showForm ? "Close Editor" : `+ New ${docLabel}`}</button>
      </div>

      <div className="settings-info-box" style={{ marginBottom: 16 }}>
        {isSO
          ? "A Sales Order is a commitment before invoicing -- it doesn't touch your books. Confirming it reserves the ordered stock; converting creates an invoice draft for you to review and post."
          : "An RFQ is a request for vendor quotes before a purchase bill -- it doesn't touch your books. Converting after it's sent creates a bill draft for you to review and post."}
      </div>

      {showForm && (
        <form className="inv-form" onSubmit={save} style={{ marginBottom: 20 }}>
          <b style={{ display: "block", marginBottom: 10 }}>{editingId ? `Edit ${docLabel} Draft` : `New ${docLabel}`}</b>
          <div className="inv-form-top">
            <label className="fld wide-field">{partyLabel}
              <select value={partyId} onChange={(e) => {
                const p = parties.find((x) => x.id === e.target.value);
                setPartyId(e.target.value);
                if (p) { setPartyName(p.accounts?.name || ""); setPartyPan(p.pan_vat_number || ""); }
              }}>
                <option value="">— select or type below —</option>
                {parties.filter((p) => p.party_type === partyRole || p.party_type === "both").map((p) => (
                  <option key={p.id} value={p.id}>{p.accounts?.name}</option>
                ))}
              </select>
            </label>
            <label className="fld">Name <input placeholder={`${partyLabel} name`} value={partyName} onChange={(e) => setPartyName(e.target.value)} required /></label>
            <label className="fld">Address <input value={partyAddress} onChange={(e) => setPartyAddress(e.target.value)} /></label>
            <label className="fld">PAN/VAT <input value={partyPan} onChange={(e) => setPartyPan(e.target.value)} /></label>
            <label className="fld">{isSO ? "Order" : "RFQ"} Date (AD)
              <input type="date" value={orderDate} onChange={(e) => setOrderDate(e.target.value)} required />
              <span style={{ fontSize: 11, color: "var(--ink2)", marginTop: 3 }}>{bsDisplay(orderDate)}</span>
            </label>
            <label className="fld">Expected Date (AD)
              <input type="date" value={expectedDate} onChange={(e) => setExpectedDate(e.target.value)} />
            </label>
          </div>

          <div style={{ overflowX: "auto" }}>
            <table className="tbl inv-lines-tbl">
              <thead><tr><th>Description</th><th>Unit</th><th className="num">Qty</th><th className="num">Rate</th><th className="num">Amount</th><th className="num">VAT%</th><th className="num">VAT</th><th className="num">Total</th><th /></tr></thead>
              <tbody>
                {lines.map((line, index) => (
                  <tr key={index}>
                    <td>
                      <select style={{ width: "100%", marginBottom: 3 }} value={line.itemId || ""} onChange={(e) => {
                        const item = items.find((entry) => entry.id === e.target.value);
                        if (item) updateLine(index, { itemId: item.id, description: item.name, unit: item.unit, rate: String(isSO ? item.selling_price : item.cost_price) });
                        else updateLine(index, { itemId: "", description: "", unit: "pcs", rate: "" });
                      }}>
                        <option value="">— type below or pick item —</option>
                        {items.map((item) => (
                          <option key={item.id} value={item.id}>
                            {item.name} {isSO && `(Available: ${Number(item.current_stock - item.committed_stock).toLocaleString()} ${item.unit})`}
                          </option>
                        ))}
                      </select>
                      <input placeholder="Description" value={line.description} onChange={(e) => updateLine(index, { description: e.target.value })} />
                    </td>
                    <td><input value={line.unit} onChange={(e) => updateLine(index, { unit: e.target.value })} style={{ width: 50 }} /></td>
                    <td><input type="number" step="0.001" className="num-input" value={line.quantity} onChange={(e) => updateLine(index, { quantity: e.target.value })} /></td>
                    <td><input type="number" step="0.01" className="num-input" value={line.rate} onChange={(e) => updateLine(index, { rate: e.target.value })} /></td>
                    <td className="num">{calcAmount(line).toLocaleString()}</td>
                    <td><input type="number" step="0.01" className="num-input" value={line.vatRate} onChange={(e) => updateLine(index, { vatRate: e.target.value })} style={{ width: 55 }} /></td>
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
          <label className="fld" style={{ marginTop: 12 }}>Notes <input value={notes} onChange={(e) => setNotes(e.target.value)} /></label>
          {error && <p className="msg err">{error}</p>}
          <div style={{ display: "flex", gap: 10, marginTop: 10 }}>
            <button className="btn" disabled={busy}>{busy ? "Saving…" : "Save Draft"}</button>
            <button type="button" className="ghost-btn" onClick={() => setShowForm(false)}>Cancel</button>
          </div>
        </form>
      )}

      {error && !showForm && <p className="msg err">{error}</p>}

      {loading ? <p className="note">Loading…</p> : docs.length === 0 ? <p className="note">No {docLabel.toLowerCase()}s yet.</p> : (
        <div style={{ overflowX: "auto" }}>
          <table className="tbl">
            <thead><tr><th>#</th><th>Date</th><th>{partyLabel}</th><th className="num">Total</th><th>Status</th><th /></tr></thead>
            <tbody>
              {docs.map((doc) => (
                <tr key={doc.id} ref={doc.id === highlightId ? highlightRef : null}
                    style={doc.id === highlightId ? { background: "var(--gold-light, #fff3cd)" } : undefined}>
                  <td><b>{prefix}-{doc.fiscal_year}-{String(doc[numberField]).padStart(4, "0")}</b></td>
                  <td>{doc[dateField]}</td>
                  <td>{isSO ? doc.party_name : doc.vendor_name}</td>
                  <td className="num"><b>NPR {fmt(doc.total)}</b></td>
                  <td><span className={`status-${doc.status}`}>{doc.status}</span></td>
                  <td style={{ whiteSpace: "nowrap" }}>
                    {doc.status === "draft" && <>
                      <button className="link" onClick={() => openEdit(doc)}>Edit</button>{" · "}
                      <button className="link" onClick={() => doCommit(doc)}>{commitLabel}</button>{" · "}
                      <button className="link" style={{ color: "var(--rust)" }} onClick={() => doDeleteDraft(doc)}>Delete</button>
                    </>}
                    {doc.status === commitStatus && <>
                      <button className="link" onClick={() => doConvert(doc)}>{convertLabel}</button>{" · "}
                      <button className="link" style={{ color: "var(--rust)" }} onClick={() => setCancelDoc(doc)}>Cancel</button>
                    </>}
                    {doc.status === "converted" && (
                      <Link className="link" to={`/${isSO ? "invoices" : "purchases"}?open=${isSO ? doc.invoice_id : doc.bill_id}`}>
                        View {isSO ? "Invoice" : "Bill"} →
                      </Link>
                    )}
                    {doc.status === "cancelled" && <span className="muted" title={doc.cancellation_reason}>Cancelled</span>}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      {cancelDoc && (
        <LifecycleActionModal
          title={`Cancel ${prefix}-${cancelDoc.fiscal_year}-${String(cancelDoc[numberField]).padStart(4, "0")}`}
          description={isSO ? "Any reserved stock for this order will be released." : "This RFQ will no longer be convertible to a bill."}
          actionLabel="Cancel"
          onClose={() => setCancelDoc(null)}
          onConfirm={async (reason) => {
            if (isSO) await cancelSalesOrder(cancelDoc.id, reason);
            else await cancelRfq(cancelDoc.id, reason);
            await load();
          }}
        />
      )}
    </div>
  );
}
