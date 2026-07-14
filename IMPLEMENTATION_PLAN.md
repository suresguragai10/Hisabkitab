# HisabKitab Improvement Implementation Plan

This plan converts the product audit into small releases. Each stage should be completed, tested, and deployed before the next stage begins.

## Stage 0 — Protect the current product

1. Create a database backup and export the existing Supabase schema.
2. Create separate development, staging, and production projects.
3. Put every SQL change in a numbered migration file.
4. Add a release checklist and test user for each role.
5. Hide incomplete modules in production until their database migrations exist.

**Exit condition:** a failed change can be rolled back without losing accounting data.

## Stage 1 — Restore manual vouchers

Status: **started in this revision**

1. Replace the duplicate Voucher Entry page with a real double-entry form.
2. Support Journal, Payment, Receipt, and Contra vouchers.
3. Require at least two valid lines.
4. Prevent debit and credit from being entered on the same line.
5. Require total debit to equal total credit.
6. Post the voucher header and lines atomically in PostgreSQL.
7. Verify that every selected account belongs to the signed-in business.
8. Serialize voucher numbering to reduce duplicate numbers during simultaneous posting.
9. Remove the broken Reverse button.
10. Replace the browser prompt for voiding with an application dialog.
11. Prevent sales and purchase vouchers from being voided directly from the general voucher list.

**Files changed:**

- `src/pages/VoucherEntry.jsx`
- `src/pages/VoucherList.jsx`
- `src/lib/db.js`
- `src/App.jsx`
- `sql/phaseP0_1_manual_vouchers.sql`

**Manual test:**

1. Apply `phaseP0_1_manual_vouchers.sql` in the staging Supabase project.
2. Open Accounting → Vouchers.
3. Create a journal with one debit and one credit.
4. Confirm the new voucher appears once in Recent Vouchers.
5. Confirm it appears in both account ledgers.
6. Try an unbalanced voucher and confirm it cannot be saved.
7. Void the test voucher with a reason and confirm reports exclude it.

## Stage 2 — Make payments accurate

1. Add `document_payments` and `payment_allocations` tables.
2. Store every receipt and payment separately.
3. Calculate paid amount and outstanding amount from allocations.
4. Add Open, Partially Paid, Paid, Overdue, Cancelled, and Credited statuses.
5. Stop the current settlement function from marking a partly paid document as fully paid.
6. Add payment history to invoice and purchase detail screens.
7. Add safe reversal of a payment allocation.

**Exit condition:** paying NPR 1 against an NPR 100 invoice leaves NPR 99 outstanding.

## Stage 3 — Correct inventory accounting

1. Choose and document the inventory method: perpetual inventory is recommended.
2. Add Inventory Asset, Cost of Goods Sold, Stock Adjustment, and Purchase Return accounts.
3. Store cost layers or a documented weighted-average cost.
4. On sale: debit Cost of Goods Sold and credit Inventory Asset.
5. On purchase: debit Inventory Asset rather than Purchase Expense for stock items.
6. Handle sales returns, purchase returns, damaged stock, and opening stock.
7. Reconcile stock valuation to the Inventory Asset ledger.

**Exit condition:** stock valuation equals the related general-ledger balance.

## Stage 4 — Rebuild document lifecycle

1. Separate Draft, Posted, Cancelled, and Credited documents.
2. Prohibit editing a posted financial document directly.
3. Add controlled cancellation and reversal transactions.
4. Link each generated voucher to its source document.
5. Add immutable document numbering per fiscal year.
6. Add credit notes and debit notes with complete ledger posting.
7. Add document attachments and internal notes.

## Stage 5 — Structured Chart of Accounts

1. Add account code, parent account, report class, account subtype, and normal balance.
2. Mark system accounts and control accounts.
3. Stop classifying reports by account-name text.
4. Add validation before deleting, deactivating, or changing account type.
5. Post opening balances through a balanced opening journal.

## Stage 6 — Trustworthy reports

Status: **implemented in v6.5.0; staging acceptance pending**

Implemented and reconciled in this order:

1. General Ledger
2. Day Book
3. Trial Balance
4. Profit & Loss
5. Balance Sheet
6. Cash Flow
7. Receivables Ageing
8. Payables Ageing
9. Sales Register
10. Purchase Register
11. VAT Report
12. Stock Valuation

Every report should support date range, fiscal year, export, drill-down, and totals that reconcile to the ledger.

## Stage 7 — Tax and fiscal controls

1. Complete VAT treatment for returns, notes, exempt sales, and zero-rated sales.
2. Add TDS entries, certificates, remittances, and reconciliation.
3. Add fiscal periods and server-enforced period locks.
4. Add year-end closing and opening carry-forward.
5. Add Nepal-specific print and export formats only after accounting results reconcile.

## Stage 8 — Security and audit integrity

1. Enforce permissions in PostgreSQL, not only in React navigation.
2. Validate workspace ownership in every security-definer function.
3. Generate audit entries from trusted triggers and posting functions.
4. Remove direct client access to manufacture audit events.
5. Test owner, accountant, staff, and viewer permissions separately.
6. Review RLS for every table.

## Stage 9 — Professional navigation and UI system

1. Reorganize navigation into Sales, Purchases, Banking, Accounting, Inventory, Reports, Tax, and Settings.
2. Add URL routing and browser history.
3. Extract shared Page Header, Button, Form Field, Table, Badge, Modal, Empty State, and Toast components.
4. Move inline styles into a design system.
5. Use one SVG icon library.
6. Improve responsive tables and mobile forms.
7. Finish English/Nepali translation coverage.
8. Add keyboard navigation, focus handling, and accessible labels.

## Stage 10 — Production readiness

1. Add automated tests for balanced posting, payment allocation, inventory valuation, period locking, and permissions.
2. Add error monitoring and structured logs.
3. Add import validation and duplicate detection.
4. Add backup, restore, and data-export workflows.
5. Add database migration verification to deployment.
6. Run a parallel-bookkeeping test against a known accounting dataset.
7. Obtain review from a Nepal accounting professional before commercial release.

## Immediate next development task

After Stage 6 database and acceptance tests pass, implement **Stage 7: VAT/TDS completeness, fiscal periods, server-enforced locks, and year-end closing**.
