import React, { useEffect, useState } from "react";
import { useTaxRates, DEFAULT_TDS_TYPES } from "../lib/taxRates";
import { supabase } from "../supabase";
import { currentFiscalYear } from "../lib/fiscalYear";
import { formatDualDate } from "../lib/nepaliCalendar";
import { listParties } from "../lib/db";

// TDS types are loaded from the database via useTaxRates()

const fmt = (n) => Number(n||0).toLocaleString(undefined,{minimumFractionDigits:2,maximumFractionDigits:2});

// ── DB helpers ────────────────────────────────────────────────
async function listEntries(status) {
  let q = supabase.from("tds_entries").select("*").order("entry_date", {ascending:false});
  if (status && status !== "all") q = q.eq("status", status);
  const { data, error } = await q;
  if (error) throw error;
  return data;
}

async function listRemittances() {
  const { data, error } = await supabase.from("tds_remittances").select("*").order("remittance_date",{ascending:false});
  if (error) throw error;
  return data;
}

// ── TDS Certificate print view ─────────────────────────────────
function TDSCertificate({ entries, payeeName, onClose }) {
  const totGross = entries.reduce((s,e) => s+Number(e.gross_amount),0);
  const totTds   = entries.reduce((s,e) => s+Number(e.tds_amount),0);
  const totNet   = entries.reduce((s,e) => s+Number(e.net_amount),0);
  return (
    <div className="print-overlay">
      <div className="print-actions no-print" style={{display:"flex",gap:12,marginBottom:20}}>
        <button className="btn" onClick={()=>window.print()}>🖨 Print Certificate</button>
        <button className="link" onClick={onClose}>← Back</button>
      </div>
      <div className="invoice-paper">
        <div className="inv-header">
          <div style={{flex:1}}>
            <div className="inv-title" style={{fontSize:18}}>TDS CERTIFICATE</div>
            <div className="inv-title-sub">कर कट्टी प्रमाणपत्र</div>
            <div style={{fontSize:12,color:"#555",marginTop:4}}>
              As per Income Tax Act 2058 — Section 87 & 88
            </div>
          </div>
          <div style={{textAlign:"right",fontSize:12}}>
            <div><b>Deductor (कट्टा गर्ने):</b></div>
            <div>Your Business Name</div>
            <div style={{color:"#888"}}>PAN: —</div>
          </div>
        </div>

        <div className="inv-meta" style={{marginTop:12}}>
          <div className="inv-meta-left">
            <div><b>Deductee (कट्टा भएको व्यक्ति):</b></div>
            <div style={{fontWeight:600,fontSize:15}}>{payeeName}</div>
            <div style={{fontSize:12,color:"#555"}}>PAN: {entries[0]?.payee_pan || "—"}</div>
          </div>
          <div className="inv-meta-right">
            <div><b>Period:</b> {entries[0]?.fiscal_year}</div>
            <div><b>Entries:</b> {entries.length} payment(s)</div>
          </div>
        </div>

        <table className="inv-table" style={{marginTop:16}}>
          <thead>
            <tr>
              <th>Date</th><th>Type</th><th>Ref</th>
              <th className="r">Gross (NPR)</th>
              <th className="r">Rate %</th>
              <th className="r">TDS (NPR)</th>
              <th className="r">Net Paid</th>
            </tr>
          </thead>
          <tbody>
            {entries.map(e=>(
              <tr key={e.id}>
                <td style={{fontSize:11}}>{e.entry_date}</td>
                <td style={{fontSize:11}}>{TDS_TYPES.find(t=>t.type===e.tds_type)?.label||e.tds_type}</td>
                <td style={{fontSize:11}}>{e.reference||"—"}</td>
                <td className="r">{fmt(e.gross_amount)}</td>
                <td className="r">{e.tds_rate}%</td>
                <td className="r">{fmt(e.tds_amount)}</td>
                <td className="r">{fmt(e.net_amount)}</td>
              </tr>
            ))}
          </tbody>
          <tfoot>
            <tr className="inv-total-row">
              <td colSpan={3}><b>TOTAL</b></td>
              <td className="r"><b>{fmt(totGross)}</b></td>
              <td/>
              <td className="r"><b>{fmt(totTds)}</b></td>
              <td className="r"><b>{fmt(totNet)}</b></td>
            </tr>
          </tfoot>
        </table>

        <div style={{marginTop:24,padding:"12px 16px",background:"#f8f8f6",borderRadius:8,fontSize:12}}>
          <b>Certified that the above TDS has been deducted as per prevailing law and will be/has been remitted to Inland Revenue Department (IRD), Nepal.</b>
        </div>

        <div className="inv-footer" style={{marginTop:32}}>
          <div><div className="inv-sign"><div className="inv-sign-line"/><div>Deductee Signature</div></div></div>
          <div style={{textAlign:"center",fontSize:11,color:"#888"}}>
            This is a computer-generated TDS certificate.
          </div>
          <div><div className="inv-sign"><div className="inv-sign-line"/><div>Authorised Signatory / Stamp</div></div></div>
        </div>
      </div>
    </div>
  );
}

