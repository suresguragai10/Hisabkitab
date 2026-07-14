import React, { useEffect, useState } from "react";
import { listAccounts, getLedger } from "../lib/db";

export default function Ledger() {
  const [accounts, setAccounts] = useState([]);
  const [accountId, setAccountId] = useState("");
  const [ledger, setLedger] = useState(null);
  const [loading, setLoading] = useState(false);
  const [err, setErr] = useState(null);

  useEffect(() => { listAccounts().then(setAccounts).catch((e) => setErr(e.message)); }, []);

  useEffect(() => {
    if (!accountId) { setLedger(null); return; }
    setLoading(true);
    getLedger(accountId)
      .then(setLedger)
      .catch((e) => setErr(e.message))
      .finally(() => setLoading(false));
  }, [accountId]);

  return (
    <div className="panel">
      <div className="panel-head"><h2>Ledger</h2></div>
      <label className="fld wide-field">Account
        <select value={accountId} onChange={(e) => setAccountId(e.target.value)}>
          <option value="">Select an account…</option>
          {accounts.map((a) => <option key={a.id} value={a.id}>{a.account_code ? `${a.account_code} · ${a.name}` : a.name}</option>)}
        </select>
      </label>

      {err && <p className="msg err">{err}</p>}
      {loading && <p className="note">Loading…</p>}

      {ledger && (
        <>
          <table className="tbl">
            <thead><tr><th>Date</th><th>Type / #</th><th>Description</th><th className="num">Debit</th><th className="num">Credit</th><th className="num">Balance</th></tr></thead>
            <tbody>
              <tr>
                <td colSpan={5} className="muted">Opening balance</td>
                <td className="num">
                  {Number(ledger.account.opening_balance).toLocaleString()} {ledger.account.opening_balance_type === "debit" ? "Dr" : "Cr"}
                </td>
              </tr>
              {ledger.entries.map((e) => (
                <tr key={e.id}>
                  <td>{e.vouchers.voucher_date}</td>
                  <td className="muted">{e.vouchers.voucher_type} #{e.vouchers.voucher_number}</td>
                  <td>{e.description || e.vouchers.narration || "—"}</td>
                  <td className="num">{Number(e.debit) ? Number(e.debit).toLocaleString() : ""}</td>
                  <td className="num">{Number(e.credit) ? Number(e.credit).toLocaleString() : ""}</td>
                  <td className="num">{Math.abs(e.runningBalance).toLocaleString()} {e.runningBalance >= 0 ? "Dr" : "Cr"}</td>
                </tr>
              ))}
            </tbody>
          </table>
          <p className="note">
            Closing balance: <b>{Math.abs(ledger.closingBalance).toLocaleString()} {ledger.closingBalance >= 0 ? "Dr" : "Cr"}</b>
          </p>
        </>
      )}
    </div>
  );
}
