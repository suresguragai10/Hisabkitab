import React, { useEffect, useState } from "react";
import { listAccounts } from "../lib/db";
import { downloadCsv, getGeneralLedgerReport, getReportFiscalYears } from "../lib/reports";
import { todayLocalDate, toLocalDateString } from "../lib/nepaliCalendar";

const money = (value) => Number(value || 0).toLocaleString(undefined, {
  minimumFractionDigits: 2,
  maximumFractionDigits: 2,
});
const balance = (value) => `${money(Math.abs(Number(value || 0)))} ${Number(value || 0) >= 0 ? "Dr" : "Cr"}`;
const today = () => todayLocalDate();
const defaultFrom = () => {
  const date = new Date();
  date.setMonth(date.getMonth() - 6);
  return toLocalDateString(date);
};

export default function Ledger() {
  const [accounts, setAccounts] = useState([]);
  const [fiscalYears, setFiscalYears] = useState([]);
  const [accountId, setAccountId] = useState("");
  const [fromDate, setFromDate] = useState(defaultFrom);
  const [toDate, setToDate] = useState(today);
  const [fiscalYear, setFiscalYear] = useState("");
  const [ledger, setLedger] = useState(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState(null);

  useEffect(() => {
    Promise.all([listAccounts(), getReportFiscalYears()])
      .then(([accountRows, yearRows]) => {
        setAccounts(accountRows || []);
        setFiscalYears(Array.isArray(yearRows) ? yearRows : []);
      })
      .catch((err) => setError(err.message));
  }, []);

  const run = async () => {
    if (!accountId) { setLedger(null); return; }
    setLoading(true);
    setError(null);
    try {
      setLedger(await getGeneralLedgerReport({
        accountId,
        fromDate,
        toDate,
        fiscalYear: fiscalYear || null,
      }));
    } catch (err) {
      setError(err.message || String(err));
      setLedger(null);
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => { if (accountId) run(); }, [accountId]);

  const exportCsv = () => {
    if (!ledger) return;
    downloadCsv(`HisabKitab-ledger-${ledger.account.account_code}-${fromDate}-to-${toDate}.csv`, [
      { label: "Date", value: "date" },
      { label: "Voucher type", value: "voucher_type" },
      { label: "Voucher number", value: "voucher_number" },
      { label: "Fiscal year", value: "fiscal_year" },
      { label: "Description", value: (row) => row.description || row.narration || "" },
      { label: "Debit", value: "debit" },
      { label: "Credit", value: "credit" },
      { label: "Running balance", value: "running_balance" },
    ], ledger.rows || []);
  };

  return (
    <div className="panel">
      <div className="panel-head"><h2>General Ledger</h2></div>
      <div style={{ display: "flex", gap: 12, alignItems: "end", flexWrap: "wrap", marginBottom: 16 }}>
        <label className="fld" style={{ margin: 0, minWidth: 250, flex: "1 1 280px" }}>Account
          <select value={accountId} onChange={(event) => setAccountId(event.target.value)}>
            <option value="">Select an account…</option>
            {accounts.map((account) => <option key={account.id} value={account.id}>{account.account_code ? `${account.account_code} · ${account.name}` : account.name}</option>)}
          </select>
        </label>
        <label className="fld" style={{ margin: 0, minWidth: 150 }}>From
          <input type="date" value={fromDate} onChange={(event) => setFromDate(event.target.value)} />
        </label>
        <label className="fld" style={{ margin: 0, minWidth: 150 }}>To
          <input type="date" value={toDate} onChange={(event) => setToDate(event.target.value)} />
        </label>
        <label className="fld" style={{ margin: 0, minWidth: 145 }}>Fiscal year
          <select value={fiscalYear} onChange={(event) => setFiscalYear(event.target.value)}>
            <option value="">All</option>
            {fiscalYears.map((year) => <option key={year} value={year}>{year}</option>)}
          </select>
        </label>
        <button className="btn" onClick={run} disabled={!accountId || loading}>{loading ? "Running…" : "Run"}</button>
        <button className="ghost-btn" onClick={exportCsv} disabled={!ledger}>Export CSV</button>
        <button className="ghost-btn" onClick={() => window.print()} disabled={!ledger}>Print</button>
      </div>

      {error && <p className="msg err">{error}</p>}
      {loading && <p className="note">Loading ledger…</p>}
      {ledger && !loading && <>
        <div className="stat-row">
          <div className="stat"><small>Opening</small><span>{balance(ledger.opening_balance)}</span></div>
          <div className="stat"><small>Period debit</small><span>{money(ledger.period_debit)}</span></div>
          <div className="stat"><small>Period credit</small><span>{money(ledger.period_credit)}</span></div>
          <div className="stat"><small>Closing</small><span>{balance(ledger.closing_balance)}</span></div>
        </div>
        <div style={{ overflowX: "auto" }}><table className="tbl">
          <thead><tr><th>Date</th><th>Voucher</th><th>Description</th><th className="num">Debit</th><th className="num">Credit</th><th className="num">Balance</th></tr></thead>
          <tbody>
            <tr><td>{fromDate}</td><td>Opening</td><td>Balance brought forward</td><td /><td /><td className="num">{balance(ledger.opening_balance)}</td></tr>
            {(ledger.rows || []).map((row) => <tr key={row.id}>
              <td>{row.date}</td><td>{row.voucher_type} #{row.voucher_number}</td><td>{row.description || row.narration || "—"}</td>
              <td className="num">{Number(row.debit) ? money(row.debit) : ""}</td><td className="num">{Number(row.credit) ? money(row.credit) : ""}</td>
              <td className="num">{balance(row.running_balance)}</td>
            </tr>)}
          </tbody>
        </table></div>
      </>}
    </div>
  );
}
