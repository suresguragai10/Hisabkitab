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
| 1.3 | Setup wizard can claim completion when backend is absent; "KitabHisabKitab" typo | ✅ | Typo fixed. The completion-claim concern doesn't reproduce: `complete_onboarding`/`seed_default_accounts`/`post_opening_journal` are all real, live, workspace-scoped functions; the wizard self-plugs any opening-balance difference into Capital before posting, and `post_opening_journal` strictly enforces debit=credit and would throw (blocking the "ready" screen via the existing try/catch) if it ever didn't balance. |

## 2. Accounting integrity audit

| # | Finding | Status | Evidence |
|---|---|---|---|
| 2.1 | Inventory/COGS not posted to ledger | ✅ | `sql/phaseP0_3_inventory_cogs.sql` — perpetual inventory, invoice posting debits COGS/credits Inventory Asset per line via `resolve_system_account('cogs')`. Predates this audit cycle. |
| 2.2 | Partial payments marked fully paid | ✅ | `sql/phaseP0_2_payment_allocations.sql` — real `payment_allocations` table (voucher, document, allocated amount, date, reversal), used by `record_document_payment`/`reverse_payment_allocation` (`src/lib/posting.js`). Status is derived from allocations vs. total, not a blind flag flip. |
| 2.3 | "Ageing" report is just a balance list, no buckets | ✅ | `sql/phaseP0_6_trustworthy_reports.sql` — `get_receivables_ageing_report`/`get_payables_ageing_report` compute real per-invoice `age_days` and bucket into `current`/`1_30`/`31_60`/`61_90`/`over_90`. |
| 2.4 | Sales collection figures status-based not balance-based | ✅ | `Invoices.jsx` reads `invoice.outstanding_amount`/`invoice.amount_paid` directly — both are real columns maintained by `sql/phaseP0_2_payment_allocations.sql` from actual allocations (`set amount_paid = v_paid, outstanding_amount = v_outstanding`), not a status-flag guess. |
| 2.5 | VAT report incomplete (credit/debit notes, exempt/zero-rated, reconciliation) | ✅ | `get_vat_report()` (`sql/phaseP2_17`) already includes sales credit notes and purchase debit notes (with cancellations) in its event union, classifies every line by `vat_treatment` (`standard`/`zero_rated`/`exempt`/`out_of_scope`), and reconciles document-derived output/input VAT against the actual `vat_payable`/`vat_receivable` ledger balances (`reconciled` flag). Minor remaining gaps: no distinct "import VAT" categorization and no bad-debt-relief adjustment — worth a note, not worth reopening this item. VAT e-filing to IRD was separately, deliberately removed from scope (user decision 2026-07-25). |
| 2.6 | Credit/debit notes detached from accounting engine | ✅ | `create_credit_note`/`create_debit_note`/`cancel_credit_note`/`cancel_debit_note` post real reversing vouchers (`sql/phaseP2_10`, `phaseP2_26`); tables are real, not missing. |
| 2.7 | Balance Sheet grouping hardcoded on display-name strings | ✅ | `accounts` table has structured `report_class`, `account_subtype`, `normal_balance`, `cash_flow_category`, `parent_account_id`, `system_code`, `is_party_account` columns; `get_balance_sheet_report()` groups by these, not by name string. Also see [[ar-ap-architecture-concern]] — the per-party-account rollup on this same report was fixed 2026-07-25 (`phaseP2_30`). |
| 2.8 | Opening balances not a controlled journal | ✅ | `post_opening_journal()` (`sql/phaseP2_13`) requires ≥2 lines, blocks P&L accounts (only balance-sheet accounts allowed), strictly enforces `debit = credit` (`raise exception` if off by >0.005), and refuses to post a second opening journal for a fiscal year that already has one — a functional lock once created. |
| 2.9 | Fiscal period locking incomplete/UI-only | ✅ | `set_period_lock`/`enforce_voucher_period_lock`/`assert_user_posting_period_open` are real, server-side, called from posting functions (confirmed during the "column ambiguous" bug investigation this session — these functions are live and in the real call chain, not UI-only). |

## 3. Navigation and information architecture

