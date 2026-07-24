import React, { useEffect, useState } from "react";
import { supabase } from "../supabase";
import { currentFiscalYear } from "../lib/fiscalYear";
import { todayLocalDate, toLocalDateString } from "../lib/nepaliCalendar";

const fmt  = (n) => Number(n||0).toLocaleString(undefined,{minimumFractionDigits:2,maximumFractionDigits:2});
const fmtD = (d) => d ? new Date(d).toLocaleDateString("en-NP") : "—";

// ── DB helpers ────────────────────────────────────────────────
async function fetchBankAccounts() {
  const { data } = await supabase.from("accounts").select("id,name,account_code,account_subtype")
    .in("account_subtype",["bank","cash"]).eq("is_active",true).order("account_code");
  return data || [];
}

async function fetchStatements() {
  const { data, error } = await supabase.from("bank_statements")
    .select("*").order("from_date",{ascending:false});
  if (error) throw error;
  return data || [];
}

async function fetchLines(statementId) {
  const { data, error } = await supabase.from("bank_statement_lines")
    .select("*, vouchers(voucher_type,voucher_number,narration)")
    .eq("statement_id", statementId).order("txn_date");
  if (error) throw error;
  return data || [];
}

async function fetchVouchers(accountId, fromDate, toDate) {
  // Get voucher lines for this bank/cash account in the period
  const { data, error } = await supabase.from("voucher_lines")
    .select("*, vouchers!inner(id,voucher_type,voucher_number,voucher_date,narration,is_void,fiscal_year)")
    .eq("account_id", accountId)
    .eq("vouchers.is_void", false)
    .gte("vouchers.voucher_date", fromDate)
    .lte("vouchers.voucher_date", toDate)
    .order("vouchers(voucher_date)");
  if (error) throw error;
  return data || [];
}

// ── Reconciliation print view ─────────────────────────────────
function ReconciliationPrint({ stmt, lines, ledgerBalance, onClose }) {
  const matched    = lines.filter(l=>l.is_matched);
  const unmatched  = lines.filter(l=>!l.is_matched);
  const totalDep   = lines.reduce((s,l)=>s+Number(l.deposits),0);
  const totalWith  = lines.reduce((s,l)=>s+Number(l.withdrawals),0);
  const diff       = Number(stmt.closing_balance) - ledgerBalance;

  return (
    <div className="print-overlay">
      <div className="print-actions no-print" style={{display:"flex",gap:12,marginBottom:20}}>
        <button className="btn" onClick={()=>window.print()}>🖨 Print</button>
        <button className="link" onClick={onClose}>← Back</button>
      </div>
      <div className="invoice-paper">
        <div className="inv-header">
          <div style={{flex:1}}>
            <div className="inv-title" style={{fontSize:18}}>Bank Reconciliation Statement</div>
            <div className="inv-title-sub">बैंक मिलान विवरण</div>
          </div>
          <div style={{textAlign:"right",fontSize:12}}>
            <div><b>Account:</b> {stmt.account_name}</div>
            <div><b>Period:</b> {stmt.from_date} to {stmt.to_date}</div>
          </div>
        </div>

        <table className="inv-table" style={{marginTop:16}}>
          <thead><tr><th>Particulars</th><th className="r">Amount (NPR)</th></tr></thead>
          <tbody>
            <tr><td><b>Balance as per Bank Statement</b></td><td className="r"><b>{fmt(stmt.closing_balance)}</b></td></tr>
            <tr><td colSpan={2} style={{background:"#f8f8f6",fontWeight:600,fontSize:12,padding:"6px 8px"}}>Add: Amounts in ledger not yet in bank (Outstanding Deposits)</td></tr>
            {unmatched.filter(l=>l.deposits>0).map(l=>(
              <tr key={l.id}><td style={{paddingLeft:24,fontSize:12}}>{l.txn_date} — {l.description}</td><td className="r">{fmt(l.deposits)}</td></tr>
            ))}
            <tr><td colSpan={2} style={{background:"#f8f8f6",fontWeight:600,fontSize:12,padding:"6px 8px"}}>Less: Amounts in ledger not yet in bank (Outstanding Withdrawals)</td></tr>
            {unmatched.filter(l=>l.withdrawals>0).map(l=>(
              <tr key={l.id}><td style={{paddingLeft:24,fontSize:12}}>{l.txn_date} — {l.description}</td><td className="r">({fmt(l.withdrawals)})</td></tr>
            ))}
            <tr className="inv-total-row">
              <td><b>Balance as per Ledger</b></td>
              <td className="r"><b>{fmt(ledgerBalance)}</b></td>
            </tr>
          </tbody>
        </table>

        <div style={{marginTop:16,padding:"10px 14px",background: Math.abs(diff)<0.5?"#e8f5f0":"#fef0ee",borderRadius:8,fontSize:13}}>
          {Math.abs(diff)<0.5
            ? "✓ Reconciliation complete — bank statement matches ledger balance."
            : `⚠ Difference of NPR ${fmt(Math.abs(diff))} — investigate unmatched items.`}
        </div>

        <div className="inv-footer" style={{marginTop:32}}>
          <div><div className="inv-sign"><div className="inv-sign-line"/><div>Prepared by</div></div></div>
          <div><div className="inv-sign"><div className="inv-sign-line"/><div>Approved by</div></div></div>
        </div>
      </div>
    </div>
  );
}

