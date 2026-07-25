# Audit Tracker

Tracks every finding from [`PRODUCT_AUDIT.md`](../PRODUCT_AUDIT.md) (the "Independent Product, Accounting & Technology Audit") plus real bugs found while working through it, each against the live code/DB — not against chat memory or the original report's assumptions. This file is the source of truth for "is the audit done"; update it whenever an item's status changes, independent of any one conversation.

Section numbers below match `PRODUCT_AUDIT.md` headings so the two files can be read side by side.

**Legend:** ✅ Done · 🟡 Partial · ❌ Open · ⚪ Not reproduced (audit's claim didn't hold up when checked against the actual code/live DB — repo-vs-live-DB drift was a repeated theme, see the "false positives" note at the bottom)

---

## 1. Critical functional defects

| # | Finding | Status | Evidence |
|---|---|---|---|
| 1.1 | Voucher Entry is not a real entry screen | ⚪ | `src/pages/VoucherEntry.jsx` exports a real form (voucher type, date, lines with account/debit/credit/description) named `VoucherEntry`; `VoucherList.jsx` is a separate, correctly-named component shown alongside it in `App.jsx` by design (entry form + recent list). No `handleReverse` reference found in either file. Audit's specific claims (wrong export name, undefined handler) don't reproduce against current code. |
| 1.2 | Supplied SQL missing tables/RPCs the frontend depends on | ✅ | All 26 flagged tables/RPCs (`bank_statement_lines`, `credit_notes`, `tds_entries`, `accept_invite`, `switch_workspace`, `set_period_lock`, etc.) exist in `sql/*.sql` today. This was real repo-vs-live-DB drift (see [[architecture-layers]] in memory) — the objects existed live in Supabase but weren't captured in git; `phaseP1_*`/`phaseP2_7` migrations backfilled the missing definitions into the repo so a fresh deploy is reproducible. |
| 1.3 | Setup wizard can claim completion when backend is absent; "KitabHisabKitab" typo | ❌ not re-checked | Not verified this pass — revisit `SetupWizard`/onboarding component for the branding typo and whether it still calls anything unbacked. |

## 2. Accounting integrity audit

| # | Finding | Status | Evidence |
|---|---|---|---|
| 2.1 | Inventory/COGS not posted to ledger | ✅ | `sql/phaseP0_3_inventory_cogs.sql` — perpetual inventory, invoice posting debits COGS/credits Inventory Asset per line via `resolve_system_account('cogs')`. Predates this audit cycle. |
| 2.2 | Partial payments marked fully paid | ✅ | `sql/phaseP0_2_payment_allocations.sql` — real `payment_allocations` table (voucher, document, allocated amount, date, reversal), used by `record_document_payment`/`reverse_payment_allocation` (`src/lib/posting.js`). Status is derived from allocations vs. total, not a blind flag flip. |
| 2.3 | "Ageing" report is just a balance list, no buckets | ✅ | `sql/phaseP0_6_trustworthy_reports.sql` — `get_receivables_ageing_report`/`get_payables_ageing_report` compute real per-invoice `age_days` and bucket into `current`/`1_30`/`31_60`/`61_90`/`over_90`. |
| 2.4 | Sales collection figures status-based not balance-based | 🟡 not re-checked this pass | Depends on 2.2's allocation model being what `Reports.jsx`'s Sales Report actually reads from — worth a direct check next time this area is touched. |
| 2.5 | VAT report incomplete (credit/debit notes, exempt/zero-rated, reconciliation) | 🟡 not re-checked this pass | VAT scope was explicitly narrowed this project to "Prepare → Review → Export Annex 13" only (direct e-filing to IRD deliberately removed, per user decision 2026-07-25) — re-verify remaining claims (credit/debit note inclusion, exempt/zero-rated handling) against `prepare_vat_return` before calling this closed. |
| 2.6 | Credit/debit notes detached from accounting engine | ✅ | `create_credit_note`/`create_debit_note`/`cancel_credit_note`/`cancel_debit_note` post real reversing vouchers (`sql/phaseP2_10`, `phaseP2_26`); tables are real, not missing. |
| 2.7 | Balance Sheet grouping hardcoded on display-name strings | ✅ | `accounts` table has structured `report_class`, `account_subtype`, `normal_balance`, `cash_flow_category`, `parent_account_id`, `system_code`, `is_party_account` columns; `get_balance_sheet_report()` groups by these, not by name string. Also see [[ar-ap-architecture-concern]] — the per-party-account rollup on this same report was fixed 2026-07-25 (`phaseP2_30`). |
| 2.8 | Opening balances not a controlled journal | 🟡 not re-checked this pass | `opening_journals` table and `post_opening_journal` exist (`phaseP2_13`) — suggests this was addressed, but debit=credit enforcement and fiscal-year-close carry-forward behavior weren't re-verified this pass. |
| 2.9 | Fiscal period locking incomplete/UI-only | ✅ | `set_period_lock`/`enforce_voucher_period_lock`/`assert_user_posting_period_open` are real, server-side, called from posting functions (confirmed during the "column ambiguous" bug investigation this session — these functions are live and in the real call chain, not UI-only). |

