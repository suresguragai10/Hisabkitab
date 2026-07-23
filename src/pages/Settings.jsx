import React, { useEffect, useState } from "react";
import { supabase } from "../supabase";
import { currentFiscalYear } from "../lib/fiscalYear";
import { bsToAd, BS_MONTHS_EN } from "../lib/nepaliCalendar";
import { useWorkspace } from "../lib/workspace";

// ── Nepal fiscal year months (Shrawan start) ─────────────────
// Fiscal year runs Shrawan (BS month index 3) through Ashadh
// (BS month index 2 of the following BS year). Real day-accurate
// AD dates come from nepaliCalendar.js (bsToAd), which is built
// from a verified table of days-per-BS-month — no more 30.5-day
// approximation, which could land a period boundary a day or two
// off the real Nepali month.
function generatePeriods(fiscalYear) {
  // Accept either "2081-82" (the format currentFiscalYear() actually
  // produces) or the older "2081/82" separator, in case one is typed.
  const fyStartYear = parseInt(String(fiscalYear).split(/[-/]/)[0], 10);
  if (!Number.isFinite(fyStartYear)) {
    throw new Error(`Unrecognized fiscal year format: "${fiscalYear}". Expected e.g. "2081-82".`);
  }

  const sequence = [];
  for (let m = 3; m <= 11; m++) sequence.push({ year: fyStartYear, month: m });
  for (let m = 0; m <= 2; m++) sequence.push({ year: fyStartYear + 1, month: m });

  return sequence.map(({ year, month }, i) => {
    // The last entry (Ashadh, month index 2) is followed by Shrawan
    // (month index 3) of the SAME BS year as that Ashadh — i.e.
    // fyStartYear + 1, not + 2. BS month order within one BS year is
    // Baishakh(0)..Chaitra(11), so index 2 -> 3 never crosses a BS
    // year boundary; only Chaitra(11) -> Baishakh(0) does, and that
    // case is already produced naturally by the sequence array above.
    const next = sequence[i + 1] || { year: fyStartYear + 1, month: 3 };
    const from = bsToAd(year, month, 1);
    const nextStart = bsToAd(next.year, next.month, 1);
    if (!from || !nextStart) {
      throw new Error(`Nepali calendar data is not available for BS year ${year}. Check nepaliCalendar.js coverage.`);
    }
    const to = new Date(nextStart);
    to.setDate(to.getDate() - 1);
    return {
      label:     `${BS_MONTHS_EN[month]} ${year}`,
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
    setErr(null);
    let reason = null;

    // Reopening a locked period must always have a reason on record.
    if (period.is_locked) {
      const input = window.prompt(`Reason for reopening "${period.period_label}"? (required)`);
      if (input === null) return; // user cancelled
      reason = input.trim();
      if (!reason) { setErr("A reason is required to reopen a locked period."); return; }
    }

    setBusy(true);
    try {
      const { error } = await supabase.rpc("set_period_lock", {
        p_period_id: period.id,
        p_locked: !period.is_locked,
        p_reason: reason,
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
                placeholder="e.g. 2081-82" style={{marginTop:4}} />
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
            <b>What period locks do:</b> Once a period is locked, nothing dated inside it can be
            created, edited, or deleted — this prevents backdating after VAT filing or year-end
            close, and is enforced by the database itself, not just this screen. Reopening a locked
            period requires a reason, which is permanently recorded along with who reopened it and
            when.
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
