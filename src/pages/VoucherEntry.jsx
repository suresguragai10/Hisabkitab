import React, { useEffect, useMemo, useState } from "react";
import BsDateInput from "../components/BsDateInput";
import { createVoucher, listAccounts } from "../lib/db";
import { fiscalYearFor } from "../lib/fiscalYear";
import { t } from "../lib/i18n";

const VOUCHER_TYPES = [
  { value: "journal", labelKey: "journal", help: "Use for adjustments, accruals, depreciation and other non-cash entries." },
  { value: "payment", labelKey: "payment", help: "Use when money is paid from cash or bank." },
  { value: "receipt", labelKey: "receipt", help: "Use when money is received into cash or bank." },
  { value: "contra", labelKey: "contra", help: "Use for transfers between cash and bank accounts." },
];

const money = new Intl.NumberFormat("en-NP", {
  minimumFractionDigits: 2,
  maximumFractionDigits: 2,
});

function localDateString(date = new Date()) {
  const year = date.getFullYear();
  const month = String(date.getMonth() + 1).padStart(2, "0");
  const day = String(date.getDate()).padStart(2, "0");
  return `${year}-${month}-${day}`;
}

function blankLine() {
  return { accountId: "", debit: "", credit: "", description: "" };
}

function initialLines() {
  return [blankLine(), blankLine()];
}

