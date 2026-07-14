import React, { useEffect, useState } from "react";
import { supabase } from "../supabase";
import { listParties } from "../lib/db";
import { currentFiscalYear } from "../lib/fiscalYear";
import { createInvoiceWithPosting, refreshDocumentPaymentStatuses } from "../lib/posting";
import PaymentModal from "./PaymentModal";
import { useTaxRates } from "../lib/taxRates";
import { useBusinessProfile } from "../lib/businessProfile";
import { adToBs, formatDualDate, BS_MONTHS_EN } from "../lib/nepaliCalendar";

const VAT_RATE = 13;
const blankLine = () => ({ description: "", quantity: "1", unit: "pcs", rate: "", vatRate: VAT_RATE });

// ── helpers ──────────────────────────────────────────────────
async function nextInvoiceNumber(fiscalYear) {
  const { data, error } = await supabase.rpc("next_invoice_number", { p_fiscal_year: fiscalYear });
  if (error) throw error;
  return data;
}

async function listInvoices() {
  const { data, error } = await supabase
    .from("invoices")
    .select("*, invoice_lines(*)")
    .order("invoice_date", { ascending: false });
  if (error) throw error;
  return data;
}

async function fetchItems() {
  const { data, error } = await supabase.from("inventory_items").select("id,name,unit,selling_price,current_stock").eq("is_active",true).order("name");
  if (error) return [];
  return data;
}

