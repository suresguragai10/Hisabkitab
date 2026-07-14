import React, { Component, useEffect, useState } from "react";
import {
  downloadCsv,
  getBalanceSheetReport,
  getCashFlowReport,
  getDayBookReport,
  getGeneralLedgerReport,
  getPayablesAgeingReport,
  getProfitLossReport,
  getPurchaseRegisterReport,
  getReceivablesAgeingReport,
  getReportFiscalYears,
  getSalesRegisterReport,
  getStockValuationReport,
  getTrialBalanceReport,
  getVatReport,
} from "../lib/reports";

class ReportBoundary extends Component {
  constructor(props) { super(props); this.state = { error: null }; }
  static getDerivedStateFromError(error) { return { error }; }
  render() {
    if (!this.state.error) return this.props.children;
    return <p className="msg err">Report error: {this.state.error.message}</p>;
  }
}

const REPORTS = [
  ["daybook", "Day Book", "period"],
  ["tb", "Trial Balance", "asof"],
  ["pl", "Profit & Loss", "period"],
  ["bs", "Balance Sheet", "asof"],
  ["cashflow", "Cash Flow", "period"],
  ["receivables", "Receivables Ageing", "asof"],
  ["payables", "Payables Ageing", "asof"],
  ["sales", "Sales Register", "period"],
  ["purchases", "Purchase Register", "period"],
  ["vat", "VAT Report", "period"],
  ["stock", "Stock Valuation", "asof"],
];

const money = (value) => Number(value || 0).toLocaleString(undefined, {
  minimumFractionDigits: 2,
  maximumFractionDigits: 2,
});
const signedMoney = (value) => Number(value || 0) < 0 ? `(${money(Math.abs(Number(value)))})` : money(value);
const titleCase = (value) => String(value || "").replaceAll("_", " ").replace(/\b\w/g, (c) => c.toUpperCase());
const today = () => new Date().toISOString().slice(0, 10);
const defaultFrom = () => {
  const date = new Date();
  date.setMonth(date.getMonth() - 6);
  return date.toISOString().slice(0, 10);
};