## 3. Navigation and information architecture

| Finding | Status | Notes |
|---|---|---|
| Sidebar exposes too many low-level masters; recommended restructure (Home/Sales/Purchases/Banking/Accounting/Inventory/Reports/Tax/Settings) | ❌ Open | Not attempted this project. Current nav still flat per `App.jsx`. Real UX work, not a bug — do as a deliberate redesign task when picked up, not a quick patch. |

## 4. UI and UX audit

| # | Finding | Status | Evidence |
|---|---|---|---|
| 4.1 | No reusable design system (~360 inline styles) | ❌ Open | Now ~404 `style={{...}}` occurrences across `src/**/*.jsx` — grew, not shrank. Untouched. |
| 4.2 | Emoji icons inconsistent | ❌ Open | Still present (`App.jsx` sidebar). Untouched. |
| 4.3 | Every page is one large panel, weak hierarchy | ❌ Open | Not attempted. |
| 4.4 | Tables not mobile-safe | ❌ Open | Not attempted. |
| 4.5 | Accessibility near-absent (no `aria-*`, `<div>` click targets) | ❌ Open | Not attempted. |
| 4.6 | No routing — Back/refresh/bookmarks broken | ❌ Open | Confirmed: no `react-router` (or any router) in `package.json`. Still local-state-only navigation. |
| 4.7 | Inconsistent `alert`/`prompt`/`confirm` usage | 🟡 Partial | 11 calls remain across `src/pages/*.jsx` + `src/components/*.jsx` today — reduced from whatever the original count was, but not eliminated. Not a priority fix on its own. |
| 4.8 | Bilingual support incomplete | ❌ Open | Not attempted this project. |
| 4.9 | Dashboard needs more decision-value cards | ❌ Open | Not attempted. |

## 5. Security and data-isolation audit

