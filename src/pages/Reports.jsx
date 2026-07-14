import React, { useEffect, useState, Component } from "react";
import { supabase } from "../supabase";
import { listTrialBalance } from "../lib/posting";

// ── Error boundary — catches render crashes so one broken report 
//   doesn't wipe the entire page. Shows the error message instead. ──
class ReportBoundary extends Component {
  constructor(props) { super(props); this.state = { err: null }; }
  static getDerivedStateFromError(e) { return { err: e }; }
  render() {
    if (this.state.err) return (
      <div className="msg err" style={{margin:"16px 0"}}>
        <b>Report error:</b> {this.state.err.message}
        <button className="link" style={{display:"inline",marginLeft:12}}
          onClick={()=>this.setState({err:null})}>Try again</button>
      </div>
    );
    return this.props.children;
  }
}

// ── DB helpers ────────────────────────────────────────────────
async function fetchAccounts() {
  const { data, error } = await supabase.from("accounts").select("*").eq("is_active", true);
  if (error) throw error;
  return data;
}

async function fetchVoucherLines() {
  const { data, error } = await supabase
    .from("voucher_lines")
    .select("*, vouchers(voucher_date, is_void, fiscal_year)");
  if (error) throw error;
  return data.filter(l => !l.vouchers?.is_void);
}

async function fetchInvoices() {
  const { data, error } = await supabase
    .from("invoices")
    .select("*")
    .neq("status", "cancelled");
  if (error) throw error;
  return data;
}

async function fetchBills() {
  const { data, error } = await supabase
    .from("purchase_bills")
    .select("*")
    .neq("status", "cancelled");
  if (error) throw error;
  return data;
}

// ── number formatting ─────────────────────────────────────────
const fmt = (n) => Math.abs(n).toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const fmtSign = (n) => (n < 0 ? "(" + fmt(n) + ")" : fmt(n));

// ── compute ledger balances from voucher lines ────────────────
function computeBalances(accounts, lines, fromDate, toDate) {
  const balances = {};
  accounts.forEach(a => {
    const ob = a.opening_balance_type === "debit" ? Number(a.opening_balance) : -Number(a.opening_balance);
    balances[a.id] = { account: a, balance: ob };
  });
  lines.forEach(l => {
    const date = l.vouchers?.voucher_date;
    if (fromDate && date < fromDate) return;
    if (toDate && date > toDate) return;
    if (balances[l.account_id]) {
      balances[l.account_id].balance += Number(l.debit) - Number(l.credit);
    }
  });
  return Object.values(balances);
}

