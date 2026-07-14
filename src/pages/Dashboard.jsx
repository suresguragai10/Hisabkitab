import React, { useEffect, useState } from "react";
import { supabase } from "../supabase";

const fmt  = (n) => Number(n||0).toLocaleString(undefined,{minimumFractionDigits:2,maximumFractionDigits:2});
const fmtK = (n) => {
  const v = Number(n||0);
  if (v >= 10000000) return (v/10000000).toFixed(1) + " Cr";
  if (v >= 100000)   return (v/100000).toFixed(1) + " L";
  if (v >= 1000)     return (v/1000).toFixed(1) + "K";
  return v.toLocaleString();
};

async function fetchStats() {
  const { data, error } = await supabase.rpc("get_dashboard_stats");
  if (error) throw error;
  return data;
}

async function fetchRecentActivity() {
  const [invRes, voucherRes] = await Promise.all([
    supabase.from("invoices").select("id,invoice_number,fiscal_year,invoice_date,party_name,total,status")
      .neq("status","cancelled").order("invoice_date",{ascending:false}).limit(5),
    supabase.from("vouchers").select("id,voucher_type,voucher_number,voucher_date,narration")
      .eq("is_void",false).order("voucher_date",{ascending:false}).limit(5),
  ]);
  return {
    invoices: invRes.data || [],
    vouchers: voucherRes.data || [],
  };
}

