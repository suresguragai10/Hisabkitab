import React, { useEffect, useState } from "react";
import { listVouchers, voidVoucher } from "../lib/db";

const money = new Intl.NumberFormat("en-NP", {
  minimumFractionDigits: 2,
  maximumFractionDigits: 2,
});

const TYPE_LABELS = {
  journal: "Journal",
  payment: "Payment",
  receipt: "Receipt",
  contra: "Contra",
  sales: "Sales",
  purchase: "Purchase",
};

export default function VoucherList({ refreshKey }) {
  const [vouchers, setVouchers] = useState([]);
  const [loading, setLoading] = useState(true);
  const [err, setErr] = useState(null);
  const [voidTarget, setVoidTarget] = useState(null);
  const [voidReason, setVoidReason] = useState("");
  const [voiding, setVoiding] = useState(false);

  const load = async () => {
    setLoading(true);
    try {
      setVouchers(await listVouchers());
      setErr(null);
    } catch (error) {
      setErr(error.message);
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => { load(); }, [refreshKey]);

  const openVoidDialog = (voucher) => {
    setVoidTarget(voucher);
    setVoidReason("");
    setErr(null);
  };

  const closeVoidDialog = () => {
    if (voiding) return;
    setVoidTarget(null);
    setVoidReason("");
  };

  const confirmVoid = async () => {
    if (!voidTarget) return;
    if (!voidReason.trim()) {
      setErr("Enter a reason before voiding the voucher.");
      return;
    }

    setVoiding(true);
    try {
      await voidVoucher(voidTarget.id, voidReason.trim());
      setVoidTarget(null);
      setVoidReason("");
      await load();
    } catch (error) {
      setErr(error.message);
    } finally {
      setVoiding(false);
    }
  };

  return (
    <section className="panel">
      <div className="panel-head">
        <div>
          <h2>Recent Vouchers</h2>
          <p className="voucher-help">The ledger history is permanent. Voiding keeps the original transaction in the audit trail.</p>
        </div>
        <button className="ghost-btn" type="button" onClick={load} disabled={loading}>Refresh</button>
      </div>

      {err && <p className="msg err" role="alert">{err}</p>}
      {loading ? (
        <p className="note">Loading…</p>
      ) : vouchers.length === 0 ? (
        <div className="empty-state">
          <strong>No vouchers recorded yet</strong>
          <span>Create a balanced journal, payment, receipt or contra voucher above.</span>
        </div>
      ) : (
        <div className="table-scroll">
          <table className="tbl voucher-list-table">
            <thead>
              <tr>
                <th>Date</th>
                <th>Voucher</th>
                <th>Accounts</th>
                <th className="num">Amount</th>
                <th>Narration</th>
                <th aria-label="Actions" />
              </tr>
            </thead>
            <tbody>
              {vouchers.map((voucher) => {
                const total = voucher.voucher_lines.reduce((sum, line) => sum + Number(line.debit), 0);
                const isDocumentVoucher = ["sales", "purchase"].includes(voucher.voucher_type);
                return (
                  <tr key={voucher.id} className={voucher.is_void ? "voided" : ""}>
                    <td>{voucher.voucher_date}</td>
                    <td>
                      <span className={`voucher-type voucher-type-${voucher.voucher_type}`}>
                        {TYPE_LABELS[voucher.voucher_type] || voucher.voucher_type}
                      </span>
                      <div className="voucher-number">#{voucher.voucher_number}</div>
                    </td>
                    <td>
                      <div className="voucher-account-list">
                        {voucher.voucher_lines.map((line) => line.accounts?.name).filter(Boolean).join(" / ") || "—"}
                      </div>
                    </td>
                    <td className="num">NPR {money.format(total)}</td>
                    <td>
                      {voucher.narration || "—"}
                      {voucher.is_void && <span className="tag tag-void">Voided: {voucher.void_reason}</span>}
                    </td>
                    <td className="voucher-list-actions">
                      {!voucher.is_void && !isDocumentVoucher && (
                        <button className="link danger-link" type="button" onClick={() => openVoidDialog(voucher)}>Void</button>
                      )}
                      {!voucher.is_void && isDocumentVoucher && (
                        <span className="managed-label" title="Sales and purchase vouchers must be changed from their source document.">Source document</span>
                      )}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}

      {voidTarget && (
        <div className="modal-overlay" role="presentation" onMouseDown={(event) => {
          if (event.target === event.currentTarget) closeVoidDialog();
        }}>
          <div className="modal-card" role="dialog" aria-modal="true" aria-labelledby="void-voucher-title">
            <div className="modal-head">
              <h3 id="void-voucher-title">Void {TYPE_LABELS[voidTarget.voucher_type] || "Voucher"} #{voidTarget.voucher_number}</h3>
              <button className="icon-btn" type="button" onClick={closeVoidDialog} disabled={voiding} aria-label="Close">×</button>
            </div>
            <p className="muted modal-copy">
              This voucher will remain visible as voided. Reports and ledgers will exclude it.
            </p>
            <label className="fld">
              Reason for voiding
              <textarea
                value={voidReason}
                onChange={(event) => setVoidReason(event.target.value)}
                placeholder="Example: Duplicate entry posted by mistake"
                rows="4"
                maxLength="500"
                autoFocus
              />
            </label>
            <div className="modal-actions">
              <button className="ghost-btn" type="button" onClick={closeVoidDialog} disabled={voiding}>Cancel</button>
              <button className="btn danger-btn" type="button" onClick={confirmVoid} disabled={voiding || !voidReason.trim()}>
                {voiding ? "Voiding…" : "Void Voucher"}
              </button>
            </div>
          </div>
        </div>
      )}
    </section>
  );
}