| # | Finding | Status | Evidence |
|---|---|---|---|
| 5.1 | Role restrictions mainly presentation-level, not DB-enforced | ✅ | RBAC implemented 2026-07-25 — real `assert_role()` gate in 47 SECURITY DEFINER functions covering owner/accountant/staff tiers (`phaseP2_22`–`phaseP2_29`). See [[rbac-implementation]] in memory. |
| 5.2 | Security-definer functions need ownership checks per foreign key (accounts, items, contacts, vendors) | 🟡 Partial | Inline ownership checks (`a.user_id = uid`, `and a.is_active`) are common in posting functions (confirmed in vouchers, invoices, bills) — but there's no single reusable `assert_account_access()`-style helper as the audit recommended, and coverage hasn't been exhaustively re-audited across all 47+ write functions since the RBAC pass. Treat as a real, not-fully-closed risk if a new function is added that skips this check. |
| 5.3 | Audit trail (`write_audit_log`) callable/spoofable by clients | ✅ | `sql/phaseP1_7_lock_down_write_audit_log.sql` — `revoke execute ... from public, authenticated, anon`. Only trusted functions can call it now (via `perform`, which uses the function owner's privileges). |
| 5.4 | Audit coverage incomplete (not every write audited) | ✅ mostly | `write_audit_log` calls now span accounts, parties, invoices, bills, credit/debit notes, payments, vouchers, TDS, fiscal periods, inventory, drafts — broad coverage confirmed via grep across `sql/*.sql`. Not verified as 100% exhaustive. |
| 5.5 | Rate-limiting logging is client-callable/pollutable | ❌ not re-checked | Not investigated this pass. |
| 5.6 | Views need explicit security-invoker/definer behavior for tenant isolation | ❌ not re-checked | Not investigated this pass. |

## 6. Engineering quality audit

| Finding | Status | Evidence |
|---|---|---|
| No automated tests | 🟡 Partial | `vitest` is wired up (`npm test` → `vitest run`), but only one test file exists (`src/lib/nepaliCalendar.test.js`, 13 tests, calendar edge cases only). None of the audit's suggested minimum suite (voucher balance, concurrency, partial payment, void/reversal, P&L↔Trial Balance reconciliation, period lock enforcement, tenant isolation, negative stock, credit-note reversal) exist yet. |
| No linting/formatting | ❌ Open | No `.eslintrc*`/`eslint.config*`/Prettier config found in repo root. |
| Large initial bundle (~602 KB) | ❌ not re-checked | Not re-measured this pass. |
| Large central `App.jsx` | ❌ not re-checked | Not re-measured this pass. |
| Stale README | ❌ not re-checked | Not re-checked this pass. |
| Calendar data needs independent verification | 🟡 Partial | Fixed 2026-07-25: silent out-of-range clamping removed (`adToBs` now returns `null` instead of a fake date), `BsDateInput` year/day ranges corrected. BS 2087 row is still explicitly marked "(placeholder)" and unverified — no authoritative source found yet, left honestly labeled rather than guessed. |

---

## Real bugs found *while* working the audit (not in the original report)

These weren't audit findings — they were live, real bugs discovered along the way and already fixed:

- ✅ **Workspace-scoping gap** — ~89 functions + 16 RLS policies scoped data by `auth.uid()` instead of `get_workspace_owner()`, breaking team-member access (dormant for the current solo-owner setup). See [[workspace-scoping-gap]].
- ✅ **"Both" party vendor-lookup gap** — 5 functions posted a customer+vendor party's bill payments to their receivable account instead of payable, causing a real ~NPR 282k data corruption (found via a Dashboard-vs-Invoices mismatch, corrected with a reclassification journal). See [[both-party-vendor-lookup-gap]].
- ✅ **Multi-FK embed crash** — `parties`↔`accounts` ambiguous embed broke the Purchases vendor dropdown; fixed with an explicit FK hint. Other dormant table pairs with the same risk are catalogued in [[multi-fk-embed-gotcha]] for when a new feature touches them.
- ✅ **AR/AP Balance Sheet rollup** — per-party accounts now roll up into single "Accounts Receivable (all customers)"/"Accounts Payable (all vendors)" lines instead of one row per customer/vendor. See [[ar-ap-architecture-concern]].

## Explicitly out of scope / already-decided

- VAT direct e-filing to IRD was **removed by user decision** (2026-07-25) — scope is Prepare → Review → Export Annex 13 only, not a gap.

## A note on the original report's reliability

Several `PRODUCT_AUDIT.md` findings (marked ⚪ above) were **static-review artifacts**: the review appears to have been done against the git repo's `sql/` migration history alone, which had drifted from the live Supabase database (tables/functions built directly in Studio outside of git — see [[architecture-layers]]). Anything the report calls "missing" is worth re-checking against the *live* DB before acting on it, not just the repo. The verified-open items above (navigation, design system, routing, accessibility, linting, tests) are not affected by that caveat — those were checked directly against current code.

## Next steps

Pick up any ❌/🟡 row above as its own task. Suggested order by risk: 5.2 (ownership-check audit) and 5.5/5.6 (unreviewed security items) before UI/UX polish (section 4) or navigation restructure (section 3), since those are cosmetic by comparison. The 6.1 test-suite gap (accounting integrity tests) is worth prioritizing given how many real bugs (both-party gap, workspace scoping) were only caught by manual cross-checking this project — automated tests for "every voucher balances," "period locks block posting," and "tenant A cannot see tenant B" would catch regressions the same way going forward.
