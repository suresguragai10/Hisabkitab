// Shared number/money formatter (audit 4.1) -- consolidates what used to
// be ~15 near-identical local `fmt`/`money` helpers scattered across
// pages, each subtly different (locale, forced decimal places). Every
// call site that adopts this passes the options that reproduce its own
// previous output exactly, so adopting it is a code consolidation, not
// a visible change -- the underlying inconsistency between pages (some
// show Nepali/Indian digit grouping "1,00,000", others plain "100,000")
// still exists and is a separate, deliberate follow-up decision, not
// fixed silently here.
export function formatMoney(value, options = {}) {
  const { locale, minimumFractionDigits = 2, maximumFractionDigits = 2 } = options;
  return Number(value || 0).toLocaleString(locale, { minimumFractionDigits, maximumFractionDigits });
}