export default function Reports() {
  const [report, setReport] = useState("pl");
  const [fromDate, setFromDate] = useState(defaultFrom);
  const [toDate, setToDate] = useState(today);
  const [asOfDate, setAsOfDate] = useState(today);
  const [fiscalYear, setFiscalYear] = useState("");
  const [fiscalYears, setFiscalYears] = useState([]);
  const [data, setData] = useState(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState(null);
  const [drillAccount, setDrillAccount] = useState(null);

  const mode = REPORTS.find(([key]) => key === report)?.[2] || "period";

  useEffect(() => {
    getReportFiscalYears().then((rows) => setFiscalYears(Array.isArray(rows) ? rows : [])).catch(() => {});
  }, []);

  const run = async () => {
    setLoading(true);
    setError(null);
    try {
      const period = { fromDate, toDate, fiscalYear: fiscalYear || null };
      const asOf = { asOfDate };
      const result = report === "daybook" ? await getDayBookReport(period)
        : report === "tb" ? await getTrialBalanceReport(asOf)
        : report === "pl" ? await getProfitLossReport(period)
        : report === "bs" ? await getBalanceSheetReport(asOf)
        : report === "cashflow" ? await getCashFlowReport(period)
        : report === "receivables" ? await getReceivablesAgeingReport(asOf)
        : report === "payables" ? await getPayablesAgeingReport(asOf)
        : report === "sales" ? await getSalesRegisterReport(period)
        : report === "purchases" ? await getPurchaseRegisterReport(period)
        : report === "vat" ? await getVatReport(period)
        : await getStockValuationReport(asOf);
      setData(result);
    } catch (err) {
      setError(err.message || String(err));
      setData(null);
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => { run(); }, [report]);

  const exportReport = () => {
    const spec = csvSpec(report, data);
    if (!spec) return;
    const suffix = mode === "period" ? `${fromDate}-to-${toDate}` : `as-of-${asOfDate}`;
    downloadCsv(`HisabKitab-${report}-${suffix}.csv`, spec.columns, spec.rows);
  };

  return (
    <div className="panel">
      <div className="panel-head"><h2>Reports (रिपोर्ट)</h2></div>

      <div className="filter-tabs" style={{ marginBottom: 16, flexWrap: "wrap" }}>
        {REPORTS.map(([key, label]) => (
          <button key={key} className={`filter-tab${report === key ? " active" : ""}`} onClick={() => setReport(key)}>{label}</button>
        ))}
      </div>

      <div style={{ display: "flex", gap: 12, marginBottom: 16, alignItems: "end", flexWrap: "wrap" }}>
        {mode === "period" ? <>
          <label className="fld" style={{ margin: 0, minWidth: 160 }}>From
            <input type="date" value={fromDate} onChange={(event) => setFromDate(event.target.value)} />
          </label>
          <label className="fld" style={{ margin: 0, minWidth: 160 }}>To
            <input type="date" value={toDate} onChange={(event) => setToDate(event.target.value)} />
          </label>
          <label className="fld" style={{ margin: 0, minWidth: 150 }}>Fiscal year
            <select value={fiscalYear} onChange={(event) => setFiscalYear(event.target.value)}>
              <option value="">All fiscal years</option>
              {fiscalYears.map((year) => <option key={year} value={year}>{year}</option>)}
            </select>
          </label>
        </> : (
          <label className="fld" style={{ margin: 0, minWidth: 180 }}>As of
            <input type="date" value={asOfDate} onChange={(event) => setAsOfDate(event.target.value)} />
          </label>
        )}
        <button className="btn" onClick={run} disabled={loading}>{loading ? "Running…" : "Run report"}</button>
        <button className="ghost-btn" onClick={exportReport} disabled={!data}>Export CSV</button>
        <button className="ghost-btn" onClick={() => window.print()} disabled={!data}>Print</button>
      </div>

      <p className="note" style={{ marginTop: 0 }}>
        Posted, non-void ledger entries are the accounting source of truth. Click an account row to open its ledger detail.
      </p>
      {error && <p className="msg err">{error}</p>}
      {loading && <p className="note">Computing report…</p>}
      {data && !loading && (
        <ReportBoundary key={`${report}-${fromDate}-${toDate}-${asOfDate}-${fiscalYear}`}>
          <ReportView report={report} data={data} onDrill={setDrillAccount} />
        </ReportBoundary>
      )}

      {drillAccount && (
        <LedgerDrilldown
          account={drillAccount}
          fromDate={mode === "period" ? fromDate : defaultFrom()}
          toDate={mode === "period" ? toDate : asOfDate}
          fiscalYear={mode === "period" ? fiscalYear : ""}
          onClose={() => setDrillAccount(null)}
        />
      )}
    </div>
  );
}

function ReportView({ report, data, onDrill }) {
  if (report === "daybook") return <DayBook data={data} />;
  if (report === "tb") return <TrialBalance data={data} onDrill={onDrill} />;
  if (report === "pl") return <ProfitLoss data={data} onDrill={onDrill} />;
  if (report === "bs") return <BalanceSheet data={data} onDrill={onDrill} />;
  if (report === "cashflow") return <CashFlow data={data} />;
  if (report === "receivables" || report === "payables") return <Ageing data={data} kind={report} />;
  if (report === "sales" || report === "purchases") return <Register data={data} kind={report} />;
  if (report === "vat") return <VatReport data={data} />;
  return <StockValuation data={data} />;
}

function StatusBanner({ good, goodText, badText, difference }) {
  return (
    <div className={`net-result ${good ? "profit" : "loss"}`} style={{ marginBottom: 16 }}>
      <span>{good ? goodText : badText}</span>
      {!good && difference !== undefined && <span>Difference: NPR {money(difference)}</span>}
    </div>
  );
}

function AccountButton({ row, onDrill }) {
  return <button className="link" style={{ display: "inline", textAlign: "left" }} onClick={() => onDrill({ id: row.account_id, account_code: row.account_code, name: row.name })}>
    {row.account_code ? `${row.account_code} · ` : ""}{row.name}
  </button>;
}

function DayBook({ data }) {
  return <div className="report-wrap">
    <div className="report-title">Day Book</div>
    <div className="report-period">{data.from} to {data.to}</div>
    <StatusBanner good={Math.abs(Number(data.difference)) <= 0.005} goodText="Debits and credits reconcile" badText="Day Book is out of balance" difference={data.difference} />
    {(data.rows || []).map((voucher) => <details key={voucher.voucher_id} style={{ borderBottom: "1px solid var(--line)", padding: "10px 0" }}>
      <summary style={{ cursor: "pointer", display: "flex", justifyContent: "space-between", gap: 12 }}>
        <span><b>{voucher.date}</b> · {titleCase(voucher.voucher_type)} #{voucher.voucher_number} · {voucher.narration || "—"}</span>
        <span>NPR {money(voucher.debit)}</span>
      </summary>
      <table className="tbl" style={{ marginTop: 10 }}>
        <thead><tr><th>Account</th><th>Description</th><th className="num">Debit</th><th className="num">Credit</th></tr></thead>
        <tbody>{(voucher.lines || []).map((line) => <tr key={line.line_id}>
          <td>{line.account_code} · {line.account_name}</td><td>{line.description || "—"}</td>
          <td className="num">{Number(line.debit) ? money(line.debit) : ""}</td><td className="num">{Number(line.credit) ? money(line.credit) : ""}</td>
        </tr>)}</tbody>
      </table>
    </details>)}
    <p className="note">Total debit: <b>NPR {money(data.total_debit)}</b> · Total credit: <b>NPR {money(data.total_credit)}</b></p>
  </div>;
}

function TrialBalance({ data, onDrill }) {
  return <div className="report-wrap">
    <div className="report-title">Trial Balance</div><div className="report-period">As of {data.as_of}</div>
    <StatusBanner good={data.balanced} goodText="Books balance — debits equal credits" badText="Trial Balance is out of balance" difference={data.difference} />
    <table className="tbl"><thead><tr><th>Account</th><th>Report class</th><th className="num">Debit</th><th className="num">Credit</th></tr></thead>
      <tbody>{(data.rows || []).map((row) => <tr key={row.account_id}>
        <td><AccountButton row={row} onDrill={onDrill} /></td><td>{titleCase(row.report_class)}</td>
        <td className="num">{Number(row.debit) ? money(row.debit) : ""}</td><td className="num">{Number(row.credit) ? money(row.credit) : ""}</td>
      </tr>)}</tbody>
      <tfoot><tr><td colSpan={2}><b>Total</b></td><td className="num"><b>{money(data.total_debit)}</b></td><td className="num"><b>{money(data.total_credit)}</b></td></tr></tfoot>
    </table>
  </div>;
}

function ReportSection({ title, rows, onDrill, total }) {
  return <div className="report-section">
    <div className="report-section-title">{title}</div>
    <table className="tbl"><tbody>{rows.map((row) => <tr key={row.account_id}>
      <td><AccountButton row={row} onDrill={onDrill} /></td><td className="num">{signedMoney(row.amount)}</td>
    </tr>)}</tbody><tfoot><tr><td><b>Total {title}</b></td><td className="num"><b>{signedMoney(total)}</b></td></tr></tfoot></table>
  </div>;
}

function ProfitLoss({ data, onDrill }) {
  const rows = data.rows || [];
  return <div className="report-wrap"><div className="report-title">Profit & Loss Statement</div><div className="report-period">{data.from} to {data.to}</div>
    <ReportSection title="Revenue" rows={rows.filter((r) => r.report_class === "revenue")} total={data.revenue} onDrill={onDrill} />
    <ReportSection title="Cost of Sales" rows={rows.filter((r) => r.report_class === "cost_of_sales")} total={data.cost_of_sales} onDrill={onDrill} />
    <div className="net-result profit"><span>Gross Profit</span><span>NPR {signedMoney(data.gross_profit)}</span></div>
    <ReportSection title="Operating Expense" rows={rows.filter((r) => r.report_class === "operating_expense")} total={data.operating_expense} onDrill={onDrill} />
    <ReportSection title="Other Income" rows={rows.filter((r) => r.report_class === "other_income")} total={data.other_income} onDrill={onDrill} />
    <ReportSection title="Other Expense" rows={rows.filter((r) => r.report_class === "other_expense")} total={data.other_expense} onDrill={onDrill} />
    <div className={`net-result ${Number(data.net_profit) >= 0 ? "profit" : "loss"}`}><span>Net {Number(data.net_profit) >= 0 ? "Profit" : "Loss"}</span><span>NPR {signedMoney(data.net_profit)}</span></div>
  </div>;
}

function BalanceSheet({ data, onDrill }) {
  const rows = data.rows || [];
  const groups = [
    ["Current Assets", "current_asset"], ["Non-current Assets", "non_current_asset"],
    ["Current Liabilities", "current_liability"], ["Non-current Liabilities", "non_current_liability"], ["Equity", "equity"],
  ];
  return <div className="report-wrap"><div className="report-title">Balance Sheet</div><div className="report-period">As of {data.as_of}</div>
    <StatusBanner good={data.balanced} goodText="Balance Sheet reconciles to the ledger" badText="Assets do not equal liabilities and equity" difference={data.difference} />
    {groups.map(([label, key]) => <ReportSection key={key} title={label} rows={rows.filter((r) => r.report_class === key)} total={rows.filter((r) => r.report_class === key).reduce((sum, row) => sum + Number(row.amount), 0)} onDrill={onDrill} />)}
    <table className="tbl"><tbody>
      <tr><td>Current earnings</td><td className="num">{signedMoney(data.current_earnings)}</td></tr>
      <tr><td><b>Total Assets</b></td><td className="num"><b>{money(data.total_assets)}</b></td></tr>
      <tr><td><b>Total Liabilities & Equity</b></td><td className="num"><b>{money(data.liabilities_and_equity)}</b></td></tr>
    </tbody></table>
  </div>;
}

function CashFlow({ data }) {
  const rows = data.rows || [];
  return <div className="report-wrap"><div className="report-title">Cash Flow Statement</div><div className="report-period">{data.from} to {data.to}</div>
    <StatusBanner good={data.reconciled} goodText="Cash Flow reconciles to cash and bank ledgers" badText="Cash Flow does not reconcile" difference={data.difference} />
    <table className="tbl"><tbody>
      <tr><td>Opening cash and bank</td><td className="num">{signedMoney(data.opening_cash)}</td></tr>
      <tr><td>Net cash from operating activities</td><td className="num">{signedMoney(data.operating)}</td></tr>
      <tr><td>Net cash from investing activities</td><td className="num">{signedMoney(data.investing)}</td></tr>
      <tr><td>Net cash from financing activities</td><td className="num">{signedMoney(data.financing)}</td></tr>
      <tr><td><b>Closing cash and bank</b></td><td className="num"><b>{signedMoney(data.closing_cash)}</b></td></tr>
    </tbody></table>
    <div className="report-section-title" style={{ marginTop: 20 }}>Cash movements</div>
    <table className="tbl"><thead><tr><th>Date</th><th>Voucher</th><th>Narration</th><th>Category</th><th className="num">Amount</th></tr></thead>
      <tbody>{rows.map((row, index) => <tr key={`${row.voucher_id}-${row.cash_flow_category}-${index}`}><td>{row.date}</td><td>{titleCase(row.voucher_type)} #{row.voucher_number}</td><td>{row.narration || "—"}</td><td>{titleCase(row.cash_flow_category)}</td><td className="num">{signedMoney(row.amount)}</td></tr>)}</tbody>
    </table>
  </div>;
}

function Ageing({ data, kind }) {
  const isReceivable = kind === "receivables";
  return <div className="report-wrap"><div className="report-title">{isReceivable ? "Receivables" : "Payables"} Ageing</div><div className="report-period">As of {data.as_of}</div>
    <StatusBanner good={data.reconciled} goodText="Ageing reconciles to the party ledgers" badText="Ageing differs from the party ledgers" difference={data.difference} />
    <div className="stat-row" style={{ marginBottom: 16 }}>
      {[['Current',data.current],['1–30 days',data.days_1_30],['31–60 days',data.days_31_60],['61–90 days',data.days_61_90],['Over 90 days',data.over_90]].map(([label, value]) => <div className="stat" key={label}><small>{label}</small><span>{money(value)}</span></div>)}
    </div>
    <table className="tbl"><thead><tr><th>Document</th><th>{isReceivable ? "Customer" : "Supplier"}</th><th>Date</th><th>Due</th><th className="num">Net</th><th className="num">Paid</th><th className="num">Outstanding</th><th>Bucket</th></tr></thead>
      <tbody>{(data.rows || []).map((row) => <tr key={row.document_id}><td>#{isReceivable ? row.invoice_number : row.bill_number}</td><td>{isReceivable ? row.party_name : row.vendor_name}</td><td>{isReceivable ? row.invoice_date : row.bill_date}</td><td>{row.due_date || "—"}</td><td className="num">{money(row.net_amount)}</td><td className="num">{money(row.paid_amount)}</td><td className="num"><b>{money(row.outstanding)}</b></td><td>{titleCase(row.bucket)}</td></tr>)}</tbody>
      <tfoot><tr><td colSpan={6}><b>Total</b></td><td className="num"><b>{money(data.total)}</b></td><td /></tr></tfoot>
    </table>
    <p className="note">Ledger balance: <b>NPR {money(data.ledger_balance)}</b></p>
  </div>;
}

function Register({ data, kind }) {
  return <div className="report-wrap"><div className="report-title">{kind === "sales" ? "Sales" : "Purchase"} Register</div><div className="report-period">{data.from} to {data.to}</div>
    <table className="tbl"><thead><tr><th>Date</th><th>Type / #</th><th>Party</th><th>PAN/VAT</th><th className="num">Taxable</th><th className="num">VAT</th><th className="num">Total</th></tr></thead>
      <tbody>{(data.rows || []).map((row) => <tr key={`${row.document_type}-${row.document_id}`}><td>{row.document_date}</td><td>{titleCase(row.document_type)} #{row.document_number}</td><td>{row.party_name}</td><td>{row.pan_vat || "—"}</td><td className="num">{signedMoney(row.subtotal)}</td><td className="num">{signedMoney(row.vat_amount)}</td><td className="num"><b>{signedMoney(row.total)}</b></td></tr>)}</tbody>
      <tfoot><tr><td colSpan={4}><b>Net total</b></td><td className="num"><b>{signedMoney(data.subtotal)}</b></td><td className="num"><b>{signedMoney(data.vat)}</b></td><td className="num"><b>{signedMoney(data.total)}</b></td></tr></tfoot>
    </table>
  </div>;
}

function VatReport({ data }) {
  return <div className="report-wrap"><div className="report-title">VAT Report</div><div className="report-period">{data.from} to {data.to}</div>
    <StatusBanner good={data.reconciled} goodText="VAT documents reconcile to VAT ledgers" badText="VAT documents and ledger differ" difference={Math.max(Math.abs(Number(data.output_variance)), Math.abs(Number(data.input_variance)))} />
    <table className="tbl"><tbody>
      <tr><td>Output VAT</td><td className="num">{money(data.output_vat)}</td><td className="muted">Ledger {money(data.output_vat_ledger)}</td></tr>
      <tr><td>Input VAT</td><td className="num">{money(data.input_vat)}</td><td className="muted">Ledger {money(data.input_vat_ledger)}</td></tr>
      <tr><td><b>Net VAT payable</b></td><td className="num"><b>{signedMoney(data.net_vat_payable)}</b></td><td /></tr>
    </tbody></table>
    <table className="tbl" style={{ marginTop: 18 }}><thead><tr><th>Date</th><th>Source</th><th>Party</th><th className="num">Output VAT</th><th className="num">Input VAT</th></tr></thead>
      <tbody>{(data.rows || []).map((row) => <tr key={`${row.source_type}-${row.source_id}`}><td>{row.document_date}</td><td>{titleCase(row.source_type)} #{row.document_number}</td><td>{row.party_name}</td><td className="num">{Number(row.output_vat) ? signedMoney(row.output_vat) : ""}</td><td className="num">{Number(row.input_vat) ? signedMoney(row.input_vat) : ""}</td></tr>)}</tbody>
    </table>
  </div>;
}

function StockValuation({ data }) {
  return <div className="report-wrap"><div className="report-title">Stock Valuation</div><div className="report-period">As of {data.as_of} · Moving weighted average</div>
    <StatusBanner good={data.reconciled} goodText="Stock valuation reconciles to Inventory Asset" badText="Stock valuation differs from Inventory Asset" difference={data.difference} />
    <table className="tbl"><thead><tr><th>SKU</th><th>Item</th><th>Category</th><th className="num">Quantity</th><th>Unit</th><th className="num">Average cost</th><th className="num">Value</th></tr></thead>
      <tbody>{(data.rows || []).map((row) => <tr key={row.item_id}><td>{row.sku || "—"}</td><td>{row.name}</td><td>{row.category_name || "—"}</td><td className="num">{Number(row.quantity).toLocaleString()}</td><td>{row.unit}</td><td className="num">{money(row.average_cost)}</td><td className="num"><b>{money(row.inventory_value)}</b></td></tr>)}</tbody>
      <tfoot><tr><td colSpan={6}><b>Total stock valuation</b></td><td className="num"><b>{money(data.stock_valuation)}</b></td></tr></tfoot>
    </table>
    <p className="note">Inventory Asset ledger: <b>NPR {money(data.inventory_ledger_balance)}</b></p>
  </div>;
}

function LedgerDrilldown({ account, fromDate, toDate, fiscalYear, onClose }) {
  const [data, setData] = useState(null);
  const [error, setError] = useState(null);
  useEffect(() => {
    getGeneralLedgerReport({ accountId: account.id, fromDate, toDate, fiscalYear: fiscalYear || null })
      .then(setData).catch((err) => setError(err.message));
  }, [account.id, fromDate, toDate, fiscalYear]);
  return <div className="modal-overlay" onMouseDown={(event) => event.target === event.currentTarget && onClose()}>
    <div className="modal-card" style={{ maxWidth: 1000 }}>
      <div className="panel-head"><h3>{account.account_code} · {account.name}</h3><button className="ghost-btn" onClick={onClose}>Close</button></div>
      {error && <p className="msg err">{error}</p>}
      {!data ? <p className="note">Loading ledger…</p> : <>
        <p className="note">Opening: {signedMoney(data.opening_balance)} · Closing: {signedMoney(data.closing_balance)}</p>
        <div style={{ overflowX: "auto" }}><table className="tbl"><thead><tr><th>Date</th><th>Voucher</th><th>Description</th><th className="num">Debit</th><th className="num">Credit</th><th className="num">Balance</th></tr></thead>
          <tbody>{(data.rows || []).map((row) => <tr key={row.id}><td>{row.date}</td><td>{titleCase(row.voucher_type)} #{row.voucher_number}</td><td>{row.description || row.narration || "—"}</td><td className="num">{Number(row.debit) ? money(row.debit) : ""}</td><td className="num">{Number(row.credit) ? money(row.credit) : ""}</td><td className="num">{signedMoney(row.running_balance)}</td></tr>)}</tbody>
        </table></div>
      </>}
    </div>
  </div>;
}

function csvSpec(report, data) {
  if (!data) return null;
  const rows = data.rows || [];
  if (report === "tb") return { rows, columns: [
    { label: "Account code", value: "account_code" }, { label: "Account", value: "name" },
    { label: "Report class", value: "report_class" }, { label: "Debit", value: "debit" }, { label: "Credit", value: "credit" },
  ] };
  if (["pl", "bs"].includes(report)) return { rows, columns: [
    { label: "Account code", value: "account_code" }, { label: "Account", value: "name" },
    { label: "Report class", value: "report_class" }, { label: "Amount", value: "amount" },
  ] };
  if (["receivables", "payables"].includes(report)) return { rows, columns: Object.keys(rows[0] || {}).map((key) => ({ label: titleCase(key), value: key })) };
  if (["sales", "purchases", "vat", "stock", "cashflow"].includes(report)) return { rows, columns: Object.keys(rows[0] || {}).filter((key) => !key.endsWith("_id")).map((key) => ({ label: titleCase(key), value: key })) };
  if (report === "daybook") return { rows, columns: [
    { label: "Date", value: "date" }, { label: "Voucher type", value: "voucher_type" },
    { label: "Voucher number", value: "voucher_number" }, { label: "Narration", value: "narration" },
    { label: "Debit", value: "debit" }, { label: "Credit", value: "credit" },
  ] };
  return null;
}
