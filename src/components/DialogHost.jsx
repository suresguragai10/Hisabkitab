import React, { useEffect, useState } from "react";
import { subscribeDialog, getDialogState, subscribeToast } from "../lib/dialogs";

function ConfirmBody({ req }) {
  return (
    <>
      <p className="modal-copy">{req.message}</p>
      <div className="modal-actions">
        <button type="button" className="ghost-btn" onClick={() => req.resolve(false)}>Cancel</button>
        <button type="button" className={"btn" + (req.danger ? " danger-btn" : "")} onClick={() => req.resolve(true)}>{req.confirmLabel}</button>
      </div>
    </>
  );
}

function PromptBody({ req }) {
  const [value, setValue] = useState("");
  const tooShort = value.trim().length < req.minLength;
  return (
    <form
      onSubmit={(e) => {
        e.preventDefault();
        if (!tooShort) req.resolve(value.trim());
      }}
    >
      <p className="modal-copy">{req.message}</p>
      <label className="fld">
        <textarea rows={3} autoFocus value={value} onChange={(e) => setValue(e.target.value)} />
      </label>
      <div className="modal-actions">
        <button type="button" className="ghost-btn" onClick={() => req.resolve(null)}>Cancel</button>
        <button className="btn" disabled={tooShort}>{req.confirmLabel}</button>
      </div>
    </form>
  );
}

export default function DialogHost() {
  const [req, setReq] = useState(getDialogState());
  const [toasts, setToasts] = useState([]);

  useEffect(() => subscribeDialog(setReq), []);
  useEffect(
    () =>
      subscribeToast((toast) => {
        setToasts((prev) => [...prev, toast]);
        setTimeout(() => setToasts((prev) => prev.filter((t) => t.id !== toast.id)), 3200);
      }),
    []
  );

  return (
    <>
      {req && (
        <div className="modal-overlay" role="dialog" aria-modal="true" aria-label={req.title}>
          <div className="modal-card" style={{ maxWidth: 400 }}>
            <div className="modal-head">
              <h3>{req.title}</h3>
              <button
                type="button"
                className="link"
                aria-label="Close"
                onClick={() => req.resolve(req.kind === "confirm" ? false : null)}
              >
                ✕
              </button>
            </div>
            {req.kind === "confirm" ? <ConfirmBody req={req} /> : <PromptBody req={req} />}
          </div>
        </div>
      )}
      {toasts.length > 0 && (
        <div className="toast-stack">
          {toasts.map((t) => (
            <div key={t.id} className={`toast toast-${t.type}`}>{t.message}</div>
          ))}
        </div>
      )}
    </>
  );
}