export default function Dashboard({ refreshKey, onNav }) {
  const [stats, setStats]    = useState(null);
  const [activity, setActivity] = useState(null);
  const [err, setErr]        = useState(null);
  const [loading, setLoading] = useState(true);

  const load = async () => {
    setLoading(true); setErr(null);
    try {
      const { error: refreshError } = await supabase.rpc("refresh_document_payment_statuses");
      if (refreshError) throw refreshError;
      const [s, a] = await Promise.all([fetchStats(), fetchRecentActivity()]);
      setStats(s); setActivity(a);
    } catch(e) { setErr(e.message); }
    setLoading(false);
  };

  useEffect(() => { load(); }, [refreshKey]);

  const salesTrend = stats ? (stats.sales_last > 0
    ? ((stats.sales_this - stats.sales_last) / stats.sales_last * 100).toFixed(0)
    : null) : null;

  const vatDeadline = stats?.vat_deadline
    ? new Date(stats.vat_deadline).toLocaleDateString("en-NP",{day:"numeric",month:"long"})
    : null;

  const daysToVat = stats?.vat_deadline
    ? Math.ceil((new Date(stats.vat_deadline) - new Date()) / 86400000)
    : null;

  return (
    <div className="panel">
      <div className="panel-head">
        <h2>Dashboard (ड्यासबोर्ड)</h2>
        <button className="ghost-btn" onClick={load}>↻ Refresh</button>
      </div>

      {err && <p className="msg err">{err}</p>}

      {loading ? (
        <p className="note">Loading…</p>
      ) : !stats ? null : (
        <>
          {/* ── Row 1: Cash position ── */}
          <div className="dash-section-title">Cash Position</div>
          <div className="dash-cards">
            <DashCard
              label="Cash & Bank"
              value={"NPR " + fmtK(stats.cash)}
              sub="Available balance"
              color="green"
              icon="💰"
            />
            <DashCard
              label="Receivables"
              value={"NPR " + fmtK(stats.receivables)}
              sub="Customers owe you"
              color={stats.receivables > 0 ? "gold" : "neutral"}
              icon="📥"
            />
            <DashCard
              label="Payables"
              value={"NPR " + fmtK(stats.payables)}
              sub="You owe vendors"
              color={stats.payables > 0 ? "rust" : "neutral"}
              icon="📤"
            />
            {stats.overdue_count > 0 && (
              <DashCard
                label="Overdue Invoices"
                value={stats.overdue_count}
                sub={stats.overdue_amount != null ? `NPR ${fmtK(stats.overdue_amount)} past due` : "Past due date"}
                color="rust"
                icon="⚠"
              />
            )}
          </div>

          {/* ── Row 2: Sales & VAT ── */}
          <div className="dash-section-title" style={{marginTop:20}}>Sales & Tax</div>
          <div className="dash-cards">
            <DashCard
              label="Sales This Month"
              value={"NPR " + fmtK(stats.sales_this)}
              sub={salesTrend !== null
                ? (salesTrend >= 0 ? "▲ " : "▼ ") + Math.abs(salesTrend) + "% vs last month"
                : "No sales last month"}
              color={salesTrend >= 0 ? "green" : "rust"}
              icon="📈"
            />
            <DashCard
              label="Sales Last Month"
              value={"NPR " + fmtK(stats.sales_last)}
              sub="Previous month"
              color="neutral"
              icon="📊"
            />
            <DashCard
              label="VAT This Month"
              value={"NPR " + fmtK(stats.vat_payable)}
              sub={daysToVat !== null
                ? (daysToVat > 0 ? `Due in ${daysToVat} days (${vatDeadline})` : `Overdue! Due ${vatDeadline}`)
                : ""}
              color={daysToVat !== null && daysToVat <= 5 ? "rust" : "gold"}
              icon="🧾"
            />
            <DashCard
              label="Stock Value"
              value={"NPR " + fmtK(stats.stock_value)}
              sub={stats.low_stock > 0 ? `⚠ ${stats.low_stock} item(s) low on stock` : "All stock levels OK"}
              color={stats.low_stock > 0 ? "gold" : "neutral"}
              icon="📦"
            />
          </div>

          {/* ── Quick actions ── */}
          <div className="dash-section-title" style={{marginTop:20}}>Quick Actions</div>
          <div className="dash-actions">
            {onNav && <>
              <button className="btn" onClick={()=>onNav("invoices")}>+ New Invoice</button>
              <button className="ghost-btn" onClick={()=>onNav("purchases")}>+ New Purchase</button>
              <button className="ghost-btn" onClick={()=>onNav("vouchers")}>+ New Voucher</button>
              <button className="ghost-btn" onClick={()=>onNav("inventory")}>+ Stock Entry</button>
            </>}
          </div>

          {/* ── Recent activity ── */}
          <div style={{display:"grid",gridTemplateColumns:"1fr 1fr",gap:16,marginTop:20}}>
            {/* Recent invoices */}
            <div>
              <div className="dash-section-title">Recent Invoices</div>
              {!activity?.invoices?.length ? (
                <p className="note">No invoices yet.</p>
              ) : (
                <table className="tbl">
                  <thead><tr><th>Invoice #</th><th>Customer</th><th className="num">Amount</th><th>Status</th></tr></thead>
                  <tbody>
                    {activity.invoices.map(i=>(
                      <tr key={i.id}>
                        <td style={{fontSize:12}}>{i.fiscal_year}-{String(i.invoice_number).padStart(4,"0")}</td>
                        <td style={{maxWidth:100,overflow:"hidden",textOverflow:"ellipsis",whiteSpace:"nowrap"}}>{i.party_name}</td>
                        <td className="num" style={{fontSize:12}}>NPR {Number(i.total).toLocaleString()}</td>
                        <td><span className={"status-"+i.status} style={{fontSize:11}}>{i.status}</span></td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              )}
            </div>

            {/* Recent vouchers */}
            <div>
              <div className="dash-section-title">Recent Vouchers</div>
              {!activity?.vouchers?.length ? (
                <p className="note">No vouchers yet.</p>
              ) : (
                <table className="tbl">
                  <thead><tr><th>Date</th><th>Type</th><th>Narration</th></tr></thead>
                  <tbody>
                    {activity.vouchers.map(v=>(
                      <tr key={v.id}>
                        <td style={{fontSize:12}}>{v.voucher_date}</td>
                        <td style={{fontSize:12}}><span className="tag">{v.voucher_type}</span></td>
                        <td style={{fontSize:12,maxWidth:120,overflow:"hidden",textOverflow:"ellipsis",whiteSpace:"nowrap"}}>{v.narration||"—"}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              )}
            </div>
          </div>
        </>
      )}
    </div>
  );
}

function DashCard({ label, value, sub, color, icon }) {
  const colors = {
    green:   { bg:"#e8f5f0", border:"#1f6f54", text:"#1f6f54" },
    gold:    { bg:"#fdf6e3", border:"#b9892f", text:"#8a6520" },
    rust:    { bg:"#fef0ee", border:"#c0392b", text:"#c0392b" },
    neutral: { bg:"#f5f5f5", border:"#cccccc", text:"#444444" },
  };
  const c = colors[color] || colors.neutral;
  return (
    <div style={{
      background: c.bg, border: `1.5px solid ${c.border}`,
      borderRadius: 10, padding: "14px 16px", flex: "1 1 160px", minWidth: 140,
    }}>
      <div style={{fontSize:20, marginBottom:4}}>{icon}</div>
      <div style={{fontSize:20, fontWeight:700, fontFamily:"Georgia,serif", color:c.text, lineHeight:1.2}}>{value}</div>
      <div style={{fontSize:12, color:"#555", marginTop:4, fontWeight:600}}>{label}</div>
      {sub && <div style={{fontSize:11, color:c.text, marginTop:3, opacity:0.85}}>{sub}</div>}
    </div>
  );
}
