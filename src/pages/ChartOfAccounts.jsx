import React, { useEffect, useMemo, useState } from "react";
import BsDateInput from "../components/BsDateInput";
import { fiscalYearFor } from "../lib/fiscalYear";
import {
  createStructuredAccount,
  deactivateStructuredAccount,
  listOpeningJournals,
  listStructuredAccounts,
  migrateLegacyOpeningBalances,
  postOpeningJournal,
  updateStructuredAccount,
} from "../lib/accounts";

const TYPE_CLASSES = {
  asset: ["current_asset", "non_current_asset"],
  liability: ["current_liability", "non_current_liability"],
  equity: ["equity"],
  income: ["revenue", "other_income"],
  expense: ["cost_of_sales", "operating_expense", "other_expense"],
};

const CLASS_LABELS = {
  current_asset: "Current Assets",
  non_current_asset: "Non-Current Assets",
  current_liability: "Current Liabilities",
  non_current_liability: "Non-Current Liabilities",
  equity: "Equity",
  revenue: "Revenue",
  cost_of_sales: "Cost of Sales",
  operating_expense: "Operating Expenses",
  other_income: "Other Income",
  other_expense: "Other Expenses",
};

const SUBTYPES = [
  "general", "cash", "bank", "receivable", "payable", "inventory",
  "input_tax", "output_tax", "fixed_asset", "accumulated_depreciation",
  "capital", "drawings", "sales", "purchases", "cost_of_goods_sold",
  "operating_expense", "other_income", "other_expense",
];

const CF_CATEGORIES = ["operating", "investing", "financing", "non_cash", "not_applicable"];
const today = () => new Date().toISOString().slice(0, 10);
const blankOpeningLine = () => ({ accountId: "", debit: "", credit: "", description: "" });

function defaultForm() {
  return {
    name: "",
    accountCode: "",
    accountType: "asset",
    reportClass: "current_asset",
    accountSubtype: "general",
    normalBalance: "debit",
    parentAccountId: "",
    cashFlowCategory: "operating",
    allowManualPosting: true,
  };
}

function AccountForm({ initial, accounts, busy, error, onSave, onCancel }) {
  const [form, setForm] = useState(initial || defaultForm());
  const set = (key, value) => setForm((current) => ({ ...current, [key]: value }));
  const classes = TYPE_CLASSES[form.accountType] || [];

  const changeType = (accountType) => {
    const reportClass = TYPE_CLASSES[accountType][0];
    setForm((current) => ({
      ...current,
      accountType,
      reportClass,
      normalBalance: accountType === "asset" || accountType === "expense" ? "debit" : "credit",
      cashFlowCategory: accountType === "asset" && reportClass === "non_current_asset"
        ? "investing"
        : accountType === "equity" || accountType === "liability"
          ? "financing"
          : "operating",
    }));
  };

  return (
    <form className="grid-form" onSubmit={(event) => { event.preventDefault(); onSave(form); }}>
      <label className="fld">Account code
        <input value={form.accountCode} onChange={(e) => set("accountCode", e.target.value)} placeholder="Auto-generated if blank" disabled={initial?.isSystemAccount} />
      </label>
      <label className="fld">Account name *
        <input required value={form.name} onChange={(e) => set("name", e.target.value)} disabled={initial?.isSystemAccount} />
      </label>
      <label className="fld">Account type
        <select value={form.accountType} onChange={(e) => changeType(e.target.value)} disabled={initial?.isSystemAccount}>
          {Object.keys(TYPE_CLASSES).map((type) => <option key={type} value={type}>{type}</option>)}
        </select>
      </label>
      <label className="fld">Report class
        <select value={form.reportClass} onChange={(e) => set("reportClass", e.target.value)} disabled={initial?.isSystemAccount}>
          {classes.map((value) => <option key={value} value={value}>{CLASS_LABELS[value]}</option>)}
        </select>
      </label>
      <label className="fld">Subtype
        <select value={form.accountSubtype} onChange={(e) => set("accountSubtype", e.target.value)} disabled={initial?.isSystemAccount}>
          {SUBTYPES.map((value) => <option key={value} value={value}>{value.replaceAll("_", " ")}</option>)}
        </select>
      </label>
      <label className="fld">Normal balance
        <select value={form.normalBalance} onChange={(e) => set("normalBalance", e.target.value)} disabled={initial?.isSystemAccount}>
          <option value="debit">Debit</option>
          <option value="credit">Credit</option>
        </select>
      </label>
      <label className="fld">Parent account
        <select value={form.parentAccountId} onChange={(e) => set("parentAccountId", e.target.value)}>
          <option value="">No parent</option>
          {accounts.filter((account) => account.id !== initial?.id && account.is_active).map((account) => (
            <option key={account.id} value={account.id}>{account.account_code} · {account.name}</option>
          ))}
        </select>
      </label>
      <label className="fld">Cash-flow category
        <select value={form.cashFlowCategory} onChange={(e) => set("cashFlowCategory", e.target.value)} disabled={initial?.isSystemAccount}>
          {CF_CATEGORIES.map((value) => <option key={value} value={value}>{value.replaceAll("_", " ")}</option>)}
        </select>
      </label>
      <label style={{ display: "flex", gap: 8, alignItems: "center" }}>
        <input type="checkbox" checked={form.allowManualPosting} onChange={(e) => set("allowManualPosting", e.target.checked)} disabled={initial?.isSystemAccount} />
        Allow manual voucher posting
      </label>
      {error && <p className="msg err wide-field">{error}</p>}
      <div className="modal-actions wide-field">
        <button type="button" className="ghost-btn" onClick={onCancel}>Cancel</button>
        <button className="btn" disabled={busy}>{busy ? "Saving…" : "Save account"}</button>
      </div>
    </form>
  );
}