// ── Reports page ──────────────────────────────────────────────
export default function Reports() {
  const [report, setReport] = useState("pl");
  const [fromDate, setFromDate] = useState(() => {
    // Default to 2 years ago so all existing data is visible without manual adjustment
    const d = new Date();
    d.setFullYear(d.getFullYear() - 2);
    return d.toISOString().slice(0,10);
  });
  const [toDate, setToDate] = useState(new Date().toISOString().slice(0,10));
  const [data, setData] = useState(null);
  const [loading, setLoading] = useState(false);
  const [err, setErr] = useState(null);

  const run = async () => {
    setLoading(true); setErr(null); setData(null);
    try {
      const { error: refreshError } = await supabase.rpc("refresh_document_payment_statuses");
      if (refreshError) throw refreshError;
      const [accounts, lines, invoices, bills] = await Promise.all([
        fetchAccounts(), fetchVoucherLines(), fetchInvoices(), fetchBills(),
      ]);
      // Period balances — for P&L and VAT (filtered to selected date range)
      const balances = computeBalances(accounts, lines, fromDate, toDate);
      // All-time balances — Balance Sheet always shows the full picture regardless of date filter
      const balancesAll = computeBalances(accounts, lines, null, null);

      if (report === "tb") setData({ rows: await listTrialBalance() });
      else if (report === "pl") setData(buildPL(balances, fromDate, toDate));
      else if (report === "bs") setData(buildBS(balancesAll));
      else if (report === "vat") setData(buildVAT(invoices, bills, fromDate, toDate));
      else if (report === "ageing") setData(buildAgeing(accounts, lines));
      else if (report === "sales") setData(buildSales(invoices, fromDate, toDate));
    } catch(e) { setErr(e.message); }
    setLoading(false);
  };

  useEffect(() => { run(); }, [report, fromDate, toDate]);

  return (
    <div className="panel">
      <div className="panel-head"><h2>Reports (रिपोर्ट)</h2></div>

      {/* Report selector */}
      <div className="filter-tabs" style={{marginBottom:16}}>
        {[
          {key:"tb", label:"Trial Balance"},
          {key:"pl", label:"Profit & Loss"},
          {key:"bs", label:"Balance Sheet"},
          {key:"vat", label:"VAT Summary"},
          {key:"ageing", label:"Ageing"},
          {key:"sales", label:"Sales Report"},
        ].map(r=>(
          <button key={r.key} className={"filter-tab"+(report===r.key?" active":"")} onClick={()=>setReport(r.key)}>{r.label}</button>
        ))}
      </div>

      {/* Date range (not needed for BS and Ageing) */}
      {report !== "bs" && report !== "ageing" && report !== "tb" && (
        <div style={{display:"flex",gap:12,marginBottom:16,alignItems:"center",flexWrap:"wrap"}}>
          <label className="fld" style={{margin:0,flex:"1 1 160px"}}>From <input type="date" value={fromDate} onChange={e=>setFromDate(e.target.value)} /></label>
          <label className="fld" style={{margin:0,flex:"1 1 160px"}}>To <input type="date" value={toDate} onChange={e=>setToDate(e.target.value)} /></label>
          <button className="btn" onClick={run} style={{marginTop:20}}>Run</button>
        </div>
      )}

      {err && <p className="msg err">{err}</p>}
      {loading && <p className="note">Computing…</p>}
      {data && <ReportBoundary key={report}><ReportView report={report} data={data} fromDate={fromDate} toDate={toDate} /></ReportBoundary>}
    </div>
  );
}

// ── Report views ──────────────────────────────────────────────
function ReportView({ report, data, fromDate, toDate }) {
  if (report === "tb") return <TBView data={data} />;
  if (report === "pl") return <PLView data={data} fromDate={fromDate} toDate={toDate} />;
  if (report === "bs") return <BSView data={data} />;
  if (report === "vat") return <VATView data={data} fromDate={fromDate} toDate={toDate} />;
  if (report === "ageing") return <AgeingView data={data} />;
  if (report === "sales") return <SalesView data={data} fromDate={fromDate} toDate={toDate} />;
  return null;
}

// ── Trial Balance (integrity check: total debit must equal total credit) ──
function TBView({ data }) {
  const rows = data.rows || [];
  const totalDebit = rows.reduce((s, r) => s + Number(r.debit), 0);
  const totalCredit = rows.reduce((s, r) => s + Number(r.credit), 0);
  const balanced = Math.abs(totalDebit - totalCredit) < 0.005;
  return (
    <div className="report-wrap">
      <div className="report-title">Trial Balance</div>
      <div className="report-period">As of today — every account's net balance</div>
      <button className="ghost-btn no-print" onClick={()=>window.print()} style={{marginBottom:16}}>🖨 Print</button>

      <div className={"net-result "+(balanced?"profit":"loss")} style={{marginBottom:16}}>
        <span>{balanced ? "✓ Books balance — debits equal credits" : "✗ Out of balance — investigate"}</span>
        <span>{balanced ? "" : "Δ NPR " + fmt(totalDebit - totalCredit)}</span>
      </div>

      <table className="tbl">
        <thead><tr><th>Account</th><th>Group</th><th className="num">Debit</th><th className="num">Credit</th></tr></thead>
        <tbody>
          {rows.map(r=>(
            <tr key={r.account_id}>
              <td>{r.name}</td>
              <td className="muted">{r.group_name}</td>
              <td className="num">{Number(r.debit) ? fmt(Number(r.debit)) : ""}</td>
              <td className="num">{Number(r.credit) ? fmt(Number(r.credit)) : ""}</td>
            </tr>
          ))}
        </tbody>
        <tfoot>
          <tr>
            <td colSpan={2}><b>Total</b></td>
            <td className="num"><b>{fmt(totalDebit)}</b></td>
            <td className="num"><b>{fmt(totalCredit)}</b></td>
          </tr>
        </tfoot>
      </table>
    </div>
  );
}

