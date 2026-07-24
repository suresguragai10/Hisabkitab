import React, { useEffect, useState } from "react";
import { supabase } from "../supabase";
import { currentFiscalYear } from "../lib/fiscalYear";
import { useWorkspace } from "../lib/workspace";
import { downloadCsv } from "../lib/reports";

const ANNEX13_COLUMNS = [
  { label: "Party Name",        value: "party_name" },
  { label: "Party PAN",         value: "party_pan" },
  { label: "Opening Balance",   value: "opening_balance" },
  { label: "Exempted Purchase", value: "exempted_purchase" },
  { label: "Vatable Purchase",  value: "vatable_purchase" },
  { label: "VAT on Purchase",   value: "vat_on_purchase" },
  { label: "Exempted Sales",    value: "exempted_sales" },
  { label: "Vatable Sales",     value: "vatable_sales" },
  { label: "VAT on Sales",      value: "vat_on_sales" },
  { label: "Closing Balance",   value: "closing_balance" },
];

async function listFiscalYearsWithPeriods() {
  const { data, error } = await supabase.from("fiscal_periods").select("fiscal_year");
  if (error) throw error;
  return [...new Set((data || []).map(r => r.fiscal_year))].sort().reverse();
}

const fmt = (n) => Number(n||0).toLocaleString(undefined,{minimumFractionDigits:2,maximumFractionDigits:2});

const SOURCE_LABELS = {
  sales_invoice: "Sales Invoice",
  sales_credit_note: "Sales Credit Note",
  purchase_bill: "Purchase Bill",
  purchase_debit_note: "Purchase Debit Note",
};

async function listPeriods(fiscalYear) {
  const { data, error } = await supabase.rpc("list_fiscal_periods", { p_fiscal_year: fiscalYear });
  if (error) throw error;
  return data || [];
}

async function listReturns(fiscalYear) {
  const { data, error } = await supabase.rpc("list_vat_returns", { p_fiscal_year: fiscalYear });
  if (error) throw error;
  return data || [];
}

