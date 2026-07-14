import React, { useEffect, useState } from "react";
import { supabase } from "../supabase";
import { currentFiscalYear } from "../lib/fiscalYear";
import { useWorkspace } from "../lib/workspace";

// ── Nepal fiscal year months (Shrawan start) ─────────────────
// Approximate AD date ranges for each BS month in the fiscal year
// BS 2081/82 = 2024-07-17 to 2025-07-15 (typical)
const NEPALI_MONTHS = [
  "Shrawan","Bhadra","Ashwin","Kartik","Mangsir","Poush",
  "Magh","Falgun","Chaitra","Baishakh","Jestha","Ashadh"
];

function generatePeriods(fiscalYear) {
  // Parse "2081/82" to get BS year
  const bsYear = parseInt(fiscalYear.split("/")[0]);
  // Each period is a BS month; approximate AD dates
  // Shrawan 2081 ≈ 2024-07-17 to 2024-08-16
  // We use approximate 30-day months; the exact mapping is in nepaliCalendar
  // For period locks, approximate dates are fine — the check is by stored from/to
  const base = new Date(2024, 6, 17); // approx Shrawan 1 = Jul 17 2024 for 2081
  const yearOffset = bsYear - 2081;
  const startMs = base.getTime() + yearOffset * 365.25 * 24 * 3600 * 1000;

  return NEPALI_MONTHS.map((name, i) => {
    const from = new Date(startMs + i * 30.5 * 24 * 3600 * 1000);
    const to   = new Date(startMs + (i+1) * 30.5 * 24 * 3600 * 1000 - 24 * 3600 * 1000);
    return {
      label:     `${name} ${bsYear + (i >= 9 ? 1 : 0)}`,
      from_date: from.toISOString().slice(0,10),
      to_date:   to.toISOString().slice(0,10),
    };
  });
}