// ── Main Bank Reconciliation page ─────────────────────────────
export default function BankReconciliation() {
  const [statements,    setStatements]    = useState([]);
  const [bankAccounts,  setBankAccounts]  = useState([]);
  const [activeStmt,    setActiveStmt]    = useState(null);
  const [lines,         setLines]         = useState([]);
  const [vouchers,      setVouchers]      = useState([]);
  const [loading,       setLoading]       = useState(true);
  const [busy,          setBusy]          = useState(false);
  const [err,           setErr]           = useState(null);
  const [showNewStmt,   setShowNewStmt]   = useState(false);
  const [showAddLine,   setShowAddLine]   = useState(false);
  const [showPrint,     setShowPrint]     = useState(false);
  const [selectedLine,  setSelectedLine]  = useState(null); // for matching

  const [stmtForm, setStmtForm] = useState({
    accountId: "", fromDate: "", toDate: "",
    openingBalance: "", closingBalance: "", notes: "",
  });

  const [lineForm, setLineForm] = useState({
    txnDate: todayLocalDate(),
    description: "", reference: "",
    deposits: "", withdrawals: "", balance: "",
  });

  const [csvText, setCsvText] = useState("");
  const [showCsv, setShowCsv] = useState(false);

  const load = async () => {
    setLoading(true);
    try {
      const [stmts, accts] = await Promise.all([fetchStatements(), fetchBankAccounts()]);
      setStatements(stmts);
      setBankAccounts(accts);
    } catch(e) { setErr(e.message); }
    setLoading(false);
  };

  const loadLines = async (stmt) => {
    setActiveStmt(stmt);
    setLoading(true);
    try {
      const [ls, vs] = await Promise.all([
        fetchLines(stmt.id),
        fetchVouchers(stmt.account_id, stmt.from_date, stmt.to_date),
      ]);
      setLines(ls);
      setVouchers(vs);
    } catch(e) { setErr(e.message); }
    setLoading(false);
  };

  useEffect(() => { load(); }, []);

  const createStatement = async () => {
    if (!stmtForm.accountId) { setErr("Select a bank account."); return; }
    if (!stmtForm.fromDate || !stmtForm.toDate) { setErr("Enter date range."); return; }
    setBusy(true); setErr(null);
    try {
      const { data, error } = await supabase.rpc("create_bank_statement", {
        p_account_id:      stmtForm.accountId,
        p_from_date:       stmtForm.fromDate,
        p_to_date:         stmtForm.toDate,
        p_opening_balance: parseFloat(stmtForm.openingBalance)||0,
        p_closing_balance: parseFloat(stmtForm.closingBalance)||0,
        p_notes:           stmtForm.notes.trim()||null,
      });
      if (error) throw error;
      setShowNewStmt(false);
      await load();
      await loadLines(data);
    } catch(e) { setErr(e.message); }
    setBusy(false);
  };

  const addLine = async () => {
    if (!lineForm.description.trim()) { setErr("Enter description."); return; }
    const dep = parseFloat(lineForm.deposits)||0;
    const wit = parseFloat(lineForm.withdrawals)||0;
    if (dep===0 && wit===0) { setErr("Enter deposits or withdrawals amount."); return; }
    setBusy(true); setErr(null);
    try {
      const { error } = await supabase.rpc("add_bank_statement_line", {
        p_statement_id: activeStmt.id,
        p_txn_date:     lineForm.txnDate,
        p_description:  lineForm.description.trim(),
        p_reference:    lineForm.reference.trim()||null,
        p_deposits:     dep,
        p_withdrawals:  wit,
        p_balance:      parseFloat(lineForm.balance)||null,
      });
      if (error) throw error;
      setLineForm({txnDate:todayLocalDate(),description:"",reference:"",deposits:"",withdrawals:"",balance:""});
      await loadLines(activeStmt);
    } catch(e) { setErr(e.message); }
    setBusy(false);
  };

  const importCsv = async () => {
    // Parse CSV: Date, Description, Withdrawals, Deposits, Balance
    const rows = csvText.trim().split("\n").map(r=>r.split(",").map(c=>c.trim().replace(/"/g,"")));
    const validRows = rows.filter(r=>r.length>=4 && r[0] && !isNaN(new Date(r[0]).getTime()));
    if (validRows.length === 0) { setErr("No valid rows found. Format: Date, Description, Withdrawals, Deposits, Balance"); return; }
    setBusy(true); setErr(null);
    try {
      const lines = validRows.map(r=>({
        txn_date:    toLocalDateString(new Date(r[0])),
        description: r[1]||"",
        withdrawals: parseFloat(r[2])||0,
        deposits:    parseFloat(r[3])||0,
        balance:     r[4] ? parseFloat(r[4])||null : null,
      }));
      const { error } = await supabase.rpc("import_bank_statement_lines", {
        p_statement_id: activeStmt.id,
        p_lines: lines,
      });
      if (error) throw error;
      setCsvText(""); setShowCsv(false);
      await loadLines(activeStmt);
    } catch(e) { setErr(e.message); }
    setBusy(false);
  };

  const matchLine = async (lineId, voucherId) => {
    await supabase.rpc("match_statement_line", { p_line_id: lineId, p_voucher_id: voucherId });
    setSelectedLine(null);
    await loadLines(activeStmt);
  };

  const unmatchLine = async (lineId) => {
    await supabase.rpc("unmatch_statement_line", { p_line_id: lineId });
    await loadLines(activeStmt);
  };

  const finalizeReconciliation = async () => {
    if (!confirm("Mark this reconciliation as complete? You can still view it afterwards.")) return;
    await supabase.rpc("reconcile_statement", { p_statement_id: activeStmt.id });
    await load();
    setActiveStmt(s=>({...s, status:"reconciled"}));
  };

  // Summary calculations
  const totalDep      = lines.reduce((s,l)=>s+Number(l.deposits),0);
  const totalWith     = lines.reduce((s,l)=>s+Number(l.withdrawals),0);
  const matchedCount  = lines.filter(l=>l.is_matched).length;
  const unmatchedDep  = lines.filter(l=>!l.is_matched&&l.deposits>0).reduce((s,l)=>s+Number(l.deposits),0);
  const unmatchedWith = lines.filter(l=>!l.is_matched&&l.withdrawals>0).reduce((s,l)=>s+Number(l.withdrawals),0);

  // Ledger balance = opening + all deposits - all withdrawals (matched)
  const ledgerBalance = Number(activeStmt?.opening_balance||0) + totalDep - totalWith;
  const diff          = Number(activeStmt?.closing_balance||0) - ledgerBalance;
  const isBalanced    = Math.abs(diff) < 0.5;

  // Vouchers not yet matched to any line
  const matchedVoucherIds = new Set(lines.filter(l=>l.matched_voucher_id).map(l=>l.matched_voucher_id));
  const unmatchedVouchers = vouchers.filter(v=>!matchedVoucherIds.has(v.vouchers?.id));

  if (showPrint && activeStmt) return (
    <ReconciliationPrint stmt={activeStmt} lines={lines}
      ledgerBalance={ledgerBalance} onClose={()=>setShowPrint(false)} />
  );

  return (
    <div className="panel">
      <div className="panel-head">
        <h2>Bank Reconciliation (बैंक मिलान)</h2>
        {!activeStmt && (
          <button className="btn" onClick={()=>setShowNewStmt(s=>!s)}>
            {showNewStmt ? "Cancel" : "+ New Reconciliation"}
          </button>
        )}
        {activeStmt && (
          <div style={{display:"flex",gap:8}}>
            <button className="ghost-btn" onClick={()=>setShowPrint(true)}>🖨 Print Statement</button>
            {activeStmt.status==="open" && isBalanced && (
              <button className="btn" onClick={finalizeReconciliation}>✓ Finalise</button>
            )}
            <button className="link" onClick={()=>{setActiveStmt(null);setLines([]);setVouchers([]);}}>
              ← All Statements
            </button>
          </div>
        )}
      </div>

      {err && <p className="msg err">{err}</p>}

      {/* ── New statement form ── */}
      {showNewStmt && !activeStmt && (
        <div className="biz-form" style={{marginBottom:16}}>
          <b style={{display:"block",marginBottom:8}}>New Bank Reconciliation</b>
          <div className="inv-form-top">
            <label className="fld">Bank / Cash Account
              <select value={stmtForm.accountId} onChange={e=>setStmtForm(f=>({...f,accountId:e.target.value}))}>
                <option value="">Select account…</option>
                {bankAccounts.map(a=><option key={a.id} value={a.id}>{a.name}</option>)}
              </select>
            </label>
            <label className="fld">From Date <input type="date" value={stmtForm.fromDate} onChange={e=>setStmtForm(f=>({...f,fromDate:e.target.value}))} /></label>
            <label className="fld">To Date   <input type="date" value={stmtForm.toDate}   onChange={e=>setStmtForm(f=>({...f,toDate:e.target.value}))} /></label>
            <label className="fld">Opening Balance (per bank)
              <input type="number" step="0.01" placeholder="0" value={stmtForm.openingBalance} onChange={e=>setStmtForm(f=>({...f,openingBalance:e.target.value}))} />
            </label>
            <label className="fld">Closing Balance (per bank)
              <input type="number" step="0.01" placeholder="0" value={stmtForm.closingBalance} onChange={e=>setStmtForm(f=>({...f,closingBalance:e.target.value}))} />
            </label>
          </div>
          {err && <p className="msg err">{err}</p>}
          <button className="btn" onClick={createStatement} disabled={busy}>{busy?"Creating…":"Create & Start"}</button>
        </div>
      )}

      {/* ── Statements list ── */}
      {!activeStmt && (
        loading ? <p className="note">Loading…</p> :
        statements.length === 0 ? <p className="note">No reconciliations yet. Create one above to start.</p> : (
          <table className="tbl" style={{marginTop:8}}>
            <thead><tr><th>Account</th><th>Period</th><th>Opening</th><th>Closing</th><th>Status</th><th/></tr></thead>
            <tbody>
              {statements.map(s=>(
                <tr key={s.id}>
                  <td><b>{s.account_name}</b></td>
                  <td style={{fontSize:12}}>{s.from_date} → {s.to_date}</td>
                  <td className="num">{fmt(s.opening_balance)}</td>
                  <td className="num">{fmt(s.closing_balance)}</td>
                  <td><span className={s.status==="reconciled"?"status-paid":"status-sent"}>{s.status}</span></td>
                  <td><button className="link" onClick={()=>loadLines(s)}>Open →</button></td>
                </tr>
              ))}
            </tbody>
          </table>
        )
      )}

      {/* ── Active reconciliation ── */}
      {activeStmt && (
        <>
          {/* Summary bar */}
          <div className="stat-row" style={{marginBottom:8}}>
            <div className="stat"><span>NPR {fmt(activeStmt.opening_balance)}</span>Opening (Bank)</div>
            <div className="stat"><span style={{color:"var(--green2)"}}>NPR {fmt(totalDep)}</span>Deposits</div>
            <div className="stat"><span style={{color:"var(--rust)"}}>NPR {fmt(totalWith)}</span>Withdrawals</div>
            <div className="stat"><span>NPR {fmt(activeStmt.closing_balance)}</span>Closing (Bank)</div>
            <div className="stat">
              <span style={{color:isBalanced?"var(--green2)":"var(--rust)"}}>
                {isBalanced ? "✓ Balanced" : "Δ " + fmt(Math.abs(diff))}
              </span>
              Difference
            </div>
          </div>

          {!isBalanced && (
            <div className="msg err" style={{marginBottom:12}}>
              ⚠ Difference of NPR {fmt(Math.abs(diff))}. 
              Unmatched deposits: NPR {fmt(unmatchedDep)} | Unmatched withdrawals: NPR {fmt(unmatchedWith)}
            </div>
          )}
          {isBalanced && (
            <div className="msg ok" style={{marginBottom:12}}>
              ✓ Bank statement balances with ledger — {matchedCount}/{lines.length} entries matched.
            </div>
          )}

          {/* Add transaction buttons */}
          {activeStmt.status === "open" && (
            <div style={{display:"flex",gap:8,marginBottom:12}}>
              <button className="ghost-btn" onClick={()=>{setShowAddLine(s=>!s);setShowCsv(false);}}>
                {showAddLine?"Cancel":"+ Add Transaction"}
              </button>
              <button className="ghost-btn" onClick={()=>{setShowCsv(s=>!s);setShowAddLine(false);}}>
                {showCsv?"Cancel":"📋 Paste CSV"}
              </button>
            </div>
          )}

          {/* Manual add form */}
          {showAddLine && (
            <div className="biz-form" style={{marginBottom:12}}>
              <div className="inv-form-top">
                <label className="fld">Date <input type="date" value={lineForm.txnDate} onChange={e=>setLineForm(f=>({...f,txnDate:e.target.value}))} /></label>
                <label className="fld wide-field">Description <input placeholder="e.g. Rent payment, Bank charge" value={lineForm.description} onChange={e=>setLineForm(f=>({...f,description:e.target.value}))} /></label>
                <label className="fld">Reference <input placeholder="Cheque / Txn no" value={lineForm.reference} onChange={e=>setLineForm(f=>({...f,reference:e.target.value}))} /></label>
                <label className="fld">Deposits (money IN) <input type="number" step="0.01" placeholder="0" value={lineForm.deposits} onChange={e=>setLineForm(f=>({...f,deposits:e.target.value}))} /></label>
                <label className="fld">Withdrawals (money OUT) <input type="number" step="0.01" placeholder="0" value={lineForm.withdrawals} onChange={e=>setLineForm(f=>({...f,withdrawals:e.target.value}))} /></label>
                <label className="fld">Running Balance <input type="number" step="0.01" placeholder="Optional" value={lineForm.balance} onChange={e=>setLineForm(f=>({...f,balance:e.target.value}))} /></label>
              </div>
              <button className="btn" onClick={addLine} disabled={busy}>{busy?"Adding…":"Add Transaction"}</button>
            </div>
          )}

          {/* CSV import */}
          {showCsv && (
            <div className="biz-form" style={{marginBottom:12}}>
              <p className="muted" style={{fontSize:12,marginBottom:8}}>
                Paste CSV from your bank statement. Format per row:<br/>
                <b>Date, Description, Withdrawals, Deposits, Balance</b><br/>
                Example: <code>2024-08-01, Rent Payment, 9000, , 41000</code>
              </p>
              <textarea rows={8} style={{width:"100%",fontFamily:"monospace",fontSize:12,padding:8,borderRadius:6,border:"1px solid var(--line)"}}
                placeholder={"2024-08-01, Rent Payment, 9000, , 41000\n2024-08-05, Customer Receipt, , 11300, 52300"}
                value={csvText} onChange={e=>setCsvText(e.target.value)} />
              <button className="btn" style={{marginTop:8}} onClick={importCsv} disabled={busy||!csvText.trim()}>
                {busy?"Importing…":"Import Transactions"}
              </button>
            </div>
          )}

          {/* Two-column matching view */}
          <div style={{display:"grid",gridTemplateColumns:"1fr 1fr",gap:16,marginTop:8}}>

            {/* Left: Bank statement lines */}
            <div>
              <div className="dash-section-title">
                Bank Statement ({lines.length} transactions)
                {selectedLine && <span style={{color:"var(--gold)",marginLeft:8,fontWeight:700}}>← click a voucher to match</span>}
              </div>
              {lines.length === 0 ? (
                <p className="note" style={{fontSize:12}}>No transactions yet. Add them above.</p>
              ) : (
                <div style={{display:"flex",flexDirection:"column",gap:4}}>
                  {lines.map(l=>(
                    <div key={l.id}
                      className={"recon-card" + (l.is_matched?" recon-matched":"") + (selectedLine===l.id?" recon-selected":"")}
                      onClick={()=>!l.is_matched && setSelectedLine(selectedLine===l.id?null:l.id)}>
                      <div style={{display:"flex",justifyContent:"space-between",alignItems:"flex-start"}}>
                        <div>
                          <div style={{fontSize:12,fontWeight:600}}>{l.description}</div>
                          <div style={{fontSize:11,color:"var(--ink2)"}}>{l.txn_date}{l.reference?" · "+l.reference:""}</div>
                          {l.is_matched && l.vouchers && (
                            <div style={{fontSize:11,color:"var(--green2)",marginTop:2}}>
                              ✓ Matched: {l.vouchers.voucher_type} #{l.vouchers.voucher_number}
                            </div>
                          )}
                        </div>
                        <div style={{textAlign:"right",minWidth:80}}>
                          {Number(l.deposits)>0  && <div style={{color:"var(--green2)",fontWeight:700,fontSize:13}}>+{fmt(l.deposits)}</div>}
                          {Number(l.withdrawals)>0&&<div style={{color:"var(--rust)",fontWeight:700,fontSize:13}}>−{fmt(l.withdrawals)}</div>}
                          {l.balance!=null && <div style={{fontSize:10,color:"var(--ink2)"}}>{fmt(l.balance)}</div>}
                        </div>
                      </div>
                      {l.is_matched && (
                        <button className="link" style={{fontSize:11,color:"var(--rust)",padding:0,marginTop:4}}
                          onClick={e=>{e.stopPropagation();unmatchLine(l.id);}}>unmatch</button>
                      )}
                    </div>
                  ))}
                </div>
              )}
            </div>

            {/* Right: Ledger vouchers */}
            <div>
              <div className="dash-section-title">
                Ledger Vouchers ({unmatchedVouchers.length} unmatched)
              </div>
              {unmatchedVouchers.length === 0 ? (
                <p className="note" style={{fontSize:12}}>All vouchers matched ✓</p>
              ) : (
                <div style={{display:"flex",flexDirection:"column",gap:4}}>
                  {unmatchedVouchers.map(v=>(
                    <div key={v.id}
                      className={"recon-card recon-voucher" + (selectedLine?" recon-matchable":"")}
                      onClick={()=>selectedLine && matchLine(selectedLine, v.vouchers?.id)}>
                      <div style={{display:"flex",justifyContent:"space-between",alignItems:"flex-start"}}>
                        <div>
                          <div style={{fontSize:12,fontWeight:600}}>
                            <span className="tag">{v.vouchers?.voucher_type}</span> #{v.vouchers?.voucher_number}
                          </div>
                          <div style={{fontSize:11,color:"var(--ink2)"}}>{v.vouchers?.voucher_date}</div>
                          <div style={{fontSize:11,color:"var(--ink2)",marginTop:1}}>{v.vouchers?.narration||"—"}</div>
                        </div>
                        <div style={{textAlign:"right",minWidth:80}}>
                          {Number(v.debit)>0  && <div style={{color:"var(--green2)",fontWeight:700,fontSize:13}}>+{fmt(v.debit)}</div>}
                          {Number(v.credit)>0 && <div style={{color:"var(--rust)",fontWeight:700,fontSize:13}}>−{fmt(v.credit)}</div>}
                        </div>
                      </div>
                    </div>
                  ))}
                </div>
              )}
            </div>
          </div>
        </>
      )}
    </div>
  );
}
