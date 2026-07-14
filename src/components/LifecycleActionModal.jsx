import React, { useState } from "react";

export default function LifecycleActionModal({ title, description, actionLabel = "Confirm", onConfirm, onClose }) {
  const [reason, setReason] = useState("");
  const [date, setDate] = useState(new Date().toISOString().slice(0, 10));
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);

  const submit = async (event) => {
    event.preventDefault();
    if (reason.trim().length < 3) {
      setError("Enter a reason of at least 3 characters.");
      return;
    }
    setBusy(true);
    setError(null);
    try {
      await onConfirm(reason.trim(), date);
      onClose();
    } catch (err) {
      setError(err.message || "The action could not be completed.");
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="modal-overlay" role="dialog" aria-modal="true" aria-label={title}>
      <form className="modal-card" onSubmit={submit}>
        <div className="modal-head">
          <h3>{title}</h3>
          <button type="button" className="link" onClick={onClose} aria-label="Close">✕</button>
        </div>
        {description && <p className="modal-copy">{description}</p>}
        <label className="fld">
          Effective date
          <input type="date" value={date} onChange={(e) => setDate(e.target.value)} required />
        </label>
        <label className="fld" style={{ marginTop: 10 }}>
          Reason
          <textarea
            rows={4}
            value={reason}
            onChange={(e) => setReason(e.target.value)}
            placeholder="Explain why this document is being reversed."
            required
          />
        </label>
        {error && <p className="msg err">{error}</p>}
        <div className="modal-actions">
          <button type="button" className="ghost-btn" onClick={onClose} disabled={busy}>Keep Document</button>
          <button className="btn" disabled={busy || reason.trim().length < 3}>
            {busy ? "Processing…" : actionLabel}
          </button>
        </div>
      </form>
    </div>
  );
}
