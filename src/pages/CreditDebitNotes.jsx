import React, { useEffect, useState } from "react";
import { supabase } from "../supabase";
import { listParties } from "../lib/db";
import { currentFiscalYear } from "../lib/fiscalYear";
import { useTaxRates } from "../lib/taxRates";

const fmt = (n) => Number(n||0).toLocaleString(undefined,{minimumFractionDigits:2,maximumFractionDigits:2});
const blankLine = () => ({ description:"", quantity:"1", unit:"pcs", rate:"", vatRate:13 });

function calcAmt(l)  { return (parseFloat(l.quantity)||0) * (parseFloat(l.rate)||0); }
function calcVat(l)  { return Math.round(calcAmt(l) * (parseFloat(l.vatRate)||0) / 100 * 100) / 100; }
function calcTotal(l){ return calcAmt(l) + calcVat(l); }

// ── Print view ───────────────────────────────────────────────
function NotePrint({ note, noteType, onClose }) {
  const isCN = noteType === "cn";
  const num  = isCN ? note.cn_number : note.dn_number;
  const date = isCN ? note.cn_date   : note.dn_date;
  const party= isCN ? note.party_name : note.vendor_name;
  const origRef = isCN
    ? (note.invoice_number ? `Against Invoice #${note.invoice_number}` : "")
    : (note.bill_number    ? `Against Bill #${note.bill_number}`        : "");
  const lines = isCN ? (note.credit_note_lines||[]) : (note.debit_note_lines||[]);

  return (
    <div className="print-overlay">
      <div className="print-actions no-print" style={{display:"flex",gap:12,marginBottom:20}}>
        <button className="btn" onClick={()=>window.print()}>🖨 Print</button>
        <button className="link" onClick={onClose}>← Back</button>
      </div>
      <div className="invoice-paper">
        <div className="inv-header">
          <div style={{flex:1}}>
            <div className="inv-title">{isCN ? "CREDIT NOTE" : "DEBIT NOTE"}</div>
            <div className="inv-title-sub">{isCN ? "क्रेडिट नोट (बिक्री फिर्ता)" : "डेबिट नोट (खरिद फिर्ता)"}</div>
          </div>
          <div style={{textAlign:"right",fontSize:12,color:"#555"}}>
            <div><b>No:</b> {isCN?"CN":"DN"}-{String(num).padStart(4,"0")}</div>
            <div><b>Date:</b> {date}</div>
            <div><b>FY:</b> {isCN ? note.fiscal_year : note.fiscal_year}</div>
          </div>
        </div>

        <div className="inv-meta">
          <div className="inv-meta-left">
            <div style={{fontWeight:600}}>{isCN?"Customer":"Vendor"}:</div>
            <div style={{fontSize:15,fontWeight:700}}>{party}</div>
            {(isCN?note.party_address:note.vendor_address) && (
              <div style={{fontSize:12}}>{isCN?note.party_address:note.vendor_address}</div>
            )}
            {(isCN?note.party_pan:note.vendor_pan) && (
              <div style={{fontSize:12}}>PAN: {isCN?note.party_pan:note.vendor_pan}</div>
            )}
          </div>
          <div className="inv-meta-right">
            {origRef && <div style={{fontSize:12}}>{origRef}</div>}
            {note.reason && <div style={{fontSize:12}}><b>Reason:</b> {note.reason}</div>}
          </div>
        </div>

        <table className="inv-table" style={{marginTop:16}}>
          <thead>
            <tr>
              <th>#</th><th>Description</th><th>Qty</th><th>Unit</th>
              <th className="r">Rate</th><th className="r">Amount</th>
              <th className="r">VAT%</th><th className="r">VAT</th>
              <th className="r">Total</th>
            </tr>
          </thead>
          <tbody>
            {lines.map((l,i)=>(
              <tr key={l.id||i}>
                <td>{i+1}</td>
                <td>{l.description}</td>
                <td>{l.quantity}</td>
                <td>{l.unit}</td>
                <td className="r">{fmt(l.rate)}</td>
                <td className="r">{fmt(l.amount)}</td>
                <td className="r">{l.vat_rate}%</td>
                <td className="r">{fmt(l.vat_amount)}</td>
                <td className="r">{fmt(l.line_total)}</td>
              </tr>
            ))}
          </tbody>
          <tfoot>
            <tr><td colSpan={5}/><td className="r">{fmt(note.subtotal)}</td><td/><td className="r">{fmt(note.vat_amount)}</td><td className="r"><b>{fmt(note.total)}</b></td></tr>
          </tfoot>
        </table>

        <div className="inv-summary">
          <div className="inv-summary-row"><span>Subtotal</span><span>NPR {fmt(note.subtotal)}</span></div>
          <div className="inv-summary-row"><span>VAT ({isCN?"Output":"Input"} reversed)</span><span>NPR {fmt(note.vat_amount)}</span></div>
          <div className="inv-summary-row inv-grand"><span>TOTAL {isCN?"CREDIT":"DEBIT"}</span><span>NPR {fmt(note.total)}</span></div>
        </div>

        <div className="inv-footer" style={{marginTop:32}}>
          <div><div className="inv-sign"><div className="inv-sign-line"/><div>Authorised Signatory</div></div></div>
          <div style={{textAlign:"center",fontSize:11,color:"#888"}}>This is a valid {isCN?"credit":"debit"} note for accounting purposes.</div>
          <div><div className="inv-sign"><div className="inv-sign-line"/><div>{isCN?"Customer":"Vendor"} Acknowledgement</div></div></div>
        </div>
      </div>
    </div>
  );
}