// ── P&L ──────────────────────────────────────────────────────
function buildPL(balances, from, to) {
  const income = balances.filter(b => b.account.account_type === "income");
  const expense = balances.filter(b => b.account.account_type === "expense");
  const totalIncome = income.reduce((s,b) => s + (-b.balance), 0); // income = credit balance
  const totalExpense = expense.reduce((s,b) => s + b.balance, 0);
  return { income, expense, totalIncome, totalExpense, netProfit: totalIncome - totalExpense };
}

function PLView({ data, fromDate, toDate }) {
  return (
    <div className="report-wrap">
      <div className="report-title">Profit & Loss Statement</div>
      <div className="report-period">{fromDate} to {toDate}</div>
      <button className="ghost-btn no-print" onClick={()=>window.print()} style={{marginBottom:16}}>🖨 Print</button>

      <div className="report-section">
        <div className="report-section-title">Income</div>
        <table className="tbl">
          <tbody>
            {data.income.map(b=>(
              <tr key={b.account.id}>
                <td>{b.account.name}</td>
                <td className="num">{fmt(-b.balance)}</td>
              </tr>
            ))}
          </tbody>
          <tfoot><tr><td><b>Total Income</b></td><td className="num"><b>{fmt(data.totalIncome)}</b></td></tr></tfoot>
        </table>
      </div>

      <div className="report-section">
        <div className="report-section-title">Expenses</div>
        <table className="tbl">
          <tbody>
            {data.expense.map(b=>(
              <tr key={b.account.id}>
                <td>{b.account.name}</td>
                <td className="num">{fmt(b.balance)}</td>
              </tr>
            ))}
          </tbody>
          <tfoot><tr><td><b>Total Expenses</b></td><td className="num"><b>{fmt(data.totalExpense)}</b></td></tr></tfoot>
        </table>
      </div>

      <div className={"net-result "+(data.netProfit>=0?"profit":"loss")}>
        <span>{data.netProfit>=0?"Net Profit":"Net Loss"}</span>
        <span>NPR {fmt(data.netProfit)}</span>
      </div>
    </div>
  );
}

// ── Balance Sheet ─────────────────────────────────────────────
function buildBS(balances) {
  const safe = balances.filter(b => b && b.account);
  const assets      = safe.filter(b => b.account.account_type === "asset");
  const liabilities = safe.filter(b => b.account.account_type === "liability");
  const equity      = safe.filter(b => b.account.account_type === "equity");
  const income      = safe.filter(b => b.account.account_type === "income");
  const expense     = safe.filter(b => b.account.account_type === "expense");

  // Net profit = total income − total expenses (folded into equity on BS)
  const totalIncome  = income.reduce((s,b) => s + (-b.balance), 0);
  const totalExpense = expense.reduce((s,b) => s + b.balance, 0);
  const netProfit    = totalIncome - totalExpense;

  // Group assets: current vs non-current
  const currentGroups = ["Cash-in-Hand","Bank Accounts","Sundry Debtors","Duties & Taxes","General"];
  const currentAssets    = assets.filter(b =>  currentGroups.includes(b.account.group_name));
  const nonCurrentAssets = assets.filter(b => !currentGroups.includes(b.account.group_name));

  // Group liabilities: current vs long-term
  const currentLiabGroups = ["Duties & Taxes","Sundry Creditors","General"];
  const currentLiab    = liabilities.filter(b =>  currentLiabGroups.includes(b.account.group_name));
  const longTermLiab   = liabilities.filter(b => !currentLiabGroups.includes(b.account.group_name));

  const totalAssets      = assets.reduce((s,b) => s + b.balance, 0);
  const totalLiabilities = liabilities.reduce((s,b) => s + (-b.balance), 0);
  const totalEquity      = equity.reduce((s,b) => s + (-b.balance), 0) + netProfit;

  return {
    assets, currentAssets, nonCurrentAssets,
    liabilities, currentLiab, longTermLiab,
    equity, netProfit,
    totalAssets, totalLiabilities, totalEquity,
  };
}

