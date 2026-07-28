import React from "react";

// Shared status label (audit 4.1). Reuses the existing .status-* CSS
// classes already defined in App.jsx's stylesheet and used across 11
// pages -- this does NOT introduce a new/competing badge system, it
// just centralizes the "capitalize the label" step that today is
// either hand-written per call site or skipped (some pages show the
// raw lowercase status string as-is).
export default function StatusBadge({ status, label }) {
  if (!status) return null;
  const text = label || (status.charAt(0).toUpperCase() + status.slice(1));
  return <span className={`status-${status}`}>{text}</span>;
}