// ── Note form (shared for CN and DN) ─────────────────────────
function NoteForm({ noteType, parties, invoices, bills, vatRate, onSave, onCancel, busy, err }) {
  const isCN = noteType === "cn";
  const fy   = currentFiscalYear();

  const [form, setForm] = useState({
    date: new Date().toISOString().slice(0,10),
    fiscalYear: fy,
    partyId:"", partyName:"", partyAddress:"", partyPan:"",
    linkedId:"", linkedNumber:"",
    reason:"", notes:"",
  });
  const [lines, setLines] = useState([blankLine(), blankLine()]);

  const setF = (k,v) => setForm(f=>({...f,[k]:v}));

  const selectParty = (id) => {
    const p = parties.find(x=>x.id===id);
    if (p) setF("partyId",id), setF("partyName",p.accounts?.name||""), setF("partyPan",p.pan_vat_number||"");
    else setF("partyId","");
  };

  const selectLinked = (id) => {
    if (!id) { setF("linkedId",""); setF("linkedNumber",""); return; }
    if (isCN) {
      const inv = invoices.find(x=>x.id===id);
      if (inv) {
        setF("linkedId",id);
        setF("linkedNumber",String(inv.invoice_number));
        if (!form.partyName && inv.party_name) setF("partyName",inv.party_name);
        if (!form.partyPan  && inv.party_pan)  setF("partyPan",inv.party_pan);
        if (inv.party_id && !form.partyId) setF("partyId",inv.party_id);
        // Auto-fill lines from invoice
        if (inv.invoice_lines?.length) {
          setLines(inv.invoice_lines.map(l=>({
            description: l.description,
            quantity: String(l.quantity),
            unit: l.unit||"pcs",
            rate: String(l.rate),
            vatRate: l.vat_rate||13,
          })));
        }
      }
    } else {
      const b = bills.find(x=>x.id===id);
      if (b) {
        setF("linkedId",id);
        setF("linkedNumber",String(b.bill_number));
        if (!form.partyName && b.vendor_name) setF("partyName",b.vendor_name);
        if (!form.partyPan  && b.vendor_pan)  setF("partyPan",b.vendor_pan);
        if (b.vendor_id && !form.partyId) setF("partyId",b.vendor_id);
      }
    }
  };

  const updateLine = (i,patch) => setLines(ls=>ls.map((l,j)=>j===i?{...l,...patch}:l));

  const validLines = lines.filter(l=>l.description.trim() && parseFloat(l.rate)>0);
  const subtotal   = validLines.reduce((s,l)=>s+calcAmt(l),0);
  const vatTotal   = validLines.reduce((s,l)=>s+calcVat(l),0);
  const total      = subtotal + vatTotal;

  const submit = () => {
    if (!form.partyName.trim()) return;
    if (validLines.length === 0) return;
    const header = {
      cn_date: form.date, dn_date: form.date,
      fiscal_year: form.fiscalYear,
      party_id: form.partyId||null, party_name: form.partyName.trim(),
      party_address: form.partyAddress||null, party_pan: form.partyPan||null,
      vendor_id: form.partyId||null, vendor_name: form.partyName.trim(),
      vendor_address: form.partyAddress||null, vendor_pan: form.partyPan||null,
      invoice_id: isCN ? (form.linkedId||null) : null,
      invoice_number: isCN ? (form.linkedNumber||null) : null,
      bill_id: !isCN ? (form.linkedId||null) : null,
      bill_number: !isCN ? (form.linkedNumber||null) : null,
      reason: form.reason||null, notes: form.notes||null,
    };
    const postLines = validLines.map(l=>({
      description: l.description, quantity: parseFloat(l.quantity)||1,
      unit: l.unit||"pcs", rate: parseFloat(l.rate)||0,
      amount: calcAmt(l), vat_rate: parseFloat(l.vatRate)||vatRate,
      vat_amount: calcVat(l), line_total: calcTotal(l),
    }));
    onSave(header, postLines);
  };

  return (
    <div className="inv-form" style={{marginBottom:16}}>
      <b style={{display:"block",marginBottom:10}}>
        New {isCN?"Credit Note (Sales Return)":"Debit Note (Purchase Return)"}
      </b>

      <div className="inv-form-top">
        <label className="fld">Date <input type="date" value={form.date} onChange={e=>setF("date",e.target.value)} /></label>
        <label className="fld">Fiscal Year <input value={form.fiscalYear} onChange={e=>setF("fiscalYear",e.target.value)} /></label>
        <label className="fld">
          {isCN?"Customer":"Vendor"} (Party)
          <select value={form.partyId} onChange={e=>selectParty(e.target.value)}>
            <option value="">— select or type below —</option>
            {parties.filter(p=>isCN?p.party_type!=="vendor":p.party_type!=="customer").map(p=>(
              <option key={p.id} value={p.id}>{p.accounts?.name}</option>
            ))}
          </select>
        </label>
        <label className="fld">
          {isCN?"Customer":"Vendor"} Name *
          <input placeholder={isCN?"Customer name":"Vendor name"} value={form.partyName}
            onChange={e=>setF("partyName",e.target.value)} required />
        </label>
        <label className="fld">
          PAN
          <input placeholder="PAN number" value={form.partyPan} onChange={e=>setF("partyPan",e.target.value)} />
        </label>
        <label className="fld">
          {isCN?"Against Invoice (optional)":"Against Bill (optional)"}
          <select value={form.linkedId} onChange={e=>selectLinked(e.target.value)}>
            <option value="">— select original document —</option>
            {isCN
              ? invoices.map(inv=><option key={inv.id} value={inv.id}>Invoice #{inv.invoice_number} — {inv.party_name} — NPR {Number(inv.total).toLocaleString()}</option>)
              : bills.map(b=><option key={b.id} value={b.id}>Bill #{b.bill_number} — {b.vendor_name} — NPR {Number(b.total).toLocaleString()}</option>)
            }
          </select>
        </label>
        <label className="fld wide-field">
          Reason for {isCN?"Return / Credit":"Return / Debit"} *
          <input placeholder="e.g. Goods damaged, Overcharge correction" value={form.reason}
            onChange={e=>setF("reason",e.target.value)} />
        </label>
      </div>

      {/* Line items */}
      <div style={{overflowX:"auto",marginTop:12}}>
        <table className="tbl inv-lines-tbl">
          <thead>
            <tr>
              <th style={{width:"30%"}}>Item / Description</th>
              <th style={{width:70}}>Qty</th>
              <th style={{width:60}}>Unit</th>
              <th style={{width:100}}>Rate</th>
              <th style={{width:100}}>Amount</th>
              <th style={{width:70}}>VAT%</th>
              <th style={{width:100}}>VAT</th>
              <th style={{width:100}}>Total</th>
              <th style={{width:32}}/>
            </tr>
          </thead>
          <tbody>
            {lines.map((l,i)=>(
              <tr key={i}>
                <td><input value={l.description} placeholder="Item/service description" onChange={e=>updateLine(i,{description:e.target.value})} /></td>
                <td><input type="number" value={l.quantity} onChange={e=>updateLine(i,{quantity:e.target.value})} style={{width:60}} /></td>
                <td><input value={l.unit} onChange={e=>updateLine(i,{unit:e.target.value})} style={{width:50}} /></td>
                <td><input type="number" value={l.rate} placeholder="0" onChange={e=>updateLine(i,{rate:e.target.value})} /></td>
                <td className="num">{fmt(calcAmt(l))}</td>
                <td><input type="number" value={l.vatRate} onChange={e=>updateLine(i,{vatRate:e.target.value})} style={{width:55}} /></td>
                <td className="num">{fmt(calcVat(l))}</td>
                <td className="num"><b>{fmt(calcTotal(l))}</b></td>
                <td><button className="link" onClick={()=>setLines(ls=>ls.filter((_,j)=>j!==i))}>✕</button></td>
              </tr>
            ))}
          </tbody>
        </table>
        <button className="ghost-btn" style={{marginTop:6}} onClick={()=>setLines(ls=>[...ls,{...blankLine(),vatRate:vatRate}])}>
          + Add line
        </button>
      </div>

      {/* Totals */}
      {validLines.length > 0 && (
        <div className="inv-totals" style={{marginTop:8}}>
          <div className="inv-total-row"><span>Subtotal</span><span>NPR {fmt(subtotal)}</span></div>
          <div className="inv-total-row"><span>VAT</span><span>NPR {fmt(vatTotal)}</span></div>
          <div className="inv-total-row inv-grand-total">
            <span>Total {isCN?"Credit":"Debit"}</span>
            <span>NPR {fmt(total)}</span>
          </div>
        </div>
      )}

      {err && <p className="msg err">{err}</p>}
      <div style={{display:"flex",gap:10,marginTop:12}}>
        <button className="btn" onClick={submit} disabled={busy||!form.partyName.trim()||validLines.length===0}>
          {busy?"Saving…":`Issue ${isCN?"Credit Note":"Debit Note"} & Post to Ledger`}
        </button>
        <button className="ghost-btn" onClick={onCancel}>Cancel</button>
      </div>
    </div>
  );
}

// ── Main page ─────────────────────────────────────────────────
export default function CreditDebitNotes() {
  const [noteType,   setNoteType]   = useState("cn"); // cn | dn
  const [notes,      setNotes]      = useState([]);
  const [parties,    setParties]    = useState([]);
  const [invoices,   setInvoices]   = useState([]);
  const [bills,      setBills]      = useState([]);
  const [loading,    setLoading]    = useState(true);
  const [showForm,   setShowForm]   = useState(false);
  const [printNote,  setPrintNote]  = useState(null);
  const [busy,       setBusy]       = useState(false);
  const [err,        setErr]        = useState(null);
  const { vatRate }                 = useTaxRates();

  const load = async () => {
    setLoading(true);
    try {
      const isCN = noteType === "cn";
      const [nRes, pRes, iRes, bRes] = await Promise.all([
        isCN
          ? supabase.from("credit_notes").select("*, credit_note_lines(*)").order("cn_date",{ascending:false})
          : supabase.from("debit_notes").select("*, debit_note_lines(*)").order("dn_date",{ascending:false}),
        listParties(),
        supabase.from("invoices").select("id,invoice_number,party_name,party_id,party_pan,total,invoice_lines(*)").neq("status","cancelled").order("invoice_date",{ascending:false}),
        supabase.from("purchase_bills").select("id,bill_number,vendor_name,vendor_id,vendor_pan,total").neq("status","cancelled").order("bill_date",{ascending:false}),
      ]);
      setNotes(nRes.data||[]);
      setParties(pRes);
      setInvoices(iRes.data||[]);
      setBills(bRes.data||[]);
    } catch(e) { setErr(e.message); }
    setLoading(false);
  };

  useEffect(() => { load(); }, [noteType]);

  const handleSave = async (header, lines) => {
    setBusy(true); setErr(null);
    try {
      const fn = noteType === "cn" ? "create_credit_note" : "create_debit_note";
      const { data: noteId, error } = await supabase.rpc(fn, { p_header: header, p_lines: lines });
      if (error) throw error;
      setShowForm(false);
      await load();
      // Auto-open print
      const table = noteType === "cn" ? "credit_notes" : "debit_notes";
      const sel   = noteType === "cn" ? "*, credit_note_lines(*)" : "*, debit_note_lines(*)";
      const { data: n } = await supabase.from(table).select(sel).eq("id",noteId).single();
      setPrintNote(n);
    } catch(e) { setErr(e.message); }
    setBusy(false);
  };

  if (printNote) return (
    <NotePrint note={printNote} noteType={noteType} onClose={()=>setPrintNote(null)} />
  );

  return (
    <div className="panel">
      <div className="panel-head">
        <h2>Credit &amp; Debit Notes</h2>
        <button className="btn" onClick={()=>setShowForm(s=>!s)}>
          {showForm?"Cancel":`+ New ${noteType==="cn"?"Credit Note":"Debit Note"}`}
        </button>
      </div>

      {/* Type switcher */}
      <div className="filter-tabs" style={{marginBottom:16}}>
        <button className={"filter-tab"+(noteType==="cn"?" active":"")} onClick={()=>{setNoteType("cn");setShowForm(false);}}>
          📄 Credit Notes (Sales Returns)
        </button>
        <button className={"filter-tab"+(noteType==="dn"?" active":"")} onClick={()=>{setNoteType("dn");setShowForm(false);}}>
          📋 Debit Notes (Purchase Returns)
        </button>
      </div>

      {/* Info box */}
      <div className="settings-info-box" style={{marginBottom:16}}>
        {noteType === "cn"
          ? "Credit Note reduces a customer's balance. Use when goods are returned or an invoice was overcharged. Posts: Dr Sales / Dr VAT Payable / Cr Customer."
          : "Debit Note reduces your vendor payable. Use when you return goods to a vendor or were overcharged. Posts: Dr Vendor / Cr Purchase / Cr VAT Receivable."}
      </div>

      {showForm && (
        <NoteForm noteType={noteType} parties={parties} invoices={invoices} bills={bills}
          vatRate={vatRate} onSave={handleSave} onCancel={()=>setShowForm(false)}
          busy={busy} err={err} />
      )}

      {err && !showForm && <p className="msg err">{err}</p>}

      {loading ? <p className="note">Loading…</p> :
       notes.length === 0 ? (
        <p className="note">
          No {noteType==="cn"?"credit":"debit"} notes yet.
          {" "}Create one when a customer returns goods or you return to a vendor.
        </p>
      ) : (
        <table className="tbl">
          <thead>
            <tr>
              <th>#</th>
              <th>Date</th>
              <th>{noteType==="cn"?"Customer":"Vendor"}</th>
              <th>Reason</th>
              <th>Linked To</th>
              <th className="num">Total</th>
              <th>Status</th>
              <th/>
            </tr>
          </thead>
          <tbody>
            {notes.map(n=>{
              const num  = noteType==="cn" ? n.cn_number : n.dn_number;
              const date = noteType==="cn" ? n.cn_date   : n.dn_date;
              const party= noteType==="cn" ? n.party_name : n.vendor_name;
              const linked = noteType==="cn"
                ? (n.invoice_number ? `Invoice #${n.invoice_number}` : "—")
                : (n.bill_number    ? `Bill #${n.bill_number}`        : "—");
              return (
                <tr key={n.id}>
                  <td><b>{noteType==="cn"?"CN":"DN"}-{String(num).padStart(4,"0")}</b></td>
                  <td style={{fontSize:12}}>{date}</td>
                  <td>{party}</td>
                  <td style={{fontSize:12,color:"var(--ink2)"}}>{n.reason||"—"}</td>
                  <td style={{fontSize:12}}>{linked}</td>
                  <td className="num"><b>NPR {fmt(n.total)}</b></td>
                  <td><span className={"status-"+n.status}>{n.status}</span></td>
                  <td><button className="link" onClick={()=>setPrintNote(n)}>Print</button></td>
                </tr>
              );
            })}
          </tbody>
          <tfoot>
            <tr>
              <td colSpan={5}><b>Total</b></td>
              <td className="num"><b>NPR {fmt(notes.reduce((s,n)=>s+Number(n.total),0))}</b></td>
              <td colSpan={2}/>
            </tr>
          </tfoot>
        </table>
      )}
    </div>
  );
}
