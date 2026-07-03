// ============================================================
// Nepali fiscal year helper.
//
// IMPORTANT: The real Nepali fiscal year runs Shrawan 1 to Ashad-end
// on the Bikram Sambat (BS) calendar, and the exact BS/AD mapping
// shifts by a day or two each year (it is NOT a fixed AD date).
// A fully accurate version needs a proper BS calendar library/lookup
// table — that's planned as part of Phase 8 (Nepali localization).
//
// For now, this uses a fixed approximation (new FY starts July 17,
// close to the real Shrawan 1) so vouchers can be grouped by fiscal
// year today. Labels look like "2026-27". Swap this out for real BS
// conversion later without changing any other Phase 6b code, since
// everything else just calls fiscalYearFor(date).
// ============================================================

const FY_START_MONTH = 7;  // July
const FY_START_DAY = 17;   // approximate Shrawan 1

export function fiscalYearFor(date = new Date()) {
  const d = new Date(date);
  const y = d.getFullYear();
  const isBeforeCutover =
    d.getMonth() + 1 < FY_START_MONTH ||
    (d.getMonth() + 1 === FY_START_MONTH && d.getDate() < FY_START_DAY);
  const startYear = isBeforeCutover ? y - 1 : y;
  const endYearShort = String((startYear + 1) % 100).padStart(2, "0");
  return `${startYear}-${endYearShort}`;
}

export function currentFiscalYear() {
  return fiscalYearFor(new Date());
}