export default function VatFiling() {
  const { role } = useWorkspace();
  const canEdit = ["owner","accountant"].includes(role);

  const [fiscalYear,  setFiscalYear]  = useState(currentFiscalYear());
  const [fiscalYears, setFiscalYears] = useState([]);
  const [periods,    setPeriods]    = useState([]);
  const [returns,    setReturns]    = useState([]);
  const [loading,    setLoading]    = useState(true);
  const [busy,       setBusy]       = useState(false);
  const [err,        setErr]        = useState(null);
  const [msg,        setMsg]        = useState(null);
  const [expanded,   setExpanded]   = useState(null); // period id
  const [filingRef,  setFilingRef]  = useState("");
  const [filingNotes,setFilingNotes]= useState("");

  const load = async () => {
    setLoading(true); setErr(null);
    try {
      const [p, r] = await Promise.all([listPeriods(fiscalYear), listReturns(fiscalYear)]);
      setPeriods(p); setReturns(r);
    } catch(e) { setErr(e.message); }
    setLoading(false);
  };

  useEffect(() => { load(); }, [fiscalYear]);

  useEffect(() => {
    listFiscalYearsWithPeriods()
      .then(years => setFiscalYears([...new Set([...years, currentFiscalYear()])].sort().reverse()))
      .catch(() => {});
  }, []);

  // list_vat_returns LEFT JOINs from fiscal_periods, so it always returns
  // exactly one row per period -- even when no return has been prepared
  // yet, in which case every vat_returns-side column (id, status,
  // snapshot, ...) is null. A row only represents a real prepared return
  // when its id is present.
  const returnFor = (periodId) => {
    const r = returns.find(r => r.fiscal_period_id === periodId);
    return (r && r.id) ? r : null;
  };

  const exportAnnex13 = async (period) => {
    setBusy(true); setErr(null); setMsg(null);
    try {
      const { data, error } = await supabase.rpc("get_annex13_report", { p_period_id: period.id });
      if (error) throw error;
      if (!data || data.length === 0) {
        setErr(`No party balances or VAT movement found for ${period.period_label}.`);
      } else {
        downloadCsv(`Annex13_${period.period_label.replace(/\s+/g, "_")}.csv`, ANNEX13_COLUMNS, data);
      }
    } catch(e) { setErr(e.message); }
    setBusy(false);
  };

  const prepare = async (period) => {
    const wasAlreadyDrafted = !!returnFor(period.id);
    setBusy(true); setErr(null); setMsg(null);
    try {
      await supabase.rpc("prepare_vat_return", { p_period_id: period.id }).then(({ error }) => { if (error) throw error; });
      setMsg(wasAlreadyDrafted
        ? `Draft refreshed for ${period.period_label} with the latest posted documents.`
        : `Draft VAT return prepared for ${period.period_label}.`);
      setExpanded(period.id);
      await load();
    } catch(e) { setErr(e.message); }
    setBusy(false);
  };

  const file = async (vatReturn) => {
    if (!filingRef.trim()) { setErr("Enter the filing reference before submitting."); return; }
    if (!window.confirm(`File this VAT return with reference "${filingRef.trim()}"? This locks the period and cannot be undone.`)) return;
    setBusy(true); setErr(null); setMsg(null);
    try {
      const { error } = await supabase.rpc("file_vat_return", {
        p_return_id: vatReturn.id,
        p_filing_reference: filingRef.trim(),
        p_notes: filingNotes.trim() || null,
      });
      if (error) throw error;
      setMsg("VAT return filed and the period is now locked.");
      setFilingRef(""); setFilingNotes("");
      await load();
    } catch(e) { setErr(e.message); }
    setBusy(false);
  };

  const statusOf = (period) => {
    const r = returnFor(period.id);
    if (!r) return { label: "Not prepared", cls: "status-draft" };
    if (r.status === "filed") return { label: "Filed", cls: "status-paid" };
    return { label: "Draft", cls: "status-partial" };
  };

  const totalFiled = returns.filter(r => r.status === "filed")
    .reduce((s, r) => s + Number(r.snapshot?.net_vat_payable || 0), 0);

  return (
    <div className="panel">
      <div className="panel-head">
        <h2>VAT Filing</h2>
        <label className="fld" style={{ margin: 0, flex: "0 0 160px" }}>
          Fiscal Year
          <select value={fiscalYear} onChange={e => setFiscalYear(e.target.value)} style={{ marginTop: 4 }}>
            {fiscalYears.map(y => <option key={y} value={y}>{y}</option>)}
          </select>
        </label>
      </div>

      <div className="settings-info-box">
        Each fiscal period can have one VAT return. <b>Prepare</b> creates a draft snapshot from your posted
        invoices, credit notes, purchase bills, and debit notes — nothing is final yet. <b>File</b> permanently
        submits it and locks the period; there is no undo, matching a real government filing.
      </div>

      {!canEdit && <p className="note">Only owner or accountant can prepare or file VAT returns.</p>}
      {err && <p className="msg err">{err}</p>}
      {msg && <p className="msg ok">{msg}</p>}

      <div className="stat-row">
        <div className="stat"><span>{returns.filter(r=>r.status==="filed").length}</span>Periods Filed</div>
        <div className="stat"><span>{periods.filter(p => !returnFor(p.id)).length}</span>Periods Not Prepared</div>
        <div className="stat"><span style={{color:"var(--rust)"}}>NPR {fmt(totalFiled)}</span>Total Filed Net VAT</div>
      </div>

      {loading ? <p className="note">Loading…</p> : periods.length === 0 ? (
        <p className="note">No fiscal periods set up for {fiscalYear} yet. Create them from Settings first.</p>
      ) : (
        <table className="tbl" style={{ marginTop: 8 }}>
          <thead>
            <tr><th>Period</th><th>From</th><th>To</th><th>VAT Status</th><th className="num">Net Payable</th><th/></tr>
          </thead>
          <tbody>
            {periods.map(p => {
              const r = returnFor(p.id);
              const s = statusOf(p);
              return (
                <React.Fragment key={p.id}>
                  <tr>
                    <td><b>{p.period_label}</b></td>
                    <td style={{ fontSize: 12 }}>{p.from_date}</td>
                    <td style={{ fontSize: 12 }}>{p.to_date}</td>
                    <td><span className={s.cls}>{s.label}</span></td>
                    <td className="num">{r ? `NPR ${fmt(r.snapshot?.net_vat_payable)}` : "—"}</td>
                    <td style={{ whiteSpace: "nowrap" }}>
                      {(!r || r.status === "draft") && canEdit && (
                        <button className="link" disabled={busy} onClick={() => prepare(p)}>
                          {r ? "Refresh" : "Prepare"}
                        </button>
                      )}
                      {r && (
                        <button className="link" onClick={() => setExpanded(expanded === p.id ? null : p.id)}>
                          {expanded === p.id ? "Hide" : "Review"}
                        </button>
                      )}
                      {" "}
                      <button className="link" disabled={busy} onClick={() => exportAnnex13(p)}>
                        Export Annex 13
                      </button>
                    </td>
                  </tr>
                  {expanded === p.id && r && (
                    <tr>
                      <td colSpan={6}>
                        <VatReturnDetail
                          vatReturn={r}
                          canEdit={canEdit}
                          busy={busy}
                          filingRef={filingRef}
                          filingNotes={filingNotes}
                          setFilingRef={setFilingRef}
                          setFilingNotes={setFilingNotes}
                          onFile={() => file(r)}
                        />
                      </td>
                    </tr>
                  )}
                </React.Fragment>
              );
            })}
          </tbody>
        </table>
      )}
    </div>
  );
}