function OpeningJournal({ accounts, legacy, journals, onClose, onPosted }) {
  const start = today();
  const [date, setDate] = useState(start);
  const [fiscalYear, setFiscalYear] = useState(fiscalYearFor(new Date(`${start}T12:00:00`)));
  const [notes, setNotes] = useState("");
  const [lines, setLines] = useState([blankOpeningLine(), blankOpeningLine()]);
  const [offsetAccountId, setOffsetAccountId] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);
  const balanceAccounts = accounts.filter((account) => account.is_active && !["revenue", "cost_of_sales", "operating_expense", "other_income", "other_expense"].includes(account.report_class));
  const totals = lines.reduce((sum, line) => ({
    debit: sum.debit + (Number(line.debit) || 0),
    credit: sum.credit + (Number(line.credit) || 0),
  }), { debit: 0, credit: 0 });

  const updateDate = (value) => {
    setDate(value);
    setFiscalYear(fiscalYearFor(new Date(`${value}T12:00:00`)));
  };
  const updateLine = (index, key, value) => setLines((current) => current.map((line, lineIndex) => {
    if (lineIndex !== index) return line;
    if (key === "debit" && value !== "") return { ...line, debit: value, credit: "" };
    if (key === "credit" && value !== "") return { ...line, credit: value, debit: "" };
    return { ...line, [key]: value };
  }));

  const post = async () => {
    setBusy(true); setError(null);
    try {
      await postOpeningJournal({ fiscalYear, date, notes, lines });
      await onPosted();
      onClose();
    } catch (e) { setError(e.message); }
    setBusy(false);
  };

  const convertLegacy = async () => {
    setBusy(true); setError(null);
    try {
      await migrateLegacyOpeningBalances({ fiscalYear, date, offsetAccountId, notes });
      await onPosted();
      onClose();
    } catch (e) { setError(e.message); }
    setBusy(false);
  };

  return (
    <div className="modal-overlay" onClick={onClose}>
      <div className="modal-card" style={{ maxWidth: 920 }} onClick={(e) => e.stopPropagation()}>
        <div className="modal-head"><h3>Opening Journal</h3><button className="link" onClick={onClose}>✕</button></div>
        <div className="grid-form">
          <label className="fld">Opening date<BsDateInput value={date} onChange={updateDate} /></label>
          <label className="fld">Fiscal year<input value={fiscalYear} onChange={(e) => setFiscalYear(e.target.value)} /></label>
          <label className="fld wide-field">Notes<input value={notes} onChange={(e) => setNotes(e.target.value)} placeholder="Opening balances approved by…" /></label>
        </div>

        {legacy.count > 0 && (
          <div className="msg" style={{ marginBottom: 14 }}>
            <b>Legacy opening balances found:</b> {legacy.count} account(s), Dr NPR {legacy.debit.toLocaleString()} / Cr NPR {legacy.credit.toLocaleString()}.
            {Math.abs(legacy.debit - legacy.credit) > 0.005 && (
              <label className="fld" style={{ marginTop: 10 }}>Offset account required for NPR {Math.abs(legacy.debit - legacy.credit).toLocaleString()}
                <select value={offsetAccountId} onChange={(e) => setOffsetAccountId(e.target.value)}>
                  <option value="">Select offset account</option>
                  {balanceAccounts.map((account) => <option key={account.id} value={account.id}>{account.account_code} · {account.name}</option>)}
                </select>
              </label>
            )}
            <button className="ghost-btn" type="button" disabled={busy} onClick={convertLegacy}>Convert legacy balances</button>
          </div>
        )}

        <div className="table-scroll">
          <table className="tbl">
            <thead><tr><th>Account</th><th>Description</th><th className="num">Debit</th><th className="num">Credit</th><th /></tr></thead>
            <tbody>{lines.map((line, index) => (
              <tr key={index}>
                <td><select value={line.accountId} onChange={(e) => updateLine(index, "accountId", e.target.value)}>
                  <option value="">Select account</option>
                  {balanceAccounts.map((account) => <option key={account.id} value={account.id}>{account.account_code} · {account.name}</option>)}
                </select></td>
                <td><input value={line.description} onChange={(e) => updateLine(index, "description", e.target.value)} /></td>
                <td><input className="num" type="number" min="0" step="0.01" value={line.debit} onChange={(e) => updateLine(index, "debit", e.target.value)} /></td>
                <td><input className="num" type="number" min="0" step="0.01" value={line.credit} onChange={(e) => updateLine(index, "credit", e.target.value)} /></td>
                <td><button className="link" type="button" onClick={() => setLines((current) => current.length > 2 ? current.filter((_, i) => i !== index) : current)}>Remove</button></td>
              </tr>
            ))}</tbody>
          </table>
        </div>
        <button className="ghost-btn" type="button" onClick={() => setLines((current) => [...current, blankOpeningLine()])}>+ Add line</button>
        <div className={`net-result ${Math.abs(totals.debit - totals.credit) <= 0.005 && totals.debit > 0 ? "profit" : "loss"}`} style={{ marginTop: 12 }}>
          <span>Debit NPR {totals.debit.toLocaleString()} · Credit NPR {totals.credit.toLocaleString()}</span>
          <span>Difference NPR {Math.abs(totals.debit - totals.credit).toLocaleString()}</span>
        </div>
        {journals.length > 0 && <p className="note">Existing opening journal: {journals[0].fiscal_year} on {journals[0].opening_date}</p>}
        {error && <p className="msg err">{error}</p>}
        <div className="modal-actions"><button className="ghost-btn" onClick={onClose}>Cancel</button><button className="btn" disabled={busy} onClick={post}>{busy ? "Posting…" : "Post opening journal"}</button></div>
      </div>
    </div>
  );
}

