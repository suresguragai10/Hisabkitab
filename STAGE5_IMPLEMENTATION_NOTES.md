# HisabKitab Stage 5 — Structured Chart of Accounts

Version: **6.4.0**

## Purpose

Stage 5 replaces free-text account grouping with a structured accounting model. It adds stable account codes, hierarchy, report classifications, subtypes, normal balances, protected control accounts, and balanced opening journals. Financial statements no longer decide current/non-current or income/expense sections from account display names.

## Migration order

1. Back up the Supabase database and schema.
2. Run `sql/phaseP0_5_structured_chart_preflight.sql`.
3. Resolve every `missing_*`, `invalid_*`, or `duplicate_*` row. `legacy_opening_balance` rows are informational and may be converted after migration.
4. Run `sql/phaseP0_5_structured_chart.sql` in a new SQL Editor tab.
5. Run `sql/phaseP0_5_structured_chart_verify.sql`.
6. Deploy the complete newly built `dist` directory.
7. Test the account, opening-journal, voucher, dashboard, and report paths below.

## Main database changes

The `accounts` table now includes:

- `account_code`
- `parent_account_id`
- `report_class`
- `account_subtype`
- `normal_balance`
- `cash_flow_category`
- `is_control_account`
- `is_system_account`
- `allow_manual_posting`

Legacy accounts are classified once during migration. Runtime P&L, Balance Sheet, dashboard cash/receivables/payables, bank-account selection, and manual-voucher selection use the structured fields afterward.

Direct authenticated inserts, updates, and deletes on `accounts` are revoked. Account changes use:

- `create_structured_account`
- `update_structured_account`
- `deactivate_structured_account`

System-account resolution and contact creation now populate structured fields automatically.

## Opening balances

New opening balances must use `post_opening_journal`. It:

- requires at least two lines;
- permits only balance-sheet accounts;
- requires one debit or one credit on every line;
- requires total debit to equal total credit;
- permits one opening journal per fiscal year;
- creates a source-linked `opening` voucher.

Existing direct opening-balance fields remain visible only as legacy data. Use `migrate_legacy_opening_balances` from the Chart of Accounts. If legacy debits and credits differ, select a reviewed balance-sheet offset account. The conversion posts the journal first, then zeros the legacy fields to avoid double counting.

Opening stock must continue to be entered item-by-item through the Stage 3 inventory workflow. Do not use a general-ledger opening amount as a substitute for item quantities and valuation.

## Acceptance tests

### Account structure

1. Create a current-asset account with a blank code; confirm a unique code is generated.
2. Create a child account and confirm it appears indented below its parent.
3. Try assigning an account as its own parent; saving must fail.
4. Try creating a liability account with an asset report class; the database constraint must reject it.
5. Confirm system and control accounts display their flags and cannot be edited structurally.

### Change protection

1. Post a journal to a new account.
2. Try changing its account type, report class, or normal balance; saving must fail.
3. Try deactivating the posted account; deactivation must fail.
4. Create an unused custom account and deactivate it; it should become inactive.
5. Confirm direct browser table writes are unavailable and RPC-based actions still work.

### Opening journal

1. Post NPR 10,000 debit to Bank and NPR 10,000 credit to Capital.
2. Confirm the opening voucher exists once and the Trial Balance remains balanced.
3. Try an unbalanced opening journal; posting must fail.
4. Try using an income or expense account; posting must fail.
5. Try a second opening journal for the same fiscal year; posting must fail.
6. If legacy balances exist, convert them and confirm the legacy fields become zero while ledger balances remain unchanged.

### Reports and workflows

1. Rename a custom account; confirm its Balance Sheet or P&L section does not change.
2. Confirm current and non-current sections follow `report_class`, not `group_name`.
3. Confirm manual Voucher Entry excludes accounts marked `allow_manual_posting=false`.
4. Confirm Cash/Bank selection in Bank Reconciliation uses `account_subtype`.
5. Confirm Dashboard cash, receivables, and payables still load.
6. Confirm contact creation succeeds and directs opening amounts to the Opening Journal.
7. Confirm the setup wizard posts a balanced opening journal and rejects aggregate opening stock.

## Known limits

- Stage 5 introduces report classifications but does not complete all Stage 6 report requirements such as Day Book, date-aware opening/closing balances, drill-down, exports, and full ageing.
- Parent accounts are organizational; a separate non-posting-heading model may be added during the UI/report redesign.
- Existing legacy classification is a one-time best-effort mapping and should be reviewed by an accountant before production use.
- Role enforcement and complete RLS review remain Stage 8 work.
