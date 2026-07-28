import React from "react";

// Shared modal shell (audit 4.1) -- the .modal-overlay > .modal-card >
// .modal-head + content structure was hand-rolled independently in
// DialogHost, LifecycleActionModal, DocumentActivityModal, and
// PaymentModal, all with the identical CSS but slightly different JSX.
// This extracts just the shell; each caller keeps its own body/footer
// content and state -- this is not meant to replace what's inside a
// modal, only the wrapper around it.
//
// `as="form"` + `onSubmit` supports LifecycleActionModal's case, where
// the modal-card element itself needs to be a <form> so Enter-to-submit
// and the submit button's native validation keep working.
export default function Modal({
  title,
  subtitle,
  onClose,
  closeOnBackdrop = false,
  maxWidth,
  as: CardTag = "div",
  onSubmit,
  children,
}) {
  return (
    <div
      className="modal-overlay"
      role="dialog"
      aria-modal="true"
      aria-label={title}
      onClick={closeOnBackdrop ? onClose : undefined}
    >
      <CardTag
        className="modal-card"
        style={maxWidth ? { maxWidth } : undefined}
        onClick={closeOnBackdrop ? (event) => event.stopPropagation() : undefined}
        onSubmit={onSubmit}
      >
        <div className="modal-head">
          <div>
            <h3>{title}</h3>
            {subtitle && <div className="muted" style={{ fontSize: 12 }}>{subtitle}</div>}
          </div>
          {onClose && (
            <button type="button" className="link" onClick={onClose} aria-label="Close">✕</button>
          )}
        </div>
        {children}
      </CardTag>
    </div>
  );
}
