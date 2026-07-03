import React, { useEffect, useState } from "react";
import { listAccounts, listVouchers } from "../lib/db";

export default function Dashboard({ refreshKey }) {
  const [stats, setStats] = useState(null);
  const [err, setErr] = useState(null);

  useEffect(() => {
    Promise.all([listAccounts(), listVouchers(200)])
      .then(([accounts, vouchers]) => {
        const active = vouchers.filter((v) => !v.is_void);
        const cashLike = accounts.filter((a) => a.group_name === "Cash-in-Hand" || a.group_name === "Bank Accounts");
        setStats({
          accountCount: accounts.length,
          voucherCount: active.length,
          voidCount: vouchers.length - active.length,
          cashAccounts: cashLike.length,
          recent: active.slice(0, 5),
        });
      })
      .catch((e) => setErr(e.message));
  }, [refreshKey]);

  return (
    <div className="panel">
      <div className="panel-head"><h2>Dashboard</h2></div>
      {err && <p className="msg err">{err}</p>}
      {!stats ? <p className="note">Loading…</p> : (
        <>
          <div className="stat-row">
            <div className="stat"><span>{stats.accountCount}</span>Accounts</div>
            <div className="stat"><span>{stats.voucherCount}</span>Vouchers recorded</div>
            <div className="stat"><span>{stats.cashAccounts}</span>Cash / bank accounts</div>
            <div className="stat"><span>{stats.voidCount}</span>Voided entries</div>
          </div>
          <h3 className="sub-head">Recent activity</h3>
          {stats.recent.length === 0 ? <p className="note">Nothing recorded yet — start with a voucher or a party.</p> : (
            <table className="tbl">
              <tbody>
                {stats.recent.map((v) => (
                  <tr key={v.id}>
                    <td>{v.voucher_date}</td>
                    <td className="muted">{v.voucher_type} #{v.voucher_number}</td>
                    <td>{v.narration || "—"}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
        </>
      )}
    </div>
  );
}
