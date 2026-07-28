import React from "react";
import { formatMoney } from "../lib/format";

// Shared money display (audit 4.1). Wraps formatMoney() so new code
// doesn't need to hand-write `"NPR " + fmt(x)` string concatenation, and
// so the two common "how should a negative number look" conventions
// already in use across the app (accounting-parenthesis in Reports.jsx,
// "Dr"/"Cr" suffix in Ledger.jsx) are available in one place instead of
// each being a bespoke local wrapper function.
export default function Money({ value, currency = "NPR", negativeStyle, options }) {
  const n = Number(value || 0);
  const prefix = currency ? `${currency} ` : "";

  if (negativeStyle === "parenthesis" && n < 0) {
    return <>{prefix}({formatMoney(Math.abs(n), options)})</>;
  }
  if (negativeStyle === "dr-cr") {
    return <>{prefix}{formatMoney(Math.abs(n), options)} {n >= 0 ? "Dr" : "Cr"}</>;
  }
  return <>{prefix}{formatMoney(n, options)}</>;
}
