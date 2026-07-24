import React, { useEffect, useState } from "react";
import { supabase } from "../supabase";
import { listParties } from "../lib/db";
import { currentFiscalYear } from "../lib/fiscalYear";
import { todayLocalDate } from "../lib/nepaliCalendar";
import { createInvoiceWithPosting, refreshDocumentPaymentStatuses } from "../lib/posting";
import { cancelInvoiceDocument, deleteDocumentDraft, markInvoicePrinted, postInvoiceDraft, saveInvoiceDraft } from "../lib/lifecycle";
import LifecycleActionModal from "../components/LifecycleActionModal";
import DocumentActivityModal from "../components/DocumentActivityModal";
import PaymentModal from "./PaymentModal";
import { useTaxRates } from "../lib/taxRates";
import { useBusinessProfile } from "../lib/businessProfile";
import { adToBs, formatDualDate, BS_MONTHS_EN } from "../lib/nepaliCalendar";

const VAT_RATE = 13;
const blankLine = () => ({ itemId: "", description: "", quantity: "1", unit: "pcs", rate: "", vatRate: VAT_RATE });

// ── helpers ──────────────────────────────────────────────────
async function listInvoices() {
  const { data, error } = await supabase
    .from("invoices")
    .select("*, invoice_lines(*)")
    .order("invoice_date", { ascending: false });
  if (error) throw error;
  return data;
}

async function fetchItems() {
  const { data, error } = await supabase.from("inventory_items").select("id,name,unit,selling_price,current_stock,hsn_code,track_inventory,item_type").eq("is_active",true).order("name");
  if (error) return [];
  return data;
}

function calcAmount(l) { return (parseFloat(l.quantity) || 0) * (parseFloat(l.rate) || 0); }
function calcVat(l)    { return calcAmount(l) * ((parseFloat(l.vatRate) || 0) / 100); }

// Convert AD date string to BS display string
function adDateToBsString(adStr) {
  if (!adStr) return "";
  try {
    const bs = adToBs(new Date(adStr + "T00:00:00"));
    return `${bs.year}-${String(bs.month + 1).padStart(2,"0")}-${String(bs.day).padStart(2,"0")}`;
  } catch { return ""; }
}

function bsDisplayFull(adStr) {
  if (!adStr) return "";
  try {
    const bs = adToBs(new Date(adStr + "T00:00:00"));
    return `${bs.day} ${BS_MONTHS_EN[bs.month]} ${bs.year} BS`;
  } catch { return ""; }
}

function numWords(n) {
  const ones = ["","One","Two","Three","Four","Five","Six","Seven","Eight","Nine",
    "Ten","Eleven","Twelve","Thirteen","Fourteen","Fifteen","Sixteen","Seventeen","Eighteen","Nineteen"];
  const tens = ["","","Twenty","Thirty","Forty","Fifty","Sixty","Seventy","Eighty","Ninety"];
  if (n === 0) return "Zero";
  const int = Math.floor(n);
  const dec = Math.round((n - int) * 100);
  const toWords = (num) => {
    if (num === 0) return "";
    if (num < 20) return ones[num] + " ";
    if (num < 100) return tens[Math.floor(num/10)] + (num%10 ? " " + ones[num%10] : "") + " ";
    if (num < 1000) return ones[Math.floor(num/100)] + " Hundred " + toWords(num%100);
    if (num < 100000) return toWords(Math.floor(num/1000)) + "Thousand " + toWords(num%1000);
    if (num < 10000000) return toWords(Math.floor(num/100000)) + "Lakh " + toWords(num%100000);
    return toWords(Math.floor(num/10000000)) + "Crore " + toWords(num%10000000);
  };
  return "NPR " + toWords(int).trim() + (dec ? ` and ${dec}/100` : "") + " Only";
}