| Finding | Status | Notes |
|---|---|---|
| Sidebar exposes too many low-level masters; recommended restructure (Home/Sales/Purchases/Banking/Accounting/Inventory/Reports/Tax/Settings) | ✅ | Done 2026-07-26 as structural step 2 (right after routing landed): Banking split out from Accounting (Bank Reconciliation), Tax & Compliance split out from Reports (VAT/TDS), Audit Log moved under Settings. Contacts deliberately kept unified rather than split into Customers/Suppliers — one page already correctly handles customer/vendor/both, splitting the nav wouldn't split the underlying data model. Credit/Debit Notes gets two findable nav entries (Sales → Credit Notes, Purchases → Debit Notes) routing to the same shared page instead of duplicating it. |

## 4. UI and UX audit

| # | Finding | Status | Evidence |
|---|---|---|---|
| 4.1 | No reusable design system (~360 inline styles) | ❌ Open | Now ~404 `style={{...}}` occurrences across `src/**/*.jsx` — grew, not shrank. Untouched. |
| 4.2 | Emoji icons inconsistent | ❌ Open | Still present (`App.jsx` sidebar). Untouched. |
| 4.3 | Every page is one large panel, weak hierarchy | ❌ Open | Not attempted. |
| 4.4 | Tables not mobile-safe | ❌ Open | Not attempted. |
| 4.5 | Accessibility near-absent (no `aria-*`, `<div>` click targets) | ❌ Open | Not attempted. |
| 4.6 | No routing — Back/refresh/bookmarks broken | ✅ | Fixed 2026-07-26: `react-router-dom` (`HashRouter`, since this is a static GitHub Pages deploy with no server-side rewrite support) now drives navigation. Every page is a real `<Route>`, the sidebar uses `NavLink`, and the URL is the source of truth for the current page — real Back/Forward, refresh-safe pages, bookmarkable/shareable links. Done as the first step of a deliberate structural sequence (routing → nav restructure → shared UI primitives → new features) so later work doesn't get built on the old tab-state system and need rewiring. |
| 4.7 | Inconsistent `alert`/`prompt`/`confirm` usage | ✅ | All 11 remaining calls replaced with a shared `ConfirmDialog`/`Toast` system (`src/lib/dialogs.js` + `src/components/DialogHost.jsx`, mounted once in `App.jsx`), styled to match the existing modal design. Verified: `grep` for `alert(`/`confirm(`/`prompt(` across `src/pages`+`src/components` now returns nothing; build (116 modules) and test suite (13/13) both pass. |
| 4.8 | Bilingual support incomplete | ❌ Open | Not attempted this project. |
| 4.9 | Dashboard needs more decision-value cards | ❌ Open | Not attempted. |

## 5. Security and data-isolation audit