function BSView({ data }) {
  if (!data) return <p className="note">Loading…</p>;
  const {
    currentAssets=[], nonCurrentAssets=[], currentLiab=[], longTermLiab=[],
    equity=[], netProfit=0, totalAssets=0, totalLiabilities=0, totalEquity=0,
  } = data;

  const totalCurrentAssets    = currentAssets.reduce((s,b)=>s+b.balance,0);
  const totalNonCurrentAssets = nonCurrentAssets.reduce((s,b)=>s+b.balance,0);
  const totalCurrentLiab      = currentLiab.reduce((s,b)=>s+(-b.balance),0);
  const totalLongTermLiab     = longTermLiab.reduce((s,b)=>s+(-b.balance),0);
  const totalEquityAccounts   = equity.reduce((s,b)=>s+(-b.balance),0);
  const isBalanced = Math.abs(totalAssets - totalLiabilities - totalEquity) < 0.5;
  const today = new Date().toLocaleDateString("en-NP",{year:"numeric",month:"long",day:"numeric"});

  return (
    <div className="report-wrap">
      <div style={{display:"flex",justifyContent:"space-between",alignItems:"flex-start",flexWrap:"wrap",gap:8,marginBottom:4}}>
        <div>
          <div className="report-title">Balance Sheet</div>
          <div className="report-period">As of {today}</div>
        </div>
        <button className="ghost-btn no-print" onClick={()=>window.print()}>🖨 Print</button>
      </div>

      {/* ── Imbalance warning ── */}
      {!isBalanced && (
        <div className="msg err" style={{marginBottom:16}}>
          <b>⚠ Out of balance by NPR {fmt(Math.abs(totalAssets - totalLiabilities - totalEquity))}</b>
          <div style={{marginTop:6,fontSize:12}}>
            Most likely cause: an opening bank/cash balance was entered without a matching Capital Account entry.
            Fix: go to <b>Chart of Accounts → Capital Account → edit → set opening balance</b> equal to your starting capital (credit).
          </div>
        </div>
      )}
      {isBalanced && (
        <div className="msg ok" style={{marginBottom:16}}>✓ Balance Sheet balances — Assets equal Liabilities + Equity</div>
      )}

      <div className="bs-vert">

        {/* ══ EQUITY & LIABILITIES ══════════════════════════════════ */}
        <div className="bs-block">
          <div className="bs-block-hd">EQUITY &amp; LIABILITIES</div>

          {/* Shareholders' Equity */}
          <div className="bs-sub-hd">Shareholders' Equity</div>
          {equity.map(b=>(
            <div key={b.account.id} className="bs-row">
              <span>{b.account.name}</span>
              <span className="bs-amt">{fmt(-b.balance)}</span>
            </div>
          ))}
          <div className="bs-row bs-net-row">
            <span>Net Profit / (Loss) for the period</span>
            <span className="bs-amt" style={{color: netProfit>=0?"var(--green2)":"var(--rust)"}}>
              {netProfit>=0?"":"-"}{fmt(netProfit)}
            </span>
          </div>
          <div className="bs-subtotal">
            <span>Total Equity</span>
            <span className="bs-amt"><b>{fmt(totalEquity)}</b></span>
          </div>

          {/* Long-term Liabilities */}
          {longTermLiab.length > 0 && <>
            <div className="bs-sub-hd" style={{marginTop:16}}>Non-Current Liabilities</div>
            {longTermLiab.map(b=>(
              <div key={b.account.id} className="bs-row">
                <span>{b.account.name}<span className="bs-grp">{b.account.group_name}</span></span>
                <span className="bs-amt">{fmt(-b.balance)}</span>
              </div>
            ))}
            <div className="bs-subtotal">
              <span>Total Non-Current Liabilities</span>
              <span className="bs-amt"><b>{fmt(totalLongTermLiab)}</b></span>
            </div>
          </>}

          {/* Current Liabilities */}
          <div className="bs-sub-hd" style={{marginTop:16}}>Current Liabilities</div>
          {currentLiab.length === 0
            ? <div className="bs-row muted"><span>—</span><span className="bs-amt">0.00</span></div>
            : currentLiab.map(b=>(
              <div key={b.account.id} className="bs-row">
                <span>{b.account.name}<span className="bs-grp">{b.account.group_name}</span></span>
                <span className="bs-amt">{fmt(-b.balance)}</span>
              </div>
            ))
          }
          <div className="bs-subtotal">
            <span>Total Current Liabilities</span>
            <span className="bs-amt"><b>{fmt(totalCurrentLiab)}</b></span>
          </div>

          <div className="bs-grand">
            <span>TOTAL EQUITY &amp; LIABILITIES</span>
            <span className="bs-amt">NPR {fmt(totalLiabilities + totalEquity)}</span>
          </div>
        </div>

        {/* ══ ASSETS ═══════════════════════════════════════════════ */}
        <div className="bs-block">
          <div className="bs-block-hd">ASSETS</div>

          {/* Non-current assets */}
          {nonCurrentAssets.length > 0 && <>
            <div className="bs-sub-hd">Non-Current Assets</div>
            {nonCurrentAssets.map(b=>(
              <div key={b.account.id} className="bs-row">
                <span>{b.account.name}<span className="bs-grp">{b.account.group_name}</span></span>
                <span className="bs-amt">{fmt(b.balance)}</span>
              </div>
            ))}
            <div className="bs-subtotal">
              <span>Total Non-Current Assets</span>
              <span className="bs-amt"><b>{fmt(totalNonCurrentAssets)}</b></span>
            </div>
          </>}

          {/* Current assets */}
          <div className="bs-sub-hd" style={{marginTop: nonCurrentAssets.length>0?16:0}}>Current Assets</div>
          {currentAssets.length === 0
            ? <div className="bs-row muted"><span>—</span><span className="bs-amt">0.00</span></div>
            : currentAssets.map(b=>(
              <div key={b.account.id} className="bs-row">
                <span>{b.account.name}<span className="bs-grp">{b.account.group_name}</span></span>
                <span className="bs-amt">{fmt(b.balance)}</span>
              </div>
            ))
          }
          <div className="bs-subtotal">
            <span>Total Current Assets</span>
            <span className="bs-amt"><b>{fmt(totalCurrentAssets)}</b></span>
          </div>

          <div className="bs-grand">
            <span>TOTAL ASSETS</span>
            <span className="bs-amt">NPR {fmt(totalAssets)}</span>
          </div>
        </div>

      </div>
    </div>
  );
}