function VatReturnDetail({ vatReturn, canEdit, busy, filingRef, filingNotes, setFilingRef, setFilingNotes, onFile }) {
  const snap = vatReturn.snapshot || {};
  const rows = snap.rows || [];

  return (
    <div style={{ padding: "16px 8px", background: "var(--panel2, #f8f8f6)", borderRadius: 8 }}>
      <div className="tds-calc-box">
        <div className="tds-calc-row"><span>Sales taxable</span><b>NPR {fmt(snap.sales_taxable)}</b></div>
        <div className="tds-calc-row"><span>Output VAT</span><b>NPR {fmt(snap.output_vat)}</b></div>
        <div className="tds-calc-row"><span>Purchase taxable</span><b>NPR {fmt(snap.purchase_taxable)}</b></div>
        <div className="tds-calc-row"><span>Input VAT</span><b>NPR {fmt(snap.input_vat)}</b></div>
        <div className="tds-calc-row tds-calc-total"><span>Net VAT payable</span><b>NPR {fmt(snap.net_vat_payable)}</b></div>
        <div className="tds-calc-row" style={{ color: snap.reconciled ? "var(--green2)" : "var(--rust)" }}>
          <span>{snap.reconciled ? "✓ Reconciled with VAT ledger" : "⚠ Not reconciled — cannot file until resolved"}</span>
        </div>
      </div>

      {rows.length > 0 && (
        <table className="tbl" style={{ marginTop: 12 }}>
          <thead>
            <tr><th>Date</th><th>Document</th><th>Party</th><th className="num">Taxable</th><th className="num">Output VAT</th><th className="num">Input VAT</th></tr>
          </thead>
          <tbody>
            {rows.map(row => (
              <tr key={row.source_id}>
                <td style={{ fontSize: 12 }}>{row.document_date}</td>
                <td style={{ fontSize: 12 }}>{SOURCE_LABELS[row.source_type] || row.source_type} #{row.document_number}</td>
                <td style={{ fontSize: 12 }}>{row.party_name}</td>
                <td className="num">{fmt(row.taxable_amount)}</td>
                <td className="num">{row.output_vat ? fmt(row.output_vat) : "—"}</td>
                <td className="num">{row.input_vat ? fmt(row.input_vat) : "—"}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}

      {vatReturn.status === "filed" ? (
        <div className="msg ok" style={{ marginTop: 12 }}>
          Filed on {new Date(vatReturn.filed_at).toLocaleDateString()} — reference <b>{vatReturn.filing_reference}</b>
          {vatReturn.notes && <div style={{ marginTop: 4, fontSize: 12 }}>{vatReturn.notes}</div>}
        </div>
      ) : canEdit ? (
        <div style={{ marginTop: 12 }}>
          <b style={{ display: "block", marginBottom: 8 }}>File this VAT return</b>
          <div className="inv-form-top">
            <label className="fld">Filing Reference <input placeholder="IRD acknowledgement / reference no." value={filingRef} onChange={e => setFilingRef(e.target.value)} /></label>
            <label className="fld wide-field">Notes <input placeholder="Optional" value={filingNotes} onChange={e => setFilingNotes(e.target.value)} /></label>
          </div>
          <button className="btn" disabled={busy || !snap.reconciled} onClick={onFile}>
            {busy ? "Filing…" : "File to IRD"}
          </button>
        </div>
      ) : null}
    </div>
  );
}