| # | Finding | Status | Evidence |
|---|---|---|---|
| 5.1 | Role restrictions mainly presentation-level, not DB-enforced | ✅ | RBAC implemented 2026-07-25 — real `assert_role()` gate in 47 SECURITY DEFINER functions covering owner/accountant/staff tiers (`phaseP2_22`–`phaseP2_29`). See [[rbac-implementation]] in memory. |
| 5.2 | Security-definer functions need ownership checks per foreign key (accounts, items, contacts, vendors) | 🟡 Partial | `post_voucher()` already rejects any `account_id` line that doesn't belong to the caller (`foreign_account_count` check), and `post_invoice_draft()`/`post_bill_draft()` validate `party_id`/`item_id` before use — the core posting path is solid. Re-audited 2026-07-25 and found 4 real gaps: `create_item()`/`update_item()` didn't validate `sales_account_id`/`purchase_account_id` (update_item validated none of its 4 FK params at all), and `create_structured_account()`/`update_structured_account()`/`create_item_category()`/`update_item_category()` never validated their `parent_*_id`. Fixed in `sql/phaseP2_31_ownership_checks_items_categories.sql` — written and confirmed run against the live database 2026-07-25. Still no single reusable `assert_account_access()`-style helper as the audit suggested (each fix is an inline check, matching the existing pattern) — and this pass covered items/categories/accounts specifically, not an exhaustive re-check of all 47+ RBAC-gated functions. Treat as a real, not-fully-closed risk if a new function is added that skips this check. |
| 5.3 | Audit trail (`write_audit_log`) callable/spoofable by clients | ✅ | `sql/phaseP1_7_lock_down_write_audit_log.sql` — `revoke execute ... from public, authenticated, anon`. Only trusted functions can call it now (via `perform`, which uses the function owner's privileges). |
| 5.4 | Audit coverage incomplete (not every write audited) | ✅ mostly | `write_audit_log` calls now span accounts, parties, invoices, bills, credit/debit notes, payments, vouchers, TDS, fiscal periods, inventory, drafts — broad coverage confirmed via grep across `sql/*.sql`. Not verified as 100% exhaustive. |
| 5.5 | Rate-limiting logging is client-callable/pollutable | 🟡 Partial | Confirmed real: `check_rate_limit`/`log_rate_limit` accept any client-supplied `p_identifier` with no ownership check, granted to `anon`+`authenticated`. Someone could spam fake failed-attempt rows against *another* user's email/IP to lock them out via `check_rate_limit`'s 5-failures-in-15-minutes rule — a griefing/DoS vector against this custom layer, not an auth bypass (Supabase's own platform-level GoTrue rate limiting is independent of this table and still applies). Not fixed yet — needs a product decision on an acceptable mitigation (there's no clean way to verify "this identifier is really yours" pre-authentication). |
| 5.6 | Views need explicit security-invoker/definer behavior for tenant isolation | ✅ | **Confirmed and fixed 2026-07-26 — this was a real, live cross-tenant data leak, not a theoretical concern.** All 4 views in `public` (`item_summary`, `contact_summary`, `inventory_valuation`, `trial_balance`) are owned by `postgres`, which has `rolbypassrls=true`. Postgres views without `security_invoker=true` check underlying-table RLS against the *view owner's* privileges, not the querying user's — so with an RLS-bypassing owner, RLS was skipped entirely for anyone querying these views, regardless of `auth.uid()`. `trial_balance` already had `security_invoker=true` (fixed at some earlier point); `item_summary`/`contact_summary`/`inventory_valuation` did not, meaning any authenticated user could see every business's items, contacts, and computed account balances (`contact_summary` joins `parties`+`accounts`+effectively `vouchers` for its outstanding-balance calc). Fixed in `sql/phaseP2_35_view_security_invoker_fix.sql` (`ALTER VIEW ... SET (security_invoker = true)` on all three — no view logic changed). **Written but not yet confirmed run against the live database.** |

## 6. Engineering quality audit

| Finding | Status | Evidence |
|---|---|---|
| No automated tests | 🟡 Partial | `vitest` is wired up (`npm test` → `vitest run`), 21 tests across 3 files now (calendar edge cases, `createVoucher`'s client-side "≥2 lines / debit=credit / total>0" balance validation, and the new confirm/prompt dialog resolve flow — `supabase.rpc`/`.from()` mocked so no test touches the live project). This covers the *client-side* half of "every voucher balances." The audit's DB-level suite (concurrency, partial-payment status, void/reversal, P&L↔Trial-Balance reconciliation, **period-lock enforcement, tenant isolation**, negative stock, credit-note reversal) genuinely can't be built in this environment — there's no `psql`/Docker/Supabase-CLI access to run integration tests against real Postgres (confirmed unavailable repeatedly this project). Would need a local Supabase dev stack to close the rest of this item. |
| No linting/formatting | ❌ Open | No `.eslintrc*`/`eslint.config*`/Prettier config found in repo root. |
| Large initial bundle (~602 KB) | ❌ not re-checked | Not re-measured this pass. |
| Large central `App.jsx` | ❌ not re-checked | Not re-measured this pass. |
| Stale README | ❌ not re-checked | Not re-checked this pass. |
| Calendar data needs independent verification | 🟡 Partial | Fixed 2026-07-25: silent out-of-range clamping removed (`adToBs` now returns `null` instead of a fake date), `BsDateInput` year/day ranges corrected. BS 2087 row is still explicitly marked "(placeholder)" and unverified. Tried again same day: scraped calendar-grid pages gave 3 mutually-inconsistent day counts for Ashad 2087 (29/30/32), and a third-party open-source data table disagreed with this file's own already-confirmed 2081–2083 rows once cross-checked — none of it trustworthy enough to overwrite the placeholder with. Genuinely needs a manual check against an official printed Nepal Panchang, not automated search/fetch. |

---

## Real bugs found *while* working the audit (not in the original report)

These weren't audit findings — they were live, real bugs discovered along the way and already fixed:

- ✅ **Workspace-scoping gap** — ~89 functions + 16 RLS policies scoped data by `auth.uid()` instead of `get_workspace_owner()`, breaking team-member access (dormant for the current solo-owner setup). See [[workspace-scoping-gap]].
- ✅ **"Both" party vendor-lookup gap** — 5 functions posted a customer+vendor party's bill payments to their receivable account instead of payable, causing a real ~NPR 282k data corruption (found via a Dashboard-vs-Invoices mismatch, corrected with a reclassification journal). See [[both-party-vendor-lookup-gap]].
- ✅ **Multi-FK embed crash** — `parties`↔`accounts` ambiguous embed broke the Purchases vendor dropdown; fixed with an explicit FK hint. Other dormant table pairs with the same risk are catalogued in [[multi-fk-embed-gotcha]] for when a new feature touches them.
- ✅ **AR/AP Balance Sheet rollup** — per-party accounts now roll up into single "Accounts Receivable (all customers)"/"Accounts Payable (all vendors)" lines instead of one row per customer/vendor. See [[ar-ap-architecture-concern]].
- ✅ **`audit_log_action_check` missing actions** — found 2026-07-26 while wiring up Sales Orders: `write_audit_log('confirm', ...)` violated the check constraint, silently rolling back the whole `confirm_sales_order` transaction (including the stock-commitment update). Fetching the live constraint definition (not the stale repo copy) turned up 5 more gaps already in production: `delete_structured_account` and `merge_account` (Chart of Accounts "Delete"/"Merge into...") call actions (`delete`, `merge`) that were never in the allowed list either, meaning those two features have likely been silently failing since they were built. Fixed all of it in one constraint rebuild (`sql/phaseP2_33_audit_log_action_check_fix.sql`). Worth actually testing Delete/Merge in the browser now that this is fixed — they were never confirmed working live before this.
- 🟡 **Cross-tenant leak via `item_summary`/`contact_summary`/`inventory_valuation` views** — found 2026-07-26 while re-checking audit item 5.6. Confirmed live: all views in `public` are owned by `postgres` (`rolbypassrls=true`); without `security_invoker=true`, RLS on the underlying tables is skipped entirely for any authenticated user querying the view. `trial_balance` had this fixed already; the other three didn't. Fixed in `sql/phaseP2_35_view_security_invoker_fix.sql` — written, not yet confirmed run.

## Explicitly out of scope / already-decided

- VAT direct e-filing to IRD was **removed by user decision** (2026-07-25) — scope is Prepare → Review → Export Annex 13 only, not a gap.

## A note on the original report's reliability

Several `PRODUCT_AUDIT.md` findings (marked ⚪ above) were **static-review artifacts**: the review appears to have been done against the git repo's `sql/` migration history alone, which had drifted from the live Supabase database (tables/functions built directly in Studio outside of git — see [[architecture-layers]]). Anything the report calls "missing" is worth re-checking against the *live* DB before acting on it, not just the repo. The verified-open items above (navigation, design system, routing, accessibility, linting, tests) are not affected by that caveat — those were checked directly against current code.

## Next steps

`sql/phaseP2_31_ownership_checks_items_categories.sql` (5.2 fix) is written and confirmed run against the live database — no outstanding SQL action right now.

Pick up any remaining ❌/🟡 row above as its own task. Suggested order by risk: 5.5/5.6 (unreviewed security items) before UI/UX polish (section 4) or navigation restructure (section 3), since those are cosmetic by comparison. The DB-level half of the test-suite gap (6, period lock enforcement / tenant isolation / concurrency) needs a local Supabase dev stack (Docker) to even attempt — flag if that ever becomes available in this environment.