function flattenTree(accounts) {
  const children = new Map();
  accounts.forEach((account) => {
    const key = account.parent_account_id || "root";
    if (!children.has(key)) children.set(key, []);
    children.get(key).push(account);
  });
  children.forEach((list) => list.sort((a, b) => String(a.account_code).localeCompare(String(b.account_code), undefined, { numeric: true })));
  const rows = [];
  const visit = (parentId, depth, seen = new Set()) => {
    (children.get(parentId) || []).forEach((account) => {
      if (seen.has(account.id)) return;
      rows.push({ account, depth });
      visit(account.id, depth + 1, new Set([...seen, account.id]));
    });
  };
  visit("root", 0);
  accounts.filter((account) => !rows.some((row) => row.account.id === account.id)).forEach((account) => rows.push({ account, depth: 0 }));
  return rows;
}

export default function ChartOfAccounts({ onChanged }) {
  const [accounts, setAccounts] = useState([]);
  const [journals, setJournals] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);
  const [formError, setFormError] = useState(null);
  const [editing, setEditing] = useState(null);
  const [showForm, setShowForm] = useState(false);
  const [showOpening, setShowOpening] = useState(false);
  const [busy, setBusy] = useState(false);
  const [filter, setFilter] = useState("all");

  const load = async () => {
    setLoading(true);
    try {
      const [accountRows, openingRows] = await Promise.all([listStructuredAccounts(), listOpeningJournals()]);
      setAccounts(accountRows); setJournals(openingRows); setError(null);
    } catch (e) { setError(e.message); }
    setLoading(false);
  };
  useEffect(() => { load(); }, []);

  const legacy = useMemo(() => accounts.reduce((result, account) => {
    const amount = Number(account.opening_balance || 0);
    if (amount > 0) {
      result.count += 1;
      if (account.opening_balance_type === "credit") result.credit += amount;
      else result.debit += amount;
    }
    return result;
  }, { count: 0, debit: 0, credit: 0 }), [accounts]);

  const visible = useMemo(() => {
    const filtered = filter === "all" ? accounts : accounts.filter((account) => account.report_class === filter);
    return flattenTree(filtered);
  }, [accounts, filter]);

  const save = async (form) => {
    setBusy(true); setFormError(null);
    try {
      if (editing) await updateStructuredAccount(editing.id, form);
      else await createStructuredAccount(form);
      setEditing(null); setShowForm(false); await load(); onChanged?.();
    } catch (e) { setFormError(e.message); }
    setBusy(false);
  };

  const beginEdit = (account) => {
    setEditing({
      id: account.id,
      isSystemAccount: account.is_system_account,
      name: account.name,
      accountCode: account.account_code,
      accountType: account.account_type,
      reportClass: account.report_class,
      accountSubtype: account.account_subtype,
      normalBalance: account.normal_balance,
      parentAccountId: account.parent_account_id || "",
      cashFlowCategory: account.cash_flow_category,
      allowManualPosting: account.allow_manual_posting,
    });
    setShowForm(true); setFormError(null);
  };

  const deactivate = async (account) => {
    if (!window.confirm(`Deactivate ${account.account_code} · ${account.name}?`)) return;
    setError(null);
    try { await deactivateStructuredAccount(account.id); await load(); onChanged?.(); }
    catch (e) { setError(e.message); }
  };

  return (
    <div className="panel">
      <div className="panel-head">
        <div><h2>Chart of Accounts</h2><p className="note">Structured codes and report classes drive financial statements.</p></div>
        <div style={{ display: "flex", gap: 8, flexWrap: "wrap" }}>
          <button className="ghost-btn" onClick={() => setShowOpening(true)}>Opening Journal</button>
          <button className="btn" onClick={() => { setEditing(null); setShowForm((value) => !value); setFormError(null); }}>{showForm ? "Close" : "+ New Account"}</button>
        </div>
      </div>

      {showForm && <AccountForm key={editing?.id || "new"} initial={editing} accounts={accounts} busy={busy} error={formError} onSave={save} onCancel={() => { setShowForm(false); setEditing(null); }} />}
      {error && <p className="msg err">{error}</p>}
      {legacy.count > 0 && <p className="msg">{legacy.count} legacy opening balance(s) remain. Convert them from <b>Opening Journal</b>.</p>}

      <div className="filter-tabs" style={{ marginBottom: 14 }}>
        <button className={`filter-tab${filter === "all" ? " active" : ""}`} onClick={() => setFilter("all")}>All</button>
        {Object.entries(CLASS_LABELS).map(([value, label]) => <button key={value} className={`filter-tab${filter === value ? " active" : ""}`} onClick={() => setFilter(value)}>{label}</button>)}
      </div>

      {loading ? <p className="note">Loading…</p> : (
        <div className="table-scroll">
          <table className="tbl">
            <thead><tr><th>Code</th><th>Account</th><th>Report class</th><th>Subtype</th><th>Normal</th><th>Flags</th><th /></tr></thead>
            <tbody>{visible.map(({ account, depth }) => (
              <tr key={account.id} style={{ opacity: account.is_active ? 1 : 0.55 }}>
                <td><b>{account.account_code}</b></td>
                <td style={{ paddingLeft: 12 + depth * 22 }}>{depth > 0 && <span className="muted">↳ </span>}{account.name}</td>
                <td>{CLASS_LABELS[account.report_class] || account.report_class}</td>
                <td className="muted">{account.account_subtype?.replaceAll("_", " ")}</td>
                <td>{account.normal_balance === "debit" ? "Dr" : "Cr"}</td>
                <td>
                  {account.is_system_account && <span className="tag">system</span>}
                  {account.is_control_account && <span className="tag">control</span>}
                  {account.is_party_account && <span className="tag">party</span>}
                  {!account.allow_manual_posting && <span className="tag">no manual</span>}
                  {!account.is_active && <span className="tag">inactive</span>}
                </td>
                <td style={{ whiteSpace: "nowrap" }}>
                  {!account.is_system_account && <button className="link" onClick={() => beginEdit(account)}>Edit</button>}
                  {!account.is_system_account && !account.is_control_account && !account.is_party_account && account.is_active && <button className="link" onClick={() => deactivate(account)}>Deactivate</button>}
                </td>
              </tr>
            ))}</tbody>
          </table>
        </div>
      )}
      {showOpening && <OpeningJournal accounts={accounts} legacy={legacy} journals={journals} onClose={() => setShowOpening(false)} onPosted={async () => { await load(); onChanged?.(); }} />}
    </div>
  );
}
