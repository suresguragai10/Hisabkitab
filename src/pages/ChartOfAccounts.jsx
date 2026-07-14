import React, { useEffect, useState } from "react";
import { listAccounts, createAccount } from "../lib/db";

const TYPES = ["asset", "liability", "equity", "income", "expense"];

export default function ChartOfAccounts({ userId, onChanged }) {
  const [accounts, setAccounts] = useState([]);
  const [loading, setLoading] = useState(true);
  const [err, setErr] = useState(null);
  const [showForm, setShowForm] = useState(false);
  const [form, setForm] = useState({ name: "", account_type: "asset", group_name: "", opening_balance: "0", opening_balance_type: "debit" });
  const [busy, setBusy] = useState(false);

  const load = async () => {
    setLoading(true);
    try {
      setAccounts(await listAccounts());
      setErr(null);
    } catch (e) {
      setErr(e.message);
    }
    setLoading(false);
  };

  useEffect(() => { load(); }, []);

  const submit = async (e) => {
    e.preventDefault();
    if (!form.name.trim()) { setErr("Account name is required."); return; }
    setBusy(true);
    try {
      await createAccount(userId, {
        name: form.name.trim(),
        account_type: form.account_type,
        group_name: form.group_name.trim() || "General",
        opening_balance: parseFloat(form.opening_balance) || 0,
        opening_balance_type: form.opening_balance_type,
      });
      setForm({ name: "", account_type: "asset", group_name: "", opening_balance: "0", opening_balance_type: "debit" });
      setShowForm(false);
      await load();
      onChanged && onChanged();
    } catch (e) {
      setErr(e.message);
    }
    setBusy(false);
  };

  const grouped = accounts.reduce((acc, a) => {
    (acc[a.group_name] = acc[a.group_name] || []).push(a);
    return acc;
  }, {});

  return (
    <div className="panel">
      <div className="panel-head">
        <h2>Chart of Accounts</h2>
        <button className="btn" onClick={() => setShowForm((s) => !s)}>
          {showForm ? "Cancel" : "+ New Account"}
        </button>
      </div>

      {showForm && (
        <form className="inline-form" onSubmit={submit}>
          <input placeholder="Account name (e.g. Office Rent)" value={form.name}
            onChange={(e) => setForm({ ...form, name: e.target.value })} required />
          <select value={form.account_type} onChange={(e) => setForm({ ...form, account_type: e.target.value })}>
            {TYPES.map((t) => <option key={t} value={t}>{t}</option>)}
          </select>
          <input placeholder="Group (e.g. Indirect Expense)" value={form.group_name}
            onChange={(e) => setForm({ ...form, group_name: e.target.value })} />
          <input type="number" step="0.01" placeholder="Opening balance" value={form.opening_balance}
            onChange={(e) => setForm({ ...form, opening_balance: e.target.value })} />
          <select value={form.opening_balance_type} onChange={(e) => setForm({ ...form, opening_balance_type: e.target.value })}>
            <option value="debit">Debit</option>
            <option value="credit">Credit</option>
          </select>
          <button className="btn" disabled={busy}>{busy ? "Saving…" : "Save"}</button>
        </form>
      )}

      {err && <p className="msg err">{err}</p>}
      {loading ? <p className="note">Loading…</p> : (
        Object.keys(grouped).length === 0 ? (
          <p className="note">No accounts yet.</p>
        ) : (
          Object.entries(grouped).map(([group, list]) => (
            <div key={group} className="acct-group">
              <div className="acct-group-title">{group}</div>
              <table className="tbl">
                <tbody>
                  {list.map((a) => (
                    <tr key={a.id}>
                      <td>{a.name}{a.is_party_account && <span className="tag">party</span>}</td>
                      <td className="muted">{a.account_type}</td>
                      <td className="num">{Number(a.opening_balance).toLocaleString()} {a.opening_balance_type === "debit" ? "Dr" : "Cr"}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          ))
        )
      )}
    </div>
  );
}