async function updateStatus(id, status) {
  const { error } = await supabase.from("invoices").update({ status }).eq("id", id);
  if (error) throw error;
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
export default function Invoices({ userId }) {
  const { profile, loading: profLoading, save: saveProfile } = useBusinessProfile();
  const [invoices, setInvoices] = useState([]);
  const [parties, setParties]   = useState([]);
  const [loading, setLoading]   = useState(true);
  const [showForm, setShowForm] = useState(false);
  const [showBiz, setShowBiz]   = useState(false);
  const [printInv, setPrintInv] = useState(null);
  const [isReprint, setIsReprint] = useState(false);
  const [err, setErr]           = useState(null);
  const [busy, setBusy]         = useState(false);
  const [filter, setFilter]     = useState("all");
  const [items, setItems]       = useState([]);  // inventory items for line picker
  const [payModal, setPayModal] = useState(null); // invoice being paid, or null

  const [form, setForm] = useState({
    partyId: "", partyName: "", partyAddress: "", partyPan: "",
    invoiceDate: new Date().toISOString().slice(0,10),
    dueDate: "", notes: "",
  });
  const [lines, setLines] = useState([blankLine(), blankLine()]);

  const load = async () => {
    setLoading(true);
    try {
      await refreshDocumentPaymentStatuses();
      const [invs, pts, itms] = await Promise.all([listInvoices(), listParties(), fetchItems()]);
      setItems(itms);
      setInvoices(invs); setParties(pts);
    } catch(e) { setErr(e.message); }
    setLoading(false);
  };

  useEffect(() => { load(); }, []);

  const selectParty = (partyId) => {
    const p = parties.find(p => p.id === partyId);
    if (p) setForm(f => ({ ...f, partyId, partyName: p.accounts?.name||"", partyAddress: p.address||"", partyPan: p.pan_vat_number||"" }));
    else   setForm(f => ({ ...f, partyId:"", partyName:"", partyAddress:"", partyPan:"" }));
  };

  const updateLine = (i, patch) => setLines(ls => ls.map((l,idx)=>idx===i?{...l,...patch}:l));
  const addLine    = () => setLines(ls => [...ls, blankLine()]);
  const removeLine = (i) => setLines(ls => ls.filter((_,idx)=>idx!==i));

  const subtotal   = lines.reduce((s,l)=>s+calcAmount(l),0);
  const vatTotal   = lines.reduce((s,l)=>s+calcVat(l),0);
  const grandTotal = subtotal + vatTotal;

  const submit = async (e) => {
    e.preventDefault();
    if (!form.partyName.trim()) { setErr("Party name is required."); return; }
    const validLines = lines.filter(l => l.description && parseFloat(l.rate));
    if (validLines.length === 0) { setErr("Add at least one line item."); return; }
    setBusy(true); setErr(null);
    try {
      const fiscalYear   = currentFiscalYear();
      const invoiceNumber = await nextInvoiceNumber(fiscalYear);
      const postLines = validLines.map(l => ({
        item_id:     l.itemId || null,
        description: l.description,
        quantity:    parseFloat(l.quantity) || 1,
        unit:        l.unit || "pcs",
        rate:        parseFloat(l.rate) || 0,
        amount:      calcAmount(l),
        vat_rate:    parseFloat(l.vatRate) || VAT_RATE,
        vat_amount:  calcVat(l),
        line_total:  calcAmount(l) + calcVat(l),
      }));
      const header = {
        invoice_number: invoiceNumber,
        fiscal_year:    fiscalYear,
        invoice_date:   form.invoiceDate,
        invoice_date_bs: adDateToBsString(form.invoiceDate),
        due_date:       form.dueDate || null,
        due_date_bs:    form.dueDate ? adDateToBsString(form.dueDate) : null,
        party_id:       form.partyId || null,
        party_name:     form.partyName.trim(),
        party_address:  form.partyAddress.trim() || null,
        party_pan:      form.partyPan.trim() || null,
        notes:          form.notes.trim() || null,
        status:         "open",
      };
      const invId = await createInvoiceWithPosting(header, postLines);
      setShowForm(false);
      setLines([blankLine(), blankLine()]);
      setForm({ partyId:"", partyName:"", partyAddress:"", partyPan:"", invoiceDate: new Date().toISOString().slice(0,10), dueDate:"", notes:"" });
      await load();
      const { data: inv } = await supabase.from("invoices").select("*, invoice_lines(*)").eq("id", invId).single();
      setPrintInv(inv); setIsReprint(false);
    } catch(e) { setErr(e.message); }
    setBusy(false);
  };

  const openPrint = async (inv) => {
    // If already printed before, mark as reprint
    const rc = (inv.reprint_count || 0) + 1;
    if (inv.reprint_count > 0 || inv.is_reprint) {
      await supabase.from("invoices").update({ is_reprint: true, reprint_count: rc }).eq("id", inv.id);
      const { data: fresh } = await supabase.from("invoices").select("*, invoice_lines(*)").eq("id", inv.id).single();
      setPrintInv(fresh); setIsReprint(true);
    } else {
      await supabase.from("invoices").update({ reprint_count: 1 }).eq("id", inv.id);
      const { data: fresh } = await supabase.from("invoices").select("*, invoice_lines(*)").eq("id", inv.id).single();
      setPrintInv(fresh); setIsReprint(false);
    }
  };

  const filtered = filter === "all" ? invoices : invoices.filter(i => i.status === filter);

  const activeInvoices = invoices.filter(i => !["cancelled", "credited"].includes(i.status));
  const totalOutstanding = activeInvoices.reduce((s, i) => s + Number(i.outstanding_amount ?? i.total), 0);
  const totalCollected = activeInvoices.reduce((s, i) => s + Number(i.amount_paid || 0), 0);
  const totalVat = activeInvoices.reduce((s, i) => s + Number(i.vat_amount), 0);

    if (payModal) return (
    <PaymentModal docType="invoice" doc={payModal}
      onClose={()=>setPayModal(null)}
      onSaved={()=>{setPayModal(null); load();}} />
  );

  if (printInv) return <InvoicePrint inv={printInv} profile={profile} isReprint={isReprint} onClose={()=>setPrintInv(null)} />;

  return (
    <div className="panel">
      <div className="panel-head">
        <h2>Invoices (कर बीजक)</h2>
        <div style={{display:"flex",gap:8}}>
          <button className="ghost-btn" onClick={()=>setShowBiz(s=>!s)}>⚙ Business Info</button>
          <button className="btn" onClick={()=>setShowForm(s=>!s)}>{showForm?"Cancel":"+ New Invoice"}</button>
        </div>
      </div>

      {/* Business profile panel */}
      {showBiz && !profLoading && profile && (
        <BizProfilePanel profile={profile} onSave={saveProfile} onClose={()=>setShowBiz(false)} />
      )}

      {/* Summary stats */}
      <div className="stat-row">
        <div className="stat"><span style={{color:"var(--gold)"}}>NPR {totalOutstanding.toLocaleString()}</span>Outstanding</div>
        <div className="stat"><span>NPR {totalCollected.toLocaleString()}</span>Collected</div>
        <div className="stat"><span>NPR {totalVat.toLocaleString()}</span>Output VAT</div>
        <div className="stat"><span>{invoices.length}</span>Total Invoices</div>
      </div>

      {/* New invoice form */}
      {showForm && (
        <form className="inv-form" onSubmit={submit}>
          <div className="inv-form-top">
            <label className="fld">Customer
              <select value={form.partyId} onChange={e=>selectParty(e.target.value)}>
                <option value="">Select or type below…</option>
                {parties.filter(p=>p.party_type==="customer"||p.party_type==="both").map(p=>(
                  <option key={p.id} value={p.id}>{p.accounts?.name}</option>
                ))}
              </select>
            </label>
            <label className="fld">Name <input placeholder="Customer name" value={form.partyName} onChange={e=>setForm(f=>({...f,partyName:e.target.value}))} required /></label>
            <label className="fld">Address <input placeholder="Address" value={form.partyAddress} onChange={e=>setForm(f=>({...f,partyAddress:e.target.value}))} /></label>
            <label className="fld">PAN/VAT <input placeholder="PAN number" value={form.partyPan} onChange={e=>setForm(f=>({...f,partyPan:e.target.value}))} /></label>
            <label className="fld">
              Invoice Date (AD)
              <input type="date" value={form.invoiceDate} onChange={e=>setForm(f=>({...f,invoiceDate:e.target.value}))} required />
              <span style={{fontSize:11,color:"var(--ink2)",marginTop:3}}>{bsDisplayFull(form.invoiceDate)}</span>
            </label>
            <label className="fld">
              Due Date (AD)
              <input type="date" value={form.dueDate} onChange={e=>setForm(f=>({...f,dueDate:e.target.value}))} />
              {form.dueDate && <span style={{fontSize:11,color:"var(--ink2)",marginTop:3}}>{bsDisplayFull(form.dueDate)}</span>}
            </label>
          </div>

          <table className="tbl inv-lines-tbl">
            <thead><tr><th>Description</th><th>Unit</th><th className="num">Qty</th><th className="num">Rate</th><th className="num">Amount</th><th className="num">VAT%</th><th className="num">VAT</th><th className="num">Total</th><th/></tr></thead>
            <tbody>
              {lines.map((l,i)=>(
                <tr key={i}>
                  <td>
                    <select style={{width:"100%",marginBottom:3}} value={l.itemId||""}
                      onChange={e=>{
                        const itm = items.find(x=>x.id===e.target.value);
                        if(itm) updateLine(i,{itemId:itm.id,description:itm.name,unit:itm.unit,rate:String(itm.selling_price)});
                        else updateLine(i,{itemId:"",description:"",unit:"pcs",rate:""});
                      }}>
                      <option value="">— type below or pick item —</option>
                      {items.map(itm=>(
                        <option key={itm.id} value={itm.id}>{itm.name} (Stock: {Number(itm.current_stock).toLocaleString()} {itm.unit})</option>
                      ))}
                    </select>
                    <input placeholder="Description" value={l.description} onChange={e=>updateLine(i,{description:e.target.value})} />
                  </td>
                  <td><input placeholder="pcs" value={l.unit} onChange={e=>updateLine(i,{unit:e.target.value})} style={{width:50}} /></td>
                  <td><input type="number" step="0.001" className="num-input" value={l.quantity} onChange={e=>updateLine(i,{quantity:e.target.value})} /></td>
                  <td><input type="number" step="0.01"  className="num-input" value={l.rate}     onChange={e=>updateLine(i,{rate:e.target.value})} /></td>
                  <td className="num">{calcAmount(l).toLocaleString()}</td>
                  <td><input type="number" step="0.01"  className="num-input" value={l.vatRate}  onChange={e=>updateLine(i,{vatRate:e.target.value})} style={{width:55}} /></td>
                  <td className="num">{calcVat(l).toLocaleString()}</td>
                  <td className="num">{(calcAmount(l)+calcVat(l)).toLocaleString()}</td>
                  <td>{lines.length>1&&<button type="button" className="link" onClick={()=>removeLine(i)}>✕</button>}</td>
                </tr>
              ))}
            </tbody>
            <tfoot>
              <tr><td colSpan={4} className="muted">Subtotal</td><td className="num"><b>{subtotal.toLocaleString()}</b></td><td></td><td className="num"><b>{vatTotal.toLocaleString()}</b></td><td className="num"><b>{grandTotal.toLocaleString()}</b></td><td/></tr>
            </tfoot>
          </table>
          <button type="button" className="link" onClick={addLine}>+ Add line</button>
          <label className="fld" style={{marginTop:12}}>Notes <input placeholder="Optional notes" value={form.notes} onChange={e=>setForm(f=>({...f,notes:e.target.value}))} /></label>
          {err && <p className="msg err">{err}</p>}
          <button className="btn" disabled={busy}>{busy?"Saving…":"Save & Print Invoice"}</button>
        </form>
      )}

      {/* Filter tabs */}
      <div className="filter-tabs">
        {["all","open","partial","overdue","paid","draft","cancelled","credited"].map(f=>(
          <button key={f} className={"filter-tab"+(filter===f?" active":"")} onClick={()=>setFilter(f)}>
            {f.charAt(0).toUpperCase()+f.slice(1)}
          </button>
        ))}
      </div>

      {loading ? <p className="note">Loading…</p> : filtered.length === 0 ? (
        <p className="note">No invoices found.</p>
      ) : (
        <table className="tbl" style={{marginTop:8}}>
          <thead><tr><th>Invoice #</th><th>Date (BS)</th><th>Customer</th><th>Status</th><th className="num">Paid</th><th className="num">Outstanding</th><th className="num">Total</th><th/></tr></thead>
          <tbody>
            {filtered.map(inv=>(
              <tr key={inv.id}>
                <td>{inv.fiscal_year}-{String(inv.invoice_number).padStart(4,"0")}</td>
                <td>
                  <span>{inv.invoice_date_bs || adDateToBsString(inv.invoice_date)}</span>
                  <span className="muted" style={{fontSize:11,display:"block"}}>{inv.invoice_date} AD</span>
                </td>
                <td>{inv.party_name}</td>
                <td>
                  <span className={"status-"+inv.status}>{inv.status}</span>
                  {["partial", "overdue"].includes(inv.status) && (
                    <div style={{fontSize:10,color:"var(--rust)",marginTop:2}}>
                      Paid NPR {Number(inv.amount_paid || 0).toLocaleString()}
                    </div>
                  )}
                </td>
                <td className="num">NPR {Number(inv.amount_paid || 0).toLocaleString()}</td>
                <td className="num"><b>NPR {Number(inv.outstanding_amount ?? inv.total).toLocaleString()}</b></td>
                <td className="num">NPR {Number(inv.total).toLocaleString()}</td>
                <td>
                  <button className="link" onClick={()=>openPrint(inv)}>Print</button>
                  {inv.status==="draft" && <button className="link" onClick={async()=>{await updateStatus(inv.id,"open");load();}}>Mark Open</button>}
                  {(["open", "partial", "overdue"].includes(inv.status)) && (
                    <button className="link" onClick={()=>setPayModal(inv)}>
                      {Number(inv.amount_paid || 0) > 0 ? "Record More Payment" : "Record Payment"}
                    </button>
                  )}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </div>
  );
}