// ── IRD-Compliant Invoice Print ───────────────────────────────
function InvoicePrint({ inv, profile, isReprint, onClose }) {
  const print = () => window.print();
  const p = profile || {};
  const invNo = `${inv.fiscal_year}-${String(inv.invoice_number).padStart(4,"0")}`;
  const bsDate = bsDisplayFull(inv.invoice_date);
  const adDate = inv.invoice_date;
  const bsDue  = inv.due_date ? bsDisplayFull(inv.due_date) : null;

  return (
    <div className="print-overlay">
      <div className="print-actions no-print" style={{display:"flex",gap:12,alignItems:"center",marginBottom:20}}>
        <button className="btn" onClick={print}>🖨 Print / Save PDF</button>
        <button className="link" onClick={onClose}>← Back to Invoices</button>
        {isReprint && <span style={{color:"var(--rust)",fontWeight:700,fontSize:13}}>COPY — Reprint #{inv.reprint_count}</span>}
      </div>

      <div className="invoice-paper">
        {/* ── Header ── */}
        <div className="inv-header">
          <div style={{flex:1}}>
            <div className="inv-biz-name">{p.biz_name || "Your Business Name"}</div>
            {p.biz_name_np && <div style={{fontSize:14,color:"#444",fontFamily:"'Noto Sans Devanagari',sans-serif"}}>{p.biz_name_np}</div>}
            <div className="inv-biz-sub">{[p.address, p.city].filter(Boolean).join(", ") || "Address, City"}</div>
            {p.phone && <div className="inv-biz-sub">📞 {p.phone}</div>}
            {p.email && <div className="inv-biz-sub">✉ {p.email}</div>}
            {p.pan_vat && <div className="inv-biz-sub" style={{fontWeight:700}}>PAN/VAT: {p.pan_vat}</div>}
          </div>
          <div style={{textAlign:"right"}}>
            <div className="inv-title">TAX INVOICE</div>
            <div className="inv-title-sub">कर बीजक</div>
            {isReprint && (
              <div style={{fontSize:11,color:"var(--rust)",marginTop:4,fontWeight:700}}>
                COPY OF ORIGINAL — Print {inv.reprint_count}
              </div>
            )}
          </div>
        </div>

        {/* ── Invoice meta ── */}
        <div className="inv-meta">
          <div className="inv-meta-left">
            <div style={{marginBottom:4}}><b>Bill To / ग्राहक:</b></div>
            <div style={{fontWeight:600}}>{inv.party_name}</div>
            {inv.party_address && <div style={{fontSize:12,color:"#555"}}>{inv.party_address}</div>}
            {inv.party_pan && <div style={{fontSize:12}}>PAN: {inv.party_pan}</div>}
          </div>
          <div className="inv-meta-right">
            <div><span>Invoice No / बीजक नं:</span><b style={{marginLeft:8}}>{invNo}</b></div>
            <div style={{marginTop:4}}>
              <span>Date (BS) / मिति:</span>
              <b style={{marginLeft:8}}>{bsDate}</b>
            </div>
            <div style={{color:"#666",fontSize:11,textAlign:"right"}}>
              Date (AD): {adDate}
            </div>
            {bsDue && (
              <div style={{marginTop:4}}>
                <span>Due Date:</span>
                <b style={{marginLeft:8}}>{bsDue}</b>
                <span style={{fontSize:11,color:"#666",display:"block",textAlign:"right"}}>({inv.due_date} AD)</span>
              </div>
            )}
          </div>
        </div>

        {/* ── Line items ── */}
        <table className="inv-table">
          <thead>
            <tr>
              <th>#</th><th>Description / विवरण</th><th>Unit</th>
              <th className="r">Qty</th><th className="r">Rate</th>
              <th className="r">Amount</th><th className="r">VAT%</th>
              <th className="r">VAT</th><th className="r">Total</th>
            </tr>
          </thead>
          <tbody>
            {(inv.invoice_lines || []).map((l, i) => (
              <tr key={l.id || i}>
                <td>{i+1}</td>
                <td>{l.description}</td>
                <td>{l.unit}</td>
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
            <tr>
              <td colSpan={5}></td>
              <td className="r"><b>Subtotal / जम्मा</b></td>
              <td colSpan={2}></td>
              <td className="r"><b>{Number(inv.subtotal).toLocaleString()}</b></td>
            </tr>
            <tr>
              <td colSpan={5}></td>
              <td className="r"><b>VAT 13% / मूअकर</b></td>
              <td colSpan={2}></td>
              <td className="r"><b>{Number(inv.vat_amount).toLocaleString()}</b></td>
            </tr>
            <tr className="inv-total-row">
              <td colSpan={5}></td>
              <td className="r"><b>GRAND TOTAL / कुल जम्मा</b></td>
              <td colSpan={2}></td>
              <td className="r"><b>NPR {Number(inv.total).toLocaleString()}</b></td>
            </tr>
          </tfoot>
        </table>

        {/* ── Amount in words ── */}
        <div className="inv-words">
          <b>Amount in words:</b> {numWords(Number(inv.total))}
        </div>

        {inv.notes && <div className="inv-notes"><b>Notes:</b> {inv.notes}</div>}

        {/* ── Footer ── */}
        <div className="inv-footer">
          <div>
            <div className="inv-sign"><div className="inv-sign-line"></div><div>Customer Signature / ग्राहकको हस्ताक्षर</div></div>
          </div>
          <div style={{textAlign:"center",fontSize:11,color:"#888"}}>
            <div>This is a computer-generated invoice.</div>
            {isReprint && <div style={{color:"var(--rust)",fontWeight:600,marginTop:4}}>This is a copy — not an original invoice.</div>}
          </div>
          <div>
            <div className="inv-sign"><div className="inv-sign-line"></div><div>Authorised Signature / अधिकृत हस्ताक्षर</div></div>
          </div>
        </div>
      </div>
    </div>
  );
}

// ── Business Profile Settings Panel ──────────────────────────
function BizProfilePanel({ profile, onSave, onClose }) {
  const [form, setForm] = useState({
    biz_name:       profile.biz_name       || "",
    biz_name_np:    profile.biz_name_np    || "",
    address:        profile.address         || "",
    city:           profile.city            || "",
    pan_vat:        profile.pan_vat         || "",
    phone:          profile.phone           || "",
    email:          profile.email           || "",
    invoice_prefix: profile.invoice_prefix  || "",
  });
  const [busy, setBusy] = useState(false);
  const [ok, setOk] = useState(false);

  const save = async () => {
    setBusy(true);
    try { await onSave(form); setOk(true); setTimeout(onClose, 1000); }
    catch(e) { alert("Save failed: " + e.message); }
    setBusy(false);
  };

  const f = (k) => ({ value: form[k], onChange: e => setForm(f=>({...f,[k]:e.target.value})) });

  return (
    <div className="biz-form">
      <div style={{display:"flex",justifyContent:"space-between",alignItems:"center",marginBottom:8}}>
        <b>Business Details <span className="muted">(saved to your account, printed on every invoice)</span></b>
        <button className="link" style={{margin:0}} onClick={onClose}>✕ Close</button>
      </div>
      {ok && <p className="msg ok">✓ Saved to your account!</p>}
      <div className="grid-form" style={{gridTemplateColumns:"repeat(2,1fr)"}}>
        <label className="fld wide-field">Business Name (English) <input placeholder="e.g. Ram Traders Pvt Ltd" {...f("biz_name")} /></label>
        <label className="fld wide-field">Business Name (Nepali) <input placeholder="e.g. राम ट्रेडर्स प्रा.लि." {...f("biz_name_np")} /></label>
        <label className="fld">Address <input placeholder="Street / Tole" {...f("address")} /></label>
        <label className="fld">City / District <input placeholder="e.g. Kathmandu" {...f("city")} /></label>
        <label className="fld">PAN / VAT Number <input placeholder="9-digit PAN" {...f("pan_vat")} /></label>
        <label className="fld">Phone <input placeholder="+977-1-..." {...f("phone")} /></label>
        <label className="fld">Email <input placeholder="info@yourbiz.com" {...f("email")} /></label>
        <label className="fld">Invoice Prefix <input placeholder="INV (optional)" {...f("invoice_prefix")} /></label>
      </div>
      <button className="btn" onClick={save} disabled={busy}>{busy?"Saving…":"Save to Account"}</button>
    </div>
  );
}

// ── Main Invoices page ────────────────────────────────────────
export default function Invoices() {
  const { profile, loading: profLoading, save: saveProfile } = useBusinessProfile();
  const [invoices, setInvoices] = useState([]);
  const [parties, setParties] = useState([]);
  const [items, setItems] = useState([]);
  const [loading, setLoading] = useState(true);
  const [showForm, setShowForm] = useState(false);
  const [showBiz, setShowBiz] = useState(false);
  const [printInv, setPrintInv] = useState(null);
  const [isReprint, setIsReprint] = useState(false);
  const [payModal, setPayModal] = useState(null);
  const [activityDoc, setActivityDoc] = useState(null);
  const [cancelDoc, setCancelDoc] = useState(null);
  const [editingDraftId, setEditingDraftId] = useState(null);
  const [err, setErr] = useState(null);
  const [busy, setBusy] = useState(false);
  const [filter, setFilter] = useState("all");

  const emptyForm = () => ({
    fiscalYear: currentFiscalYear(),
    partyId: "", partyName: "", partyAddress: "", partyPan: "",
    invoiceDate: todayLocalDate(),
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
      const [invs, pts, itms] = await Promise.all([listInvoices(), listParties(), fetchItems()]);
      setInvoices(invs || []);
      setParties(pts || []);
      setItems(itms || []);
    } catch (error) {
      setErr(error.message);
    }
    setLoading(false);
  };

  useEffect(() => { load(); }, []);

  const selectParty = (partyId) => {
    const party = parties.find((entry) => entry.id === partyId);
    if (party) {
      setForm((current) => ({
        ...current,
        partyId,
        partyName: party.accounts?.name || "",
        partyAddress: party.address || "",
        partyPan: party.pan_vat_number || "",
      }));
    } else {
      setForm((current) => ({ ...current, partyId: "", partyName: "", partyAddress: "", partyPan: "" }));
    }
  };

  const updateLine = (index, patch) => setLines((current) => current.map((line, lineIndex) => lineIndex === index ? { ...line, ...patch } : line));
  const addLine = () => setLines((current) => [...current, blankLine()]);
  const removeLine = (index) => setLines((current) => current.filter((_, lineIndex) => lineIndex !== index));

  const subtotal = lines.reduce((sum, line) => sum + calcAmount(line), 0);
  const vatTotal = lines.reduce((sum, line) => sum + calcVat(line), 0);
  const grandTotal = subtotal + vatTotal;

  const buildDocument = () => {
    if (!form.partyName.trim()) throw new Error("Party name is required.");
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
      invoice_date: form.invoiceDate,
      invoice_date_bs: adDateToBsString(form.invoiceDate),
      due_date: form.dueDate || null,
      due_date_bs: form.dueDate ? adDateToBsString(form.dueDate) : null,
      party_id: form.partyId || null,
      party_name: form.partyName.trim(),
      party_address: form.partyAddress.trim() || null,
      party_pan: form.partyPan.trim() || null,
      notes: form.notes.trim() || null,
    };
    return { header, postLines };
  };

  const persist = async (mode) => {
    setBusy(true);
    setErr(null);
    try {
      const { header, postLines } = buildDocument();
      let invoiceId;
      if (mode === "draft") {
        invoiceId = await saveInvoiceDraft(header, postLines, editingDraftId);
      } else if (editingDraftId) {
        invoiceId = await saveInvoiceDraft(header, postLines, editingDraftId);
        await postInvoiceDraft(invoiceId);
      } else {
        invoiceId = await createInvoiceWithPosting(header, postLines);
      }
      resetEditor();
      setShowForm(false);
      await load();
      if (mode === "post") {
        const { data: invoice, error } = await supabase
          .from("invoices")
          .select("*, invoice_lines(*)")
          .eq("id", invoiceId)
          .single();
        if (error) throw error;
        setPrintInv(invoice);
        setIsReprint(false);
      }
    } catch (error) {
      setErr(error.message);
    }
    setBusy(false);
  };

  const editDraft = (invoice) => {
    setEditingDraftId(invoice.id);
    setForm({
      fiscalYear: invoice.fiscal_year,
      partyId: invoice.party_id || "",
      partyName: invoice.party_name || "",
      partyAddress: invoice.party_address || "",
      partyPan: invoice.party_pan || "",
      invoiceDate: invoice.invoice_date,
      dueDate: invoice.due_date || "",
      notes: invoice.notes || "",
    });
    setLines((invoice.invoice_lines || []).map((line) => ({
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

  const postDraft = async (invoice) => {
    setBusy(true);
    setErr(null);
    try {
      await postInvoiceDraft(invoice.id);
      await load();
    } catch (error) {
      setErr(error.message);
    }
    setBusy(false);
  };

  const removeDraft = async (invoice) => {
    setBusy(true);
    setErr(null);
    try {
      await deleteDocumentDraft("invoice", invoice.id);
      if (editingDraftId === invoice.id) {
        resetEditor();
        setShowForm(false);
      }
      await load();
    } catch (error) {
      setErr(error.message);
    }
    setBusy(false);
  };

  const openPrint = async (invoice) => {
    try {
      const count = await markInvoicePrinted(invoice.id);
      const { data: fresh, error } = await supabase
        .from("invoices")
        .select("*, invoice_lines(*)")
        .eq("id", invoice.id)
        .single();
      if (error) throw error;
      setPrintInv(fresh);
      setIsReprint(Number(count) > 1);
    } catch (error) {
      setErr(error.message);
    }
  };

  const lifecycleOf = (invoice) => invoice.document_status || (["cancelled", "credited", "draft"].includes(invoice.status) ? invoice.status : "posted");
  const matchesFilter = (invoice) => {
    if (filter === "all") return true;
    if (["draft", "posted", "cancelled", "credited"].includes(filter)) return lifecycleOf(invoice) === filter;
    return invoice.status === filter;
  };
  const filtered = invoices.filter(matchesFilter);
  const activeInvoices = invoices.filter((invoice) => lifecycleOf(invoice) === "posted");
  const totalOutstanding = activeInvoices.reduce((sum, invoice) => sum + Number(invoice.outstanding_amount ?? invoice.net_total ?? invoice.total), 0);
  const totalCollected = activeInvoices.reduce((sum, invoice) => sum + Number(invoice.amount_paid || 0), 0);
  const totalVat = activeInvoices.reduce((sum, invoice) => sum + Number(invoice.vat_amount || 0), 0);

  if (payModal) return (
    <PaymentModal
      docType="invoice"
      doc={payModal}
      onClose={() => setPayModal(null)}
      onSaved={() => { setPayModal(null); load(); }}
    />
  );

  if (printInv) return <InvoicePrint inv={printInv} profile={profile} isReprint={isReprint} onClose={() => setPrintInv(null)} />;

  return (
    <div className="panel">
      <div className="panel-head">
        <h2>Invoices (कर बीजक)</h2>
        <div style={{ display: "flex", gap: 8 }}>
          <button className="ghost-btn" onClick={() => setShowBiz((current) => !current)}>⚙ Business Info</button>
          <button className="btn" onClick={() => {
            if (showForm) resetEditor();
            setShowForm((current) => !current);
          }}>
            {showForm ? "Close Editor" : "+ New Invoice"}
          </button>
        </div>
      </div>

      {showBiz && !profLoading && profile && (
        <BizProfilePanel profile={profile} onSave={saveProfile} onClose={() => setShowBiz(false)} />
      )}

      <div className="stat-row">
        <div className="stat"><span style={{ color: "var(--gold)" }}>NPR {totalOutstanding.toLocaleString()}</span>Outstanding</div>
        <div className="stat"><span>NPR {totalCollected.toLocaleString()}</span>Collected</div>
        <div className="stat"><span>NPR {totalVat.toLocaleString()}</span>Output VAT</div>
        <div className="stat"><span>{invoices.length}</span>Total Invoices</div>
      </div>

      {showForm && (
        <form className="inv-form" onSubmit={(event) => { event.preventDefault(); persist("post"); }}>
          <b style={{ display: "block", marginBottom: 10 }}>
            {editingDraftId ? "Edit Invoice Draft" : "New Invoice"}
          </b>
          <div className="settings-info-box" style={{ marginBottom: 12 }}>
            Saving a draft does not change stock or the ledger. Posting is permanent; corrections must use cancellation or a credit note.
          </div>
          <div className="inv-form-top">
            <label className="fld">Fiscal Year
              <input value={form.fiscalYear} onChange={(event) => setForm((current) => ({ ...current, fiscalYear: event.target.value }))} disabled={Boolean(editingDraftId)} />
            </label>
            <label className="fld">Customer
              <select value={form.partyId} onChange={(event) => selectParty(event.target.value)}>
                <option value="">Select or type below…</option>
                {parties.filter((party) => party.party_type === "customer" || party.party_type === "both").map((party) => (
                  <option key={party.id} value={party.id}>{party.accounts?.name}</option>
                ))}
              </select>
            </label>
            <label className="fld">Name <input placeholder="Customer name" value={form.partyName} onChange={(event) => setForm((current) => ({ ...current, partyName: event.target.value }))} required /></label>
            <label className="fld">Address <input placeholder="Address" value={form.partyAddress} onChange={(event) => setForm((current) => ({ ...current, partyAddress: event.target.value }))} /></label>
            <label className="fld">PAN/VAT <input placeholder="PAN number" value={form.partyPan} onChange={(event) => setForm((current) => ({ ...current, partyPan: event.target.value }))} /></label>
            <label className="fld">Invoice Date (AD)
              <input type="date" value={form.invoiceDate} onChange={(event) => setForm((current) => ({ ...current, invoiceDate: event.target.value }))} required />
              <span style={{ fontSize: 11, color: "var(--ink2)", marginTop: 3 }}>{bsDisplayFull(form.invoiceDate)}</span>
            </label>
            <label className="fld">Due Date (AD)
              <input type="date" value={form.dueDate} onChange={(event) => setForm((current) => ({ ...current, dueDate: event.target.value }))} />
              {form.dueDate && <span style={{ fontSize: 11, color: "var(--ink2)", marginTop: 3 }}>{bsDisplayFull(form.dueDate)}</span>}
            </label>
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
                        if (item) updateLine(index, { itemId: item.id, description: item.name, unit: item.unit, rate: String(item.selling_price) });
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
          <label className="fld" style={{ marginTop: 12 }}>Printed notes <input placeholder="Optional notes printed on the invoice" value={form.notes} onChange={(event) => setForm((current) => ({ ...current, notes: event.target.value }))} /></label>
          {err && <p className="msg err">{err}</p>}
          <div style={{ display: "flex", gap: 10, flexWrap: "wrap", marginTop: 10 }}>
            <button type="button" className="ghost-btn" disabled={busy} onClick={() => persist("draft")}>{busy ? "Saving…" : "Save Draft"}</button>
            <button className="btn" disabled={busy}>{busy ? "Posting…" : "Post & Print"}</button>
          </div>
        </form>
      )}

      <div className="filter-tabs">
        {["all", "draft", "posted", "open", "partial", "overdue", "paid", "credited", "cancelled"].map((value) => (
          <button key={value} className={`filter-tab${filter === value ? " active" : ""}`} onClick={() => setFilter(value)}>
            {value.charAt(0).toUpperCase() + value.slice(1)}
          </button>
        ))}
      </div>

      {err && !showForm && <p className="msg err">{err}</p>}
      {loading ? <p className="note">Loading…</p> : filtered.length === 0 ? <p className="note">No invoices found.</p> : (
        <div style={{ overflowX: "auto", marginTop: 8 }}>
          <table className="tbl">
            <thead><tr><th>Invoice #</th><th>Date (BS)</th><th>Customer</th><th>Lifecycle</th><th>Payment</th><th className="num">Paid</th><th className="num">Outstanding</th><th className="num">Net / Original</th><th /></tr></thead>
            <tbody>
              {filtered.map((invoice) => {
                const lifecycle = lifecycleOf(invoice);
                return (
                  <tr key={invoice.id}>
                    <td>{invoice.fiscal_year}-{String(invoice.invoice_number).padStart(4, "0")}</td>
                    <td><span>{invoice.invoice_date_bs || adDateToBsString(invoice.invoice_date)}</span><span className="muted" style={{ fontSize: 11, display: "block" }}>{invoice.invoice_date} AD</span></td>
                    <td>{invoice.party_name}</td>
                    <td><span className={`status-${lifecycle}`}>{lifecycle}</span></td>
                    <td>{lifecycle === "posted" ? <span className={`status-${invoice.status}`}>{invoice.status}</span> : "—"}</td>
                    <td className="num">NPR {Number(invoice.amount_paid || 0).toLocaleString()}</td>
                    <td className="num"><b>NPR {Number(invoice.outstanding_amount || 0).toLocaleString()}</b></td>
                    <td className="num">
                      <b>NPR {Number(invoice.net_total ?? invoice.total).toLocaleString()}</b>
                      {Number(invoice.credited_amount || 0) > 0 && <div className="muted" style={{ fontSize: 10 }}>Original {Number(invoice.total).toLocaleString()}</div>}
                    </td>
                    <td style={{ whiteSpace: "nowrap" }}>
                      {lifecycle !== "draft" && <button className="link" onClick={() => openPrint(invoice)}>Print</button>}
                      <button className="link" onClick={() => setActivityDoc(invoice)}>Activity</button>
                      {lifecycle === "draft" && <>
                        <button className="link" onClick={() => editDraft(invoice)}>Edit</button>
                        <button className="link" onClick={() => postDraft(invoice)} disabled={busy}>Post</button>
                        <button className="link" style={{ color: "var(--rust)" }} onClick={() => removeDraft(invoice)} disabled={busy}>Delete</button>
                      </>}
                      {lifecycle === "posted" && ["open", "partial", "overdue"].includes(invoice.status) && (
                        <button className="link" onClick={() => setPayModal(invoice)}>{Number(invoice.amount_paid || 0) > 0 ? "More Payment" : "Record Payment"}</button>
                      )}
                      {lifecycle === "posted" && Number(invoice.amount_paid || 0) === 0 && Number(invoice.credited_amount || 0) === 0 && (
                        <button className="link" style={{ color: "var(--rust)" }} onClick={() => setCancelDoc(invoice)}>Cancel</button>
                      )}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}

      {activityDoc && (
        <DocumentActivityModal
          documentType="invoice"
          document={activityDoc}
          title={`Invoice ${activityDoc.fiscal_year}-${String(activityDoc.invoice_number).padStart(4, "0")}`}
          onClose={() => setActivityDoc(null)}
        />
      )}
      {cancelDoc && (
        <LifecycleActionModal
          title={`Cancel Invoice #${cancelDoc.invoice_number}`}
          description="This posts a reversing sales, VAT, receivable, inventory, and COGS voucher. The original invoice remains in the audit trail."
          actionLabel="Cancel & Reverse"
          onClose={() => setCancelDoc(null)}
          onConfirm={async (reason, date) => {
            await cancelInvoiceDocument(cancelDoc.id, reason, date);
            await load();
          }}
        />
      )}
    </div>
  );
}