// ── Settings page ─────────────────────────────────────────────
export default function Settings() {
  const { role } = useWorkspace();
  const fy = currentFiscalYear();

  const [fiscalYear,  setFiscalYear]  = useState(fy);
  const [periods,     setPeriods]     = useState([]);
  const [taxRates,    setTaxRates]    = useState([]);
  const [loadingP,    setLoadingP]    = useState(true);
  const [loadingT,    setLoadingT]    = useState(true);
  const [busy,        setBusy]        = useState(false);
  const [err,         setErr]         = useState(null);
  const [msg,         setMsg]         = useState(null);
  const [section,     setSection]     = useState("periods"); // periods | taxrates

  const canEdit = ["owner","accountant"].includes(role);

  const loadPeriods = async () => {
    setLoadingP(true);
    const { data } = await supabase.rpc("list_fiscal_periods", { p_fiscal_year: fiscalYear });
    setPeriods(data || []);
    setLoadingP(false);
  };

  const loadTaxRates = async () => {
    setLoadingT(true);
    const { data } = await supabase.rpc("get_tax_rates");
    setTaxRates(data || []);
    setLoadingT(false);
  };

  useEffect(() => { loadPeriods(); }, [fiscalYear]);
  useEffect(() => { loadTaxRates(); }, []);

  const generatePeriodRows = async () => {
    setBusy(true); setErr(null);
    try {
      const rows = generatePeriods(fiscalYear);
      const { error } = await supabase.rpc("create_fiscal_periods", {
        p_fiscal_year: fiscalYear,
        p_periods: rows,  // pass as array, supabase handles serialization
      });
      if (error) throw error;
      setMsg(`Created ${rows.length} monthly periods for ${fiscalYear}`);
      await loadPeriods();
    } catch(e) { setErr(e.message); }
    setBusy(false);
  };

  const toggleLock = async (period) => {
    setBusy(true); setErr(null);
    try {
      const { error } = await supabase.rpc("set_period_lock", {
        p_period_id: period.id,
        p_locked: !period.is_locked,
      });
      if (error) throw error;
      setMsg(`Period "${period.period_label}" ${!period.is_locked ? "locked 🔒" : "unlocked 🔓"}`);
      await loadPeriods();
    } catch(e) { setErr(e.message); }
    setBusy(false);
  };

  const lockAll = async () => {
    if (!confirm(`Lock ALL unlocked periods in ${fiscalYear}? This prevents any new vouchers in those months.`)) return;
    setBusy(true); setErr(null);
    try {
      for (const p of periods.filter(p => !p.is_locked)) {
        await supabase.rpc("set_period_lock", { p_period_id: p.id, p_locked: true });
      }
      setMsg(`All periods in ${fiscalYear} locked.`);
      await loadPeriods();
    } catch(e) { setErr(e.message); }
    setBusy(false);
  };

  const lockedCount   = periods.filter(p=>p.is_locked).length;
  const unlockedCount = periods.length - lockedCount;

  return (
    <div className="panel">
      <div className="panel-head">
        <h2>Settings (सेटिङ्ग)</h2>
      </div>

      {/* Section tabs */}
      <div className="filter-tabs" style={{marginBottom:20}}>
        {[["periods","🔒 Fiscal Periods"],["taxrates","📊 Tax Rates"]].map(([k,l])=>(
          <button key={k} className={"filter-tab"+(section===k?" active":"")} onClick={()=>setSection(k)}>{l}</button>
        ))}
      </div>

      {err && <p className="msg err">{err}</p>}
      {msg && <p className="msg ok">{msg}</p>}

      {/* ── Fiscal Periods ── */}
      {section === "periods" && (
        <>
          <div style={{display:"flex",gap:12,alignItems:"center",marginBottom:16,flexWrap:"wrap"}}>
            <label className="fld" style={{margin:0,flex:"0 0 160px"}}>
              Fiscal Year
              <input value={fiscalYear} onChange={e=>setFiscalYear(e.target.value)}
                placeholder="e.g. 2081/82" style={{marginTop:4}} />
            </label>
            {canEdit && periods.length === 0 && (
              <button className="btn" style={{marginTop:20}} onClick={generatePeriodRows} disabled={busy}>
                {busy?"Generating…":"Generate 12 Monthly Periods"}
              </button>
            )}
            {canEdit && unlockedCount > 0 && periods.length > 0 && (
              <button className="ghost-btn" style={{marginTop:20,color:"var(--rust)"}}
                onClick={lockAll} disabled={busy}>
                🔒 Lock All Open Periods
              </button>
            )}
          </div>

          {!canEdit && <p className="note">Only owner or accountant can manage period locks.</p>}

          <div className="settings-info-box">
            <b>What period locks do:</b> Once a period is locked, no new vouchers, invoices or bills
            can be posted with a date inside that period. This prevents backdating after VAT filing
            or year-end close. Unlock to make a correction, then re-lock.
          </div>

          {loadingP ? <p className="note">Loading…</p> :
           periods.length === 0 ? (
            <p className="note">No periods set up for {fiscalYear} yet. Click "Generate 12 Monthly Periods" above to create them.</p>
          ) : (
            <>
              <div style={{marginBottom:8,fontSize:13,color:"var(--ink2)"}}>
                {lockedCount} locked · {unlockedCount} open
              </div>
              <table className="tbl">
                <thead>
                  <tr><th>Period</th><th>From</th><th>To</th><th>Status</th><th>Locked At</th>{canEdit&&<th/>}</tr>
                </thead>
                <tbody>
                  {periods.map(p=>(
                    <tr key={p.id}>
                      <td><b>{p.period_label}</b></td>
                      <td style={{fontSize:12}}>{p.from_date}</td>
                      <td style={{fontSize:12}}>{p.to_date}</td>
                      <td>
                        {p.is_locked
                          ? <span className="status-draft" style={{background:"#fef0ee",color:"var(--rust)"}}>🔒 Locked</span>
                          : <span className="status-paid">🔓 Open</span>}
                      </td>
                      <td style={{fontSize:11,color:"var(--ink2)"}}>
                        {p.locked_at ? new Date(p.locked_at).toLocaleDateString() : "—"}
                      </td>
                      {canEdit && (
                        <td>
                          <button className="link" onClick={()=>toggleLock(p)} disabled={busy}>
                            {p.is_locked ? "Unlock" : "Lock"}
                          </button>
                        </td>
                      )}
                    </tr>
                  ))}
                </tbody>
              </table>
            </>
          )}
        </>
      )}

      {/* ── Tax Rates ── */}
      {section === "taxrates" && (
        <>
          <div className="settings-info-box">
            <b>Nepal statutory rates loaded from your database.</b> These are used as defaults
            when creating invoices (VAT) and TDS entries. If IRD changes a rate,
            an accountant or owner can add a new effective-dated row — old entries
            keep their original rate.
          </div>

          {loadingT ? <p className="note">Loading…</p> : (
            <>
              <div className="dash-section-title" style={{marginTop:16}}>VAT Rates</div>
              <table className="tbl" style={{marginBottom:20}}>
                <thead><tr><th>Transaction Type</th><th>Label</th><th className="num">Rate %</th></tr></thead>
                <tbody>
                  {taxRates.filter(r=>r.rate_type==="vat").map(r=>(
                    <tr key={r.transaction_type}>
                      <td><code style={{fontSize:12}}>{r.transaction_type}</code></td>
                      <td>{r.label}</td>
                      <td className="num"><b>{r.rate}%</b></td>
                    </tr>
                  ))}
                </tbody>
              </table>

              <div className="dash-section-title">TDS Rates</div>
              <table className="tbl">
                <thead><tr><th>Transaction Type</th><th>Label</th><th className="num">Rate %</th><th>IRD Reference</th></tr></thead>
                <tbody>
                  {taxRates.filter(r=>r.rate_type==="tds").map(r=>(
                    <tr key={r.transaction_type}>
                      <td><code style={{fontSize:12}}>{r.transaction_type}</code></td>
                      <td>{r.label}</td>
                      <td className="num"><b>{r.rate}%</b></td>
                      <td className="muted" style={{fontSize:11}}>Income Tax Act 2058</td>
                    </tr>
                  ))}
                </tbody>
              </table>

              <p className="note" style={{marginTop:12}}>
                To change a rate (e.g. if IRD updates TDS on rent), contact your accountant
                to add a new effective-dated entry via Supabase. Support for in-app editing
                is coming in a future update.
              </p>
            </>
          )}
        </>
      )}
    </div>
  );
}