export default function VoucherEntry({ userId, onSaved, lang = "en" }) {
  const today = localDateString();
  const [accounts, setAccounts] = useState([]);
  const [loadingAccounts, setLoadingAccounts] = useState(true);
  const [voucherType, setVoucherType] = useState("journal");
  const [voucherDate, setVoucherDate] = useState(today);
  const [fiscalYear, setFiscalYear] = useState(fiscalYearFor(new Date(`${today}T12:00:00`)));
  const [narration, setNarration] = useState("");
  const [lines, setLines] = useState(initialLines);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);
  const [success, setSuccess] = useState(null);

  useEffect(() => {
    let active = true;
    async function load() {
      setLoadingAccounts(true);
      try {
        const data = await listAccounts();
        if (active) {
          setAccounts(data.filter((account) => account.allow_manual_posting !== false));
          setError(null);
        }
      } catch (err) {
        if (active) setError(err.message);
      } finally {
        if (active) setLoadingAccounts(false);
      }
    }
    load();
    return () => { active = false; };
  }, []);

  const groupedAccounts = useMemo(() => {
    return accounts.reduce((groups, account) => {
      const group = account.report_class ? account.report_class.replaceAll("_", " ") : (account.group_name || "General");
      if (!groups[group]) groups[group] = [];
      groups[group].push(account);
      return groups;
    }, {});
  }, [accounts]);

  const totals = useMemo(() => {
    const debit = lines.reduce((sum, line) => sum + (Number(line.debit) || 0), 0);
    const credit = lines.reduce((sum, line) => sum + (Number(line.credit) || 0), 0);
    return { debit, credit, difference: debit - credit };
  }, [lines]);

  const isBalanced = totals.debit > 0 && Math.abs(totals.difference) <= 0.005;
  const currentType = VOUCHER_TYPES.find((type) => type.value === voucherType);

  const updateDate = (nextDate) => {
    setVoucherDate(nextDate);
    setFiscalYear(fiscalYearFor(new Date(`${nextDate}T12:00:00`)));
  };

  const updateLine = (index, field, value) => {
    setLines((current) => current.map((line, lineIndex) => {
      if (lineIndex !== index) return line;
      if (field === "debit" && value !== "") return { ...line, debit: value, credit: "" };
      if (field === "credit" && value !== "") return { ...line, credit: value, debit: "" };
      return { ...line, [field]: value };
    }));
    setError(null);
    setSuccess(null);
  };

  const addLine = () => setLines((current) => [...current, blankLine()]);

  const removeLine = (index) => {
    setLines((current) => current.length <= 2 ? current : current.filter((_, lineIndex) => lineIndex !== index));
  };

  const resetForm = () => {
    const nextToday = localDateString();
    setVoucherType("journal");
    setVoucherDate(nextToday);
    setFiscalYear(fiscalYearFor(new Date(`${nextToday}T12:00:00`)));
    setNarration("");
    setLines(initialLines());
  };

  const validate = () => {
    const entered = lines.filter((line) => line.accountId || Number(line.debit) || Number(line.credit) || line.description.trim());
    if (entered.length < 2) return "Enter at least two voucher lines.";

    for (let index = 0; index < entered.length; index += 1) {
      const line = entered[index];
      const debit = Number(line.debit) || 0;
      const credit = Number(line.credit) || 0;
      if (!line.accountId) return `Select an account on line ${index + 1}.`;
      if (debit < 0 || credit < 0) return `Amounts cannot be negative on line ${index + 1}.`;
      if ((debit > 0 && credit > 0) || (debit === 0 && credit === 0)) {
        return `Enter either a debit or a credit on line ${index + 1}.`;
      }
    }

    if (!isBalanced) return t("notBalanced", lang);
    return null;
  };

  const submit = async (event) => {
    event.preventDefault();
    setError(null);
    setSuccess(null);

    const validationError = validate();
    if (validationError) {
      setError(validationError);
      return;
    }

    const enteredLines = lines.filter((line) => Number(line.debit) || Number(line.credit));
    setBusy(true);
    try {
      const voucher = await createVoucher(userId, {
        voucher_type: voucherType,
        fiscal_year: fiscalYear,
        voucher_date: voucherDate,
        narration: narration.trim() || null,
      }, enteredLines);

      const displayNumber = voucher?.voucher_number ? ` #${voucher.voucher_number}` : "";
      const typeLabel = currentType ? t(currentType.labelKey, lang) : t("vouchers", lang);
      setSuccess(
        lang === "np"
          ? `${typeLabel}${displayNumber} सफलतापूर्वक सुरक्षित भयो।`
          : `${typeLabel}${displayNumber} saved successfully.`
      );
      resetForm();
      onSaved && onSaved();
    } catch (err) {
      setError(err.message);
    } finally {
      setBusy(false);
    }
  };

  return (
    <section className="panel voucher-entry-panel">
      <div className="panel-head voucher-entry-head">
        <div>
          <h2>{lang === "np" ? "नयाँ भाउचर" : "New Voucher"}</h2>
          <p className="voucher-help">{currentType?.help}</p>
        </div>
        <div className={`voucher-balance ${isBalanced ? "balanced" : "unbalanced"}`}>
          <span>{isBalanced ? "Balanced" : "Difference"}</span>
          <strong>NPR {money.format(Math.abs(totals.difference))}</strong>
        </div>
      </div>

      <form onSubmit={submit}>
        <div className="voucher-meta-grid">
          <label className="fld">
            {t("voucherType", lang)}
            <select value={voucherType} onChange={(event) => setVoucherType(event.target.value)}>
              {VOUCHER_TYPES.map((type) => (
                <option key={type.value} value={type.value}>{t(type.labelKey, lang)}</option>
              ))}
            </select>
          </label>

          <label className="fld">
            {t("date", lang)}
            <BsDateInput value={voucherDate} onChange={updateDate} lang={lang} />
          </label>

          <label className="fld">
            {t("fiscalYear", lang)}
            <input value={fiscalYear} readOnly aria-label={t("fiscalYear", lang)} />
          </label>

          <label className="fld voucher-narration-field">
            {t("narration", lang)}
            <input
              value={narration}
              onChange={(event) => setNarration(event.target.value)}
              placeholder={lang === "np" ? "कारोबारको छोटो विवरण" : "Short description of the transaction"}
              maxLength={500}
            />
          </label>
        </div>

        <div className="table-scroll">
          <table className="tbl voucher-lines voucher-entry-table">
            <thead>
              <tr>
                <th className="voucher-line-number">#</th>
                <th>{t("account", lang)}</th>
                <th>Description</th>
                <th className="num">{t("debit", lang)}</th>
                <th className="num">{t("credit", lang)}</th>
                <th aria-label="Actions" />
              </tr>
            </thead>
            <tbody>
              {lines.map((line, index) => (
                <tr key={index}>
                  <td className="voucher-line-number">{index + 1}</td>
                  <td className="voucher-account-cell">
                    <select
                      value={line.accountId}
                      onChange={(event) => updateLine(index, "accountId", event.target.value)}
                      aria-label={`Account for line ${index + 1}`}
                      disabled={loadingAccounts}
                    >
                      <option value="">{loadingAccounts ? "Loading accounts…" : "Select account"}</option>
                      {Object.entries(groupedAccounts).map(([group, groupAccounts]) => (
                        <optgroup key={group} label={group}>
                          {groupAccounts.map((account) => (
                            <option key={account.id} value={account.id}>{account.account_code ? `${account.account_code} · ${account.name}` : account.name}</option>
                          ))}
                        </optgroup>
                      ))}
                    </select>
                  </td>
                  <td>
                    <input
                      value={line.description}
                      onChange={(event) => updateLine(index, "description", event.target.value)}
                      placeholder="Line description"
                      maxLength={250}
                      aria-label={`Description for line ${index + 1}`}
                    />
                  </td>
                  <td>
                    <input
                      className="num-input"
                      type="number"
                      min="0"
                      step="0.01"
                      inputMode="decimal"
                      value={line.debit}
                      onChange={(event) => updateLine(index, "debit", event.target.value)}
                      placeholder="0.00"
                      aria-label={`Debit amount for line ${index + 1}`}
                    />
                  </td>
                  <td>
                    <input
                      className="num-input"
                      type="number"
                      min="0"
                      step="0.01"
                      inputMode="decimal"
                      value={line.credit}
                      onChange={(event) => updateLine(index, "credit", event.target.value)}
                      placeholder="0.00"
                      aria-label={`Credit amount for line ${index + 1}`}
                    />
                  </td>
                  <td className="voucher-remove-cell">
                    <button
                      type="button"
                      className="icon-btn danger"
                      onClick={() => removeLine(index)}
                      disabled={lines.length <= 2}
                      aria-label={`Remove line ${index + 1}`}
                      title="Remove line"
                    >
                      ×
                    </button>
                  </td>
                </tr>
              ))}
            </tbody>
            <tfoot>
              <tr>
                <td colSpan="3">Totals</td>
                <td className="num">NPR {money.format(totals.debit)}</td>
                <td className="num">NPR {money.format(totals.credit)}</td>
                <td />
              </tr>
            </tfoot>
          </table>
        </div>

        <div className="voucher-actions">
          <button type="button" className="ghost-btn" onClick={addLine}>+ Add line</button>
          <div className="voucher-submit-actions">
            <button type="button" className="ghost-btn" onClick={resetForm} disabled={busy}>Clear</button>
            <button className="btn" disabled={busy || loadingAccounts || accounts.length === 0 || !isBalanced}>
              {busy ? t("saving", lang) : (lang === "np" ? "भाउचर सुरक्षित गर्नुस्" : "Save Voucher")}
            </button>
          </div>
        </div>
      </form>

      {error && <p className="msg err" role="alert">{error}</p>}
      {success && <p className="msg ok" role="status">{success}</p>}
      {!loadingAccounts && accounts.length === 0 && (
        <p className="msg err">Create at least two accounts in Chart of Accounts before recording a voucher.</p>
      )}
    </section>
  );
}
