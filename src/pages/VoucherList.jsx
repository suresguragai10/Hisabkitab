import React, { useEffect, useState } from "react";
import { listVouchers, voidVoucher } from "../lib/db";

export default function VoucherList({ refreshKey }) {
  const [vouchers, setVouchers] = useState([]);
  const [loading, setLoading] = useState(true);
  const [err, setErr] = useState(null);

  const load = async () => {
    setLoading(true);
    try {
      setVouchers(await listVouchers());
      setErr(null);
    } catch (e) {
      setErr(e.message);
    }
    setLoading(false);
  };

  useEffect(() => { load(); }, [refreshKey]);

  const handleVoid = async (id) => {
    const reason = window.prompt("Reason for voiding this voucher? (kept in the audit trail)");
    if (reason === null) return;
    try {
      await voidVoucher(id, reason || "No reason given");
      await load();
    } catch (e) {
      setErr(e.message);
    }
  };

  return (
    <div className="panel">
      <div className="panel-head"><h2>Recent Vouchers</h2></div>
      {err && <p className="msg err">{err}</p>}
      {loading ? <p className="note">Loading…</p> : (
        vouchers.length === 0 ? <p className="note">No vouchers recorded yet.</p> : (
          <table className="tbl">
            <thead><tr><th>Date</th><th>Type</th><th>#</th><th>Lines</th><th className="num">Amount</th><th>Narration</th><th /></tr></thead>
            <tbody>
              {vouchers.map((v) => {
                const total = v.voucher_lines.reduce((s, l) => s + Number(l.debit), 0);
                return (
                  <tr key={v.id} className={v.is_void ? "voided" : ""}>
                    <td>{v.voucher_date}</td>
                    <td className="muted">{v.voucher_type}</td>
                    <td>{v.voucher_number}</td>
                    <td>{v.voucher_lines.map((l) => l.accounts?.name).join(" / ")}</td>
                    <td className="num">{total.toLocaleString()}</td>
                    <td>{v.narration || "—"}{v.is_void && <span className="tag tag-void">voided: {v.void_reason}</span>}</td>
                    <td>{!v.is_void && <button className="link" onClick={() => handleVoid(v.id)}>Void</button>}</td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        )
      )}
    </div>
  );
}
