import React, { useEffect, useState } from "react";
import {
  getPaymentHistory,
  recordDocumentPayment,
  reversePaymentAllocation,
} from "../lib/posting";

const fmt = (n) => Number(n || 0).toLocaleString(undefined, {
  minimumFractionDigits: 2,
  maximumFractionDigits: 2,
});

// Payment modal shared by invoices and purchase bills.
// The database remains authoritative for allocation totals and overpayment checks.
export default function PaymentModal({ docType, doc, onClose, onSaved }) {
  const [amount, setAmount] = useState("");
  const [date, setDate] = useState(new Date().toISOString().slice(0, 10));
  const [mode, setMode] = useState("bank");
  const [reference, setReference] = useState("");
  const [notes, setNotes] = useState("");
  const [history, setHistory] = useState([]);
  const [loadingHistory, setLoadingHistory] = useState(true);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState(null);
  const [reverseId, setReverseId] = useState(null);
  const [reverseReason, setReverseReason] = useState("");
  const [reverseDate, setReverseDate] = useState(new Date().toISOString().slice(0, 10));

  const docNum = docType === "invoice" ? doc.invoice_number : doc.bill_number;
  const partyName = docType === "invoice" ? doc.party_name : doc.vendor_name;
  const total = Number(doc.total) || 0;
  const paid = Number(doc.amount_paid) || 0;
  const balance = Number(doc.outstanding_amount ?? (total - paid)) || 0;
  const actionLabel = docType === "invoice" ? "Receipt" : "Payment";

  const loadHistory = async () => {
    setLoadingHistory(true);
    try {
      setHistory(await getPaymentHistory(docType, doc.id));
    } catch (e) {
      setErr(e.message);
    } finally {
      setLoadingHistory(false);
    }
  };

  useEffect(() => {
    setAmount(balance > 0.005 ? String(balance) : "");
    loadHistory();
  }, [doc.id, docType]);

  const submit = async () => {
    const amt = Number(amount);
    if (!Number.isFinite(amt) || amt <= 0) {
      setErr("Enter a valid amount.");
      return;
    }
    if (amt > balance + 0.005) {
      setErr(`Amount cannot exceed the outstanding balance of NPR ${fmt(balance)}.`);
      return;
    }

    setBusy(true);
    setErr(null);
    try {
      await recordDocumentPayment(
        docType, doc.id, amt, mode, date, reference.trim() || null, notes.trim() || null
      );
      onSaved();
    } catch (e) {
      setErr(e.message);
    } finally {
      setBusy(false);
    }
  };

  const reverse = async (allocationId) => {
    if (reverseReason.trim().length < 3) {
      setErr("Enter a reversal reason of at least 3 characters.");
      return;
    }
    setBusy(true);
    setErr(null);
    try {
      await reversePaymentAllocation(allocationId, reverseReason.trim(), reverseDate);
      onSaved();
    } catch (e) {
      setErr(e.message);
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="modal-overlay" onClick={onClose}>
      <div className="modal-card" onClick={(e) => e.stopPropagation()}>
        <div className="modal-head">
          <h3>Record {actionLabel} — {docType === "invoice" ? "Invoice" : "Bill"} #{docNum}</h3>
          <button className="link" aria-label="Close payment dialog" onClick={onClose}>✕</button>
        </div>

        <div className="pay-summary">
          <div className="pay-summary-row"><span>{partyName}</span></div>
          <div className="pay-summary-row"><span>Total</span><span>NPR {fmt(total)}</span></div>
          <div className="pay-summary-row"><span>Allocated</span><span>NPR {fmt(paid)}</span></div>
          <div className="pay-summary-row pay-balance"><span>Balance due</span><span>NPR {fmt(balance)}</span></div>
        </div>

        {balance <= 0.005 ? (
          <p className="msg ok">✓ This {docType} is fully paid.</p>
        ) : (
          <>
            <div className="pay-form-grid">
              <label className="fld">
                Amount to allocate
                <input type="number" min="0.01" step="0.01" value={amount} onChange={(e) => setAmount(e.target.value)} />
              </label>
              <label className="fld">
                Date
                <input type="date" value={date} onChange={(e) => setDate(e.target.value)} />
              </label>
              <label className="fld">
                {docType === "invoice" ? "Received via" : "Paid via"}
                <select value={mode} onChange={(e) => setMode(e.target.value)}>
                  <option value="bank">Bank</option>
                  <option value="cash">Cash</option>
                </select>
              </label>
              <label className="fld">
                Reference
                <input placeholder="Cheque, transfer, or receipt reference" value={reference} onChange={(e) => setReference(e.target.value)} />
              </label>
              <label className="fld wide-field">
                Notes
                <input placeholder="Optional internal note" value={notes} onChange={(e) => setNotes(e.target.value)} />
              </label>
            </div>

            <div style={{ display: "flex", gap: 8, marginTop: 4, marginBottom: 12, flexWrap: "wrap" }}>
              <button className="ghost-btn" style={{ fontSize: 12 }} onClick={() => setAmount(String(balance))}>
                Allocate in full (NPR {fmt(balance)})
              </button>
              <button className="ghost-btn" style={{ fontSize: 12 }} onClick={() => setAmount(String(Math.round(balance / 2 * 100) / 100))}>
                Allocate half (NPR {fmt(balance / 2)})
              </button>
            </div>

            <button className="btn" onClick={submit} disabled={busy}>
              {busy ? "Recording…" : `Record ${actionLabel} & Post to Ledger`}
            </button>
          </>
        )}

        {err && <p className="msg err" style={{ marginTop: 12 }}>{err}</p>}

        <div style={{ marginTop: 20 }}>
          <div className="dash-section-title">Payment History</div>
          {loadingHistory ? (
            <p className="note">Loading payment history…</p>
          ) : history.length === 0 ? (
            <p className="note">No payments recorded for this document.</p>
          ) : (
            <table className="tbl">
              <thead><tr><th>Date</th><th>Amount</th><th>Mode</th><th>Status</th><th /></tr></thead>
              <tbody>
                {history.map((h) => {
                  const reversed = Boolean(h.reversed_at);
                  return (
                    <React.Fragment key={h.id}>
                      <tr>
                        <td style={{ fontSize: 12 }}>{h.payment_date}</td>
                        <td className="num">NPR {fmt(h.amount)}</td>
                        <td style={{ fontSize: 12, textTransform: "capitalize" }}>{h.deposit_code}</td>
                        <td>
                          <span className={reversed ? "status-cancelled" : (h.is_legacy ? "status-partial" : "status-paid")}>
                            {reversed ? "reversed" : (h.is_legacy ? "legacy - verify" : "posted")}
                          </span>
                        </td>
                        <td>
                          {!reversed && h.voucher_id && (
                            <button className="link" onClick={() => {
                              setReverseId(reverseId === h.id ? null : h.id);
                              setReverseReason("");
                              setErr(null);
                            }}>
                              Reverse
                            </button>
                          )}
                        </td>
                      </tr>
                      {reverseId === h.id && !reversed && (
                        <tr>
                          <td colSpan={5}>
                            <div className="payment-reversal-box">
                              <label className="fld">
                                Reversal date
                                <input type="date" value={reverseDate} onChange={(e) => setReverseDate(e.target.value)} />
                              </label>
                              <label className="fld wide-field">
                                Reason
                                <input autoFocus placeholder="Required reason" value={reverseReason} onChange={(e) => setReverseReason(e.target.value)} />
                              </label>
                              <div className="modal-actions">
                                <button className="ghost-btn" onClick={() => setReverseId(null)}>Keep Payment</button>
                                <button className="btn danger-btn" disabled={busy} onClick={() => reverse(h.id)}>
                                  {busy ? "Reversing…" : "Post Reversal"}
                                </button>
                              </div>
                            </div>
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
      </div>
    </div>
  );
}