// ── Main TDS page ─────────────────────────────────────────────
export default function TDS({ userId }) {
  const { tdsTypes: TDS_TYPES } = useTaxRates(); // from DB, falls back to statutory rates
  const [entries,     setEntries]     = useState([]);
  const [remittances, setRemittances] = useState([]);
  const [parties,     setParties]     = useState([]);
  const [loading,     setLoading]     = useState(true);
  const [err,         setErr]         = useState(null);
  const [busy,        setBusy]        = useState(false);
  const [view,        setView]        = useState("pending"); // pending | all | remittances
  const [showForm,    setShowForm]    = useState(false);
  const [showRemit,   setShowRemit]   = useState(false);
  const [certEntries, setCertEntries] = useState(null);
  const [certPayee,   setCertPayee]   = useState("");
  const [selected,    setSelected]    = useState(new Set()); // for remittance selection

  const fy = currentFiscalYear();

  const [form, setForm] = useState({
    date: new Date().toISOString().slice(0,10),
    fiscalYear: fy,
    tdsType: "rent",
    payeeName: "", payeePan: "", payeeId: "",
    gross: "", rate: "10",
    mode: "bank", reference: "", notes: "",
  });

  const [remitForm, setRemitForm] = useState({
    date: new Date().toISOString().slice(0,10),
    periodLabel: "",
    mode: "bank", challanNo: "", notes: "",
  });

  const load = async () => {
    setLoading(true);
    try {
      const [ents, rems, pts] = await Promise.all([
        listEntries("all"), listRemittances(), listParties()
      ]);
      setEntries(ents); setRemittances(rems); setParties(pts);
    } catch(e) { setErr(e.message); }
    setLoading(false);
  };

  useEffect(() => { load(); }, []);

  const selectType = (type) => {
    const t = TDS_TYPES.find(t=>t.type===type);
    setForm(f=>({...f, tdsType:type, rate:String(t?.rate||10)}));
  };

  const selectParty = (partyId) => {
    const p = parties.find(p=>p.id===partyId);
    if (p) setForm(f=>({...f, payeeId:partyId, payeeName:p.accounts?.name||"", payeePan:p.pan_vat_number||""}));
    else    setForm(f=>({...f, payeeId:"", payeeName:"", payeePan:""}));
  };

  const tdsAmt  = Math.round((parseFloat(form.gross)||0) * (parseFloat(form.rate)||0) / 100 * 100) / 100;
  const netAmt  = (parseFloat(form.gross)||0) - tdsAmt;

  const submit = async (e) => {
    e.preventDefault();
    if (!form.payeeName.trim()) { setErr("Payee name required."); return; }
    if (!parseFloat(form.gross))  { setErr("Enter gross amount."); return; }
    setBusy(true); setErr(null);
    try {
      const { error } = await supabase.rpc("create_tds_entry", {
        p_date:        form.date,
        p_fiscal_year: form.fiscalYear,
        p_tds_type:    form.tdsType,
        p_payee_name:  form.payeeName.trim(),
        p_payee_pan:   form.payeePan.trim() || null,
        p_payee_id:    form.payeeId || null,
        p_gross:       parseFloat(form.gross),
        p_rate:        parseFloat(form.rate),
        p_mode:        form.mode,
        p_reference:   form.reference.trim() || null,
        p_notes:       form.notes.trim() || null,
      });
      if (error) throw error;
      setShowForm(false);
      setForm(f=>({...f, payeeName:"", payeePan:"", payeeId:"", gross:"", reference:"", notes:""}));
      await load();
    } catch(e) { setErr(e.message); }
    setBusy(false);
  };

  const remit = async () => {
    if (selected.size === 0) { setErr("Select at least one entry to remit."); return; }
    if (!remitForm.periodLabel.trim()) { setErr("Enter the period (e.g. Shrawan 2081)."); return; }
    setBusy(true); setErr(null);
    try {
      const { error } = await supabase.rpc("remit_tds", {
        p_entry_ids:    Array.from(selected),
        p_date:         remitForm.date,
        p_fiscal_year:  fy,
        p_period_label: remitForm.periodLabel.trim(),
        p_mode:         remitForm.mode,
        p_challan_no:   remitForm.challanNo.trim() || null,
        p_notes:        remitForm.notes.trim() || null,
      });
      if (error) throw error;
      setShowRemit(false); setSelected(new Set());
      await load();
    } catch(e) { setErr(e.message); }
    setBusy(false);
  };

  const toggleSelect = (id) => {
    setSelected(s => { const n = new Set(s); n.has(id) ? n.delete(id) : n.add(id); return n; });
  };

  const pending   = entries.filter(e=>e.status==="deducted");
  const allByView = view === "pending" ? pending
                  : view === "all"     ? entries
                  : [];

  const totalPending = pending.reduce((s,e)=>s+Number(e.tds_amount),0);
  const totalDeducted = entries.filter(e=>e.status==="deducted").reduce((s,e)=>s+Number(e.tds_amount),0);
  const totalRemitted = entries.filter(e=>e.status==="remitted").reduce((s,e)=>s+Number(e.tds_amount),0);

  if (certEntries) return (
    <TDSCertificate entries={certEntries} payeeName={certPayee} onClose={()=>setCertEntries(null)} />
  );

  return (
    <div className="panel">
      <div className="panel-head">
        <h2>TDS — Tax Deducted at Source</h2>
        <div style={{display:"flex",gap:8}}>
          {pending.length > 0 && (
            <button className="ghost-btn" onClick={()=>{setShowRemit(s=>!s);setShowForm(false);}}>
              {showRemit?"Cancel":"📤 Remit to IRD"}
            </button>
          )}
          <button className="btn" onClick={()=>{setShowForm(s=>!s);setShowRemit(false);}}>
            {showForm?"Cancel":"+ Record TDS"}
          </button>
        </div>
      </div>

      {/* Summary stats */}
      <div className="stat-row">
        <div className="stat"><span style={{color:"var(--rust)"}}>NPR {fmt(totalPending)}</span>Pending Remittance</div>
        <div className="stat"><span>NPR {fmt(totalDeducted)}</span>Deducted (not remitted)</div>
        <div className="stat"><span style={{color:"var(--green2)"}}>NPR {fmt(totalRemitted)}</span>Remitted to IRD</div>
        <div className="stat"><span>{pending.length}</span>Pending entries</div>
      </div>

      {totalPending > 0 && (
        <div className="alert-bar">
          ⚠ NPR {fmt(totalPending)} in TDS is pending remittance to IRD.
          IRD deadline: 25th of following month.
          <button className="link" style={{display:"inline",marginLeft:8}} onClick={()=>{setShowRemit(true);setShowForm(false);}}>Remit now →</button>
        </div>
      )}

      {/* New TDS entry form */}
      {showForm && (
        <form className="inv-form" onSubmit={submit} style={{marginBottom:16}}>
          <b style={{display:"block",marginBottom:8}}>Record TDS Deduction</b>
          <div className="inv-form-top">
            <label className="fld">Payment Type
              <select value={form.tdsType} onChange={e=>selectType(e.target.value)}>
                {TDS_TYPES.map(t=><option key={t.type} value={t.type}>{t.label} ({t.rate}%)</option>)}
              </select>
            </label>
            <label className="fld">Date <input type="date" value={form.date} onChange={e=>setForm(f=>({...f,date:e.target.value}))} /></label>
            <label className="fld">Fiscal Year <input value={form.fiscalYear} onChange={e=>setForm(f=>({...f,fiscalYear:e.target.value}))} /></label>
            <label className="fld">Payee (Party)
              <select value={form.payeeId} onChange={e=>selectParty(e.target.value)}>
                <option value="">— type below or pick party —</option>
                {parties.filter(p=>p.party_type==="vendor"||p.party_type==="both").map(p=>(
                  <option key={p.id} value={p.id}>{p.accounts?.name}</option>
                ))}
              </select>
            </label>
            <label className="fld">Payee Name <input placeholder="Landlord / Consultant name" value={form.payeeName} onChange={e=>setForm(f=>({...f,payeeName:e.target.value}))} required /></label>
            <label className="fld">Payee PAN <input placeholder="PAN number" value={form.payeePan} onChange={e=>setForm(f=>({...f,payeePan:e.target.value}))} /></label>
            <label className="fld">Gross Amount (NPR)
              <input type="number" step="0.01" placeholder="0" value={form.gross} onChange={e=>setForm(f=>({...f,gross:e.target.value}))} required />
            </label>
            <label className="fld">TDS Rate (%)
              <input type="number" step="0.01" value={form.rate} onChange={e=>setForm(f=>({...f,rate:e.target.value}))} />
            </label>
            <label className="fld">Pay via
              <select value={form.mode} onChange={e=>setForm(f=>({...f,mode:e.target.value}))}>
                <option value="bank">Bank</option>
                <option value="cash">Cash</option>
              </select>
            </label>
            <label className="fld">Cheque / Ref No <input placeholder="Optional" value={form.reference} onChange={e=>setForm(f=>({...f,reference:e.target.value}))} /></label>
          </div>

          {/* Live calculation */}
          {parseFloat(form.gross) > 0 && (
            <div className="tds-calc-box">
              <div className="tds-calc-row"><span>Gross Amount</span><b>NPR {fmt(parseFloat(form.gross))}</b></div>
              <div className="tds-calc-row" style={{color:"var(--rust)"}}><span>TDS @ {form.rate}%</span><b>− NPR {fmt(tdsAmt)}</b></div>
              <div className="tds-calc-row tds-calc-total"><span>Net paid to payee</span><b>NPR {fmt(netAmt)}</b></div>
            </div>
          )}

          {err && <p className="msg err">{err}</p>}
          <button className="btn" disabled={busy}>{busy?"Saving…":"Save & Post to Ledger"}</button>
        </form>
      )}

      {/* Remit to IRD form */}
      {showRemit && (
        <div className="biz-form" style={{marginBottom:16}}>
          <b style={{display:"block",marginBottom:8}}>Remit TDS to IRD — select entries below then fill details</b>
          <div className="inv-form-top">
            <label className="fld">Remittance Date <input type="date" value={remitForm.date} onChange={e=>setRemitForm(f=>({...f,date:e.target.value}))} /></label>
            <label className="fld">Period <input placeholder="e.g. Shrawan 2081 or July 2024" value={remitForm.periodLabel} onChange={e=>setRemitForm(f=>({...f,periodLabel:e.target.value}))} /></label>
            <label className="fld">Pay via <select value={remitForm.mode} onChange={e=>setRemitForm(f=>({...f,mode:e.target.value}))}><option value="bank">Bank</option><option value="cash">Cash</option></select></label>
            <label className="fld">IRD Challan No <input placeholder="Optional" value={remitForm.challanNo} onChange={e=>setRemitForm(f=>({...f,challanNo:e.target.value}))} /></label>
          </div>
          {selected.size > 0 && (
            <div className="tds-calc-box">
              <div className="tds-calc-row tds-calc-total">
                <span>Total TDS to remit ({selected.size} entries)</span>
                <b>NPR {fmt(pending.filter(e=>selected.has(e.id)).reduce((s,e)=>s+Number(e.tds_amount),0))}</b>
              </div>
            </div>
          )}
          {err && <p className="msg err">{err}</p>}
          <button className="btn" onClick={remit} disabled={busy||selected.size===0}>
            {busy?"Processing…":"Remit to IRD & Post Voucher"}
          </button>
        </div>
      )}

      {/* View tabs */}
      <div className="filter-tabs">
        {[["pending","Pending Remittance"],["all","All Entries"],["remittances","Remittance History"]].map(([k,l])=>(
          <button key={k} className={"filter-tab"+(view===k?" active":"")} onClick={()=>setView(k)}>{l}</button>
        ))}
      </div>

      {loading ? <p className="note">Loading…</p> : (

        view === "remittances" ? (
          /* Remittance history */
          remittances.length === 0 ? <p className="note">No remittances yet.</p> : (
            <table className="tbl" style={{marginTop:8}}>
              <thead><tr><th>Date</th><th>Period</th><th className="num">Total TDS</th><th>Challan No</th><th>Mode</th></tr></thead>
              <tbody>
                {remittances.map(r=>(
                  <tr key={r.id}>
                    <td>{r.remittance_date}</td>
                    <td>{r.period_label}</td>
                    <td className="num"><b>NPR {fmt(r.total_tds)}</b></td>
                    <td>{r.challan_no||"—"}</td>
                    <td>{r.payment_mode}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          )
        ) : (

          /* Entry list */
          allByView.length === 0 ? (
            <p className="note">{view==="pending" ? "No pending TDS — all remitted ✓" : "No TDS entries yet."}</p>
          ) : (
            <table className="tbl" style={{marginTop:8}}>
              <thead>
                <tr>
                  {showRemit && view==="pending" && <th/>}
                  <th>Date</th><th>Type</th><th>Payee</th><th>PAN</th>
                  <th className="num">Gross</th><th className="num">Rate</th>
                  <th className="num">TDS</th><th className="num">Net Paid</th>
                  <th>Status</th><th/>
                </tr>
              </thead>
              <tbody>
                {allByView.map(e=>(
                  <tr key={e.id}>
                    {showRemit && view==="pending" && (
                      <td><input type="checkbox" checked={selected.has(e.id)} onChange={()=>toggleSelect(e.id)} /></td>
                    )}
                    <td style={{fontSize:12}}>{e.entry_date}</td>
                    <td><span className="tag">{TDS_TYPES.find(t=>t.type===e.tds_type)?.label||e.tds_type}</span></td>
                    <td><b>{e.payee_name}</b></td>
                    <td className="muted" style={{fontSize:11}}>{e.payee_pan||"—"}</td>
                    <td className="num">{fmt(e.gross_amount)}</td>
                    <td className="num">{e.tds_rate}%</td>
                    <td className="num" style={{color:"var(--rust)"}}><b>{fmt(e.tds_amount)}</b></td>
                    <td className="num">{fmt(e.net_amount)}</td>
                    <td><span className={e.status==="remitted"?"status-paid":"status-sent"}>{e.status}</span></td>
                    <td>
                      <button className="link" onClick={()=>{
                        // Show certificate for all entries from this payee in this FY
                        const payeeEntries = entries.filter(x=>x.payee_name===e.payee_name&&x.fiscal_year===e.fiscal_year);
                        setCertEntries(payeeEntries);
                        setCertPayee(e.payee_name);
                      }}>Certificate</button>
                    </td>
                  </tr>
                ))}
              </tbody>
              <tfoot>
                <tr>
                  {showRemit && view==="pending" && <td/>}
                  <td colSpan={4}><b>Total</b></td>
                  <td className="num"><b>{fmt(allByView.reduce((s,e)=>s+Number(e.gross_amount),0))}</b></td>
                  <td/>
                  <td className="num"><b>NPR {fmt(allByView.reduce((s,e)=>s+Number(e.tds_amount),0))}</b></td>
                  <td className="num"><b>{fmt(allByView.reduce((s,e)=>s+Number(e.net_amount),0))}</b></td>
                  <td colSpan={showRemit && view==="pending"?2:1}/>
                </tr>
              </tfoot>
            </table>
          )
        )
      )}
    </div>
  );
}
