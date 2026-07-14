// ============================================================
// Nepali fiscal year helper — Phase 8 upgrade.
// Now uses the real BS calendar (nepaliCalendar.js) instead of
// the July-17 approximation from Phase 6b.
// ============================================================

import { bsFiscalYearFor } from "./nepaliCalendar";

export function fiscalYearFor(date = new Date()) {
  return bsFiscalYearFor(date);
}

export function currentFiscalYear() {
  return bsFiscalYearFor(new Date());
}