// ── VAT Summary ───────────────────────────────────────────────
function buildVAT(invoices, bills, from, to) {
  const filteredInv = invoices.filter(i => i.invoice_date >= from && i.invoice_date <= to);
  const filteredBills = bills.filter(b => b.bill_date >= from && b.bill_date <= to);
  const outputVat = filteredInv.reduce((s,i) => s + Number(i.vat_amount), 0);
  const inputVat = filteredBills.reduce((s,b) => s + Number(b.vat_amount), 0);
  const vatPayable = outputVat - inputVat;
  return { invoices: filteredInv, bills: filteredBills, outputVat, inputVat, vatPayable };
}

function VATView({ data, fromDate, toDate }) {
  return (
    <div className="report-wrap">
      <div className="report-title">VAT Summary Report</div>
      <div className="report-period">{fromDate} to {toDate}</div>
      <button className="ghost-btn no-print" onClick={()=>window.print()} style={{marginBottom:16}}>🖨 Print</button>

      <div className="vat-grid">
        <div className="vat-card">
          <div className="vat-card-title">Output VAT (Sales)</div>
          <div className="vat-card-amount">NPR {fmt(data.outputVat)}</div>
          <div className="muted" style={{fontSize:12}}>From {data.invoices.length} invoices</div>
          <table className="tbl" style={{marginTop:12}}>
            <thead><tr><th>Invoice #</th><th>Customer</th><th className="num">Taxable</th><th className="num">VAT 13%</th></tr></thead>
            <tbody>
              {data.invoices.map(i=>(
                <tr key={i.id}>
                  <td>{i.fiscal_year}-{String(i.invoice_number).padStart(4,"0")}</td>
                  <td>{i.party_name}</td>
                  <td className="num">{fmt(Number(i.subtotal))}</td>
                  <td className="num">{fmt(Number(i.vat_amount))}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>

        <div className="vat-card">
          <div className="vat-card-title">Input VAT (Purchases)</div>
          <div className="vat-card-amount">NPR {fmt(data.inputVat)}</div>
          <div className="muted" style={{fontSize:12}}>From {data.bills.length} bills</div>
          <table className="tbl" style={{marginTop:12}}>
            <thead><tr><th>Bill #</th><th>Vendor</th><th className="num">Taxable</th><th className="num">VAT 13%</th></tr></thead>
            <tbody>
              {data.bills.map(b=>(
                <tr key={b.id}>
                  <td>{b.fiscal_year}-PB-{String(b.bill_number).padStart(4,"0")}</td>
                  <td>{b.vendor_name}</td>
                  <td className="num">{fmt(Number(b.subtotal))}</td>
                  <td className="num">{fmt(Number(b.vat_amount))}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>

      <div className={"net-result "+(data.vatPayable>=0?"loss":"profit")} style={{marginTop:20}}>
        <span>{data.vatPayable>=0?"VAT Payable to IRD":"VAT Refundable from IRD"}</span>
        <span>NPR {fmt(data.vatPayable)}</span>
      </div>
      <p className="note">Output VAT ({fmt(data.outputVat)}) − Input VAT ({fmt(data.inputVat)}) = {data.vatPayable>=0?"payable":"refundable"} NPR {fmt(data.vatPayable)}</p>
    </div>
  );
}

// ── Ageing ────────────────────────────────────────────────────
function buildAgeing(accounts, lines) {
  const today = new Date().toISOString().slice(0,10);
  const parties = accounts.filter(a => a.is_party_account);
  const result = parties.map(a => {
    const ob = a.opening_balance_type === "debit" ? Number(a.opening_balance) : -Number(a.opening_balance);
    const balance = lines
      .filter(l => l.account_id === a.id)
      .reduce((s,l) => s + Number(l.debit) - Number(l.credit), ob);
    return { account: a, balance };
  }).filter(r => Math.abs(r.balance) > 0.01);

  const receivables = result.filter(r => r.balance > 0);
  const payables = result.filter(r => r.balance < 0);
  return { receivables, payables, today };
}

function AgeingView({ data }) {
  const totalRec = data.receivables.reduce((s,r) => s+r.balance, 0);
  const totalPay = data.payables.reduce((s,r) => s+Math.abs(r.balance), 0);
  return (
    <div className="report-wrap">
      <div className="report-title">Receivables & Payables</div>
      <div className="report-period">As of today</div>
      <button className="ghost-btn no-print" onClick={()=>window.print()} style={{marginBottom:16}}>🖨 Print</button>

      <div className="bs-grid">
        <div>
          <div className="report-section">
            <div className="report-section-title" style={{color:"var(--green2)"}}>Receivables (तपाईंले पाउने)</div>
            <table className="tbl">
              <thead><tr><th>Customer</th><th className="num">Balance</th></tr></thead>
              <tbody>{data.receivables.map(r=><tr key={r.account.id}><td>{r.account.name}</td><td className="num">{fmt(r.balance)}</td></tr>)}</tbody>
              <tfoot><tr><td><b>Total Receivable</b></td><td className="num"><b>NPR {fmt(totalRec)}</b></td></tr></tfoot>
            </table>
          </div>
        </div>
        <div>
          <div className="report-section">
            <div className="report-section-title" style={{color:"var(--rust)"}}>Payables (तपाईंले दिनुपर्ने)</div>
            <table className="tbl">
              <thead><tr><th>Vendor</th><th className="num">Balance</th></tr></thead>
              <tbody>{data.payables.map(r=><tr key={r.account.id}><td>{r.account.name}</td><td className="num">{fmt(Math.abs(r.balance))}</td></tr>)}</tbody>
              <tfoot><tr><td><b>Total Payable</b></td><td className="num"><b>NPR {fmt(totalPay)}</b></td></tr></tfoot>
            </table>
          </div>
        </div>
      </div>
    </div>
  );
}

// ── Sales Report ──────────────────────────────────────────────
function buildSales(invoices, from, to) {
  const filtered = invoices.filter(i => i.invoice_date >= from && i.invoice_date <= to);
  const total = filtered.reduce((s,i) => s+Number(i.total), 0);
  const totalVat = filtered.reduce((s,i) => s+Number(i.vat_amount), 0);
  const totalSubtotal = filtered.reduce((s,i) => s+Number(i.subtotal), 0);
  const paid = filtered.reduce((s,i)=>s+Number(i.amount_paid || 0),0);
  const unpaid = filtered.reduce((s,i)=>s+Number(i.outstanding_amount ?? i.total),0);
  return { invoices: filtered, total, totalVat, totalSubtotal, paid, unpaid };
}

function SalesView({ data, fromDate, toDate }) {
  return (
    <div className="report-wrap">
      <div className="report-title">Sales Report</div>
      <div className="report-period">{fromDate} to {toDate}</div>
      <button className="ghost-btn no-print" onClick={()=>window.print()} style={{marginBottom:16}}>🖨 Print</button>

      <div className="stat-row" style={{marginBottom:16}}>
        <div className="stat"><span>NPR {fmt(data.totalSubtotal)}</span>Net Sales</div>
        <div className="stat"><span>NPR {fmt(data.totalVat)}</span>Output VAT</div>
        <div className="stat"><span>NPR {fmt(data.total)}</span>Gross Total</div>
        <div className="stat"><span style={{color:"var(--green2)"}}>NPR {fmt(data.paid)}</span>Collected</div>
        <div className="stat"><span style={{color:"var(--rust)"}}>NPR {fmt(data.unpaid)}</span>Outstanding</div>
      </div>

      <table className="tbl">
        <thead><tr><th>Invoice #</th><th>Date</th><th>Customer</th><th>Status</th><th className="num">Collected</th><th className="num">Outstanding</th><th className="num">Total</th></tr></thead>
        <tbody>
          {data.invoices.map(i=>(
            <tr key={i.id}>
              <td>{i.fiscal_year}-{String(i.invoice_number).padStart(4,"0")}</td>
              <td>{i.invoice_date}</td>
              <td>{i.party_name}</td>
              <td><span className={"status-"+i.status}>{i.status}</span></td>
              <td className="num">{fmt(Number(i.amount_paid || 0))}</td>
              <td className="num">{fmt(Number(i.outstanding_amount ?? i.total))}</td>
              <td className="num"><b>{fmt(Number(i.total))}</b></td>
            </tr>
          ))}
        </tbody>
        <tfoot>
          <tr>
            <td colSpan={4}><b>Total</b></td>
            <td className="num"><b>{fmt(data.paid)}</b></td>
            <td className="num"><b>{fmt(data.unpaid)}</b></td>
            <td className="num"><b>NPR {fmt(data.total)}</b></td>
          </tr>
        </tfoot>
      </table>
    </div>
  );
}
