import React, { useEffect, useState } from "react";
import { listAccounts, createVoucher, nextVoucherNumber } from "../lib/db";
import { currentFiscalYear } from "../lib/fiscalYear";

const VOUCHER_TYPES = [
  { value: "payment", label: "Payment" },
  { value: "receipt", label: "Receipt" },
  { value: "journal", label: "Journal" },
  { value: "contra", label: "Contra (cash ↔ bank)" },
];

const blankLine = () => ({ accountId: "", debit: "", credit: "", description: "" });

export default function VoucherEntry({ userId, onSaved }) {
  const [accounts, setAccounts] = useState([]);
  const [voucherType, setVoucherType] = useState("payment");
  const [voucherDate, setVoucherDate] = useState(new Date().toISOString().slice(0, 10));
  const [narration, setNarration] = useState("");
  const [lines, setLines] = useState([blankLine(), blankLine()]);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState(null);
  const [ok, setOk] = useState(null);

  useEffect(() => { listAccounts().then(setAccounts).catch((e) => setErr(e.message)); }, []);

  const totalDebit = lines.reduce((s, l) => s + (parseFloat(l.debit) || 0), 0);
  const totalCredit = lines.reduce((s, l) => s + (parseFloat(l.credit) || 0), 0);
  const balanced = Math.abs(totalDebit - totalCredit) < 0.005 && totalDebit > 0;

  const updateLine = (i, patch) => {
    setLines((ls) => ls.map((l, idx) => (idx === i ? { ...l, ...patch } : l)));
  };
  const addLine = () => setLines((ls) => [...ls, blankLine()]);
  const removeLine = (i) => setLines((ls) => ls.filter((_, idx) => idx !== i));

  const reset = () => {
    setLines([blankLine(), blankLine()]);
    setNarration("");
  };

  const submit = async (e) => {
    e.preventDefault();
    setErr(null);
    setOk(null);
    const validLines = lines.filter((l) => l.accountId && (parseFloat(l.debit) || parseFloat(l.credit)));
    if (validLines.length < 2) { setErr("Add at least two lines (one debit, one credit)."); return; }
    if (!balanced) { setErr("Total debit and total credit must be equal before saving."); return; }

    setBusy(true);
    try {
      const fiscalYear = currentFiscalYear();
      const voucherNumber = await nextVoucherNumber(voucherType, fiscalYear);
      await createVoucher(
        userId,
        {
          voucher_type: voucherType,
          voucher_number: voucherNumber,
          fiscal_year: fiscalYear,
          voucher_date: voucherDate,
          narration: narration.trim() || null,
        },
        validLines
      );
      setOk(`Saved ${voucherType} voucher #${voucherNumber} for FY ${fiscalYear}.`);
      reset();
      onSaved && onSaved();
    } catch (e) {
      setErr(e.message);
    }
    setBusy(false);
  };

  return (
    <div className="panel">
      <div className="panel-head"><h2>New Voucher</h2></div>
      <form onSubmit={submit}>
        <div className="voucher-header">
          <label className="fld">Type
            <select value={voucherType} onChange={(e) => setVoucherType(e.target.value)}>
              {VOUCHER_TYPES.map((t) => <option key={t.value} value={t.value}>{t.label}</option>)}
            </select>
          </label>
          <label className="fld">Date
            <input type="date" value={voucherDate} onChange={(e) => setVoucherDate(e.target.value)} required />
          </label>
          <label className="fld wide-field">Narration
            <input placeholder="What is this for?" value={narration} onChange={(e) => setNarration(e.target.value)} />
          </label>
        </div>

        <table className="tbl voucher-lines">
          <thead>
            <tr><th>Account</th><th className="num">Debit</th><th className="num">Credit</th><th>Description</th><th /></tr>
          </thead>
          <tbody>
            {lines.map((l, i) => (
              <tr key={i}>
                <td>
                  <select value={l.accountId} onChange={(e) => updateLine(i, { accountId: e.target.value })}>
                    <option value="">Select account…</option>
                    {accounts.map((a) => <option key={a.id} value={a.id}>{a.name}</option>)}
                  </select>
                </td>
                <td><input type="number" step="0.01" className="num-input" value={l.debit}
                  onChange={(e) => updateLine(i, { debit: e.target.value, credit: "" })} /></td>
                <td><input type="number" step="0.01" className="num-input" value={l.credit}
                  onChange={(e) => updateLine(i, { credit: e.target.value, debit: "" })} /></td>
                <td><input value={l.description} onChange={(e) => updateLine(i, { description: e.target.value })} /></td>
                <td>{lines.length > 2 && <button type="button" className="link" onClick={() => removeLine(i)}>✕</button>}</td>
              </tr>
            ))}
          </tbody>
          <tfoot>
            <tr>
              <td className="muted">Total</td>
              <td className="num">{totalDebit.toLocaleString()}</td>
              <td className="num">{totalCredit.toLocaleString()}</td>
              <td colSpan={2}>{!balanced && <span className="msg-inline err">Not balanced yet</span>}</td>
            </tr>
          </tfoot>
        </table>

        <button type="button" className="link" onClick={addLine}>+ Add line</button>
        <div className="voucher-actions">
          <button className="btn" disabled={busy || !balanced}>{busy ? "Saving…" : "Save Voucher"}</button>
        </div>
        {err && <p className="msg err">{err}</p>}
        {ok && <p className="msg ok">{ok}</p>}
      </form>
    </div>
  );
}
