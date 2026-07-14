# HisabKitab Stage 6 — Trustworthy Reports

Version: **6.5.0**

## Purpose

Stage 6 moves financial reporting from browser-side calculations to authenticated PostgreSQL reporting functions. Reports now use posted, non-void vouchers as the accounting source of truth and separately reconstruct document registers, historical payment allocation, credit/debit notes, and stock valuation.

## Migration order

1. Back up the Supabase database and schema.
2. Confirm the corrected Stage 5 migration is retained in the repository.
3. Run `sql/phaseP0_6_trustworthy_reports_preflight.sql`.
4. Resolve every returned missing, invalid, unbalanced, or unposted result.
5. Run `sql/phaseP0_6_trustworthy_reports.sql` in a clean SQL Editor tab.
6. Run `sql/phaseP0_6_trustworthy_reports_verify.sql`.
7. Deploy the complete newly generated `dist` directory.
8. Run the acceptance tests below with a known accounting dataset.

## Reports delivered

- General Ledger with opening, period, closing, running balance, date range, fiscal-year filter, print, and CSV export.
- Day Book with voucher line drill-down and debit/credit reconciliation.
- Trial Balance as of a selected date with an explicit balance check.
- Profit & Loss by structured report class.
- Balance Sheet with current earnings and asset/liability/equity reconciliation.
- Cash Flow derived from cash/bank voucher movements and account cash-flow categories.
- Invoice-level Receivables Ageing with current, 1–30, 31–60, 61–90, and over-90-day buckets.
- Bill-level Payables Ageing with the same buckets.
- Sales Register including credit notes as negative rows.
- Purchase Register including debit notes as negative rows.
- VAT Report including notes and comparison with VAT Payable/VAT Receivable ledger movement.
- Historical moving-weighted-average Stock Valuation compared with Inventory Asset.

## Trusted reporting functions

- `report_account_activity`
- `get_report_fiscal_years`
- `get_general_ledger_report`
- `get_day_book_report`
- `get_trial_balance_report`
- `get_profit_loss_report`
- `get_balance_sheet_report`
- `get_cash_flow_report`
- `get_receivables_ageing_report`
- `get_payables_ageing_report`
- `get_sales_register_report`
- `get_purchase_register_report`
- `get_vat_report`
- `get_stock_valuation_report`

Every function derives the owner from `auth.uid()` and filters all source data to that owner.

## Accounting behavior

### Ledger and statements

Debit balances are represented as positive values and credit balances as negative values inside the reporting engine. Trial Balance displays those net balances in separate debit and credit columns. P&L uses only activity within the selected period. Balance Sheet uses all posted activity up to the selected date and presents the cumulative unclosed income/expense balance as current earnings.

### Cash flow

Cash flow is derived only from vouchers containing a cash or bank line. Non-cash counterpart lines determine operating, investing, or financing classification. Cash-to-bank transfers are excluded from net cash flow because they have no non-cash counterpart.

### Ageing

Ageing is reconstructed as of the selected date using:

- original invoice or bill total;
- posted credit/debit notes effective by that date;
- payment allocations whose payment date is on or before that date;
- allocation reversals effective by that date;
- document cancellation vouchers effective by that date.

The ageing total is compared with structured receivable/payable ledger accounts. Legacy party opening balances without source invoices or bills will appear as a reconciliation difference and require reviewed conversion.

### VAT

Document VAT includes sales invoices, purchase bills, sales credit notes, and purchase debit notes. It is compared independently with movement in the VAT Payable and VAT Receivable system accounts for the selected period.

### Stock valuation

Historical stock valuation uses the last movement at or before the selected date. Where no earlier movement exists, it uses the stock/value before the first later movement, preserving the Stage 3 valuation cutover baseline. The total is compared with the Inventory Asset ledger.

## Acceptance tests

### Ledger and Day Book

1. Post a balanced NPR 1,000 journal and confirm the Day Book shows equal debit and credit.
2. Open both affected account ledgers and confirm opening + debits − credits = closing.
3. Change the date range and confirm only period entries change while opening balance rolls forward.
4. Export both reports to CSV and confirm amounts and dates match the screen.

### Trial Balance, P&L, and Balance Sheet

1. Run Trial Balance as of today; difference must be zero.
2. Confirm a sales voucher increases revenue and P&L profit.
3. Confirm a COGS voucher increases cost of sales and reduces profit.
4. Confirm Balance Sheet assets equal liabilities plus equity and current earnings.
5. Click an account on each statement and confirm ledger drill-down matches its report amount.

### Cash Flow

1. Record a customer receipt; operating cash flow should increase.
2. Buy a non-current asset through bank; investing cash flow should decrease.
3. Post owner capital to bank; financing cash flow should increase.
4. Transfer cash to bank; net cash flow should remain unchanged.
5. Opening cash + net change must equal closing cash.

### Ageing and registers

1. Create an NPR 100 invoice, allocate NPR 1, and confirm NPR 99 remains in receivables ageing.
2. Move the as-of date beyond 30, 60, and 90 days and confirm bucket transitions.
3. Create a credit note and confirm the invoice net amount and Sales Register reduce.
4. Repeat the same tests for a purchase bill and debit note.
5. Confirm ageing totals reconcile with party ledgers or document the legacy opening-balance difference.

### VAT and stock

1. Confirm invoice output VAT and purchase input VAT appear in the VAT Report.
2. Confirm credit/debit notes reduce their respective VAT totals.
3. VAT document totals must match VAT ledger movement.
4. Run Stock Valuation as of today; difference from Inventory Asset must be zero.
5. Run it before and after a purchase and sale and confirm historical quantity/value changes.

## Known limits

- Fiscal-year filters use the fiscal-year values stored on transactions. Stage 7 will add authoritative fiscal-period boundaries, locks, year-end closing, and carry-forward.
- Cash-flow classification depends on the Stage 5 `cash_flow_category` assigned to counterpart accounts. Review custom accounts before production reliance.
- Ageing exposes legacy opening balances as a ledger difference because those balances have no invoice/bill due date. They should be converted to source documents or reviewed opening schedules.
- Statutory Nepal VAT formats and return filing remain Stage 7 and require professional tax review.
- URL routing, reusable report-table components, and broader responsive redesign remain Stage 9.
