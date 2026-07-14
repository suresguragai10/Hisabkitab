# HisabKitab Stage 2 Implementation Notes

Version: **6.1.0**  
Status: **source implementation complete; Supabase staging migration and acceptance tests required**

## What changed

Stage 2 replaces the legacy one-flag settlement flow with explicit payment and allocation records.

- `document_payments` stores each receipt or vendor payment, its date, cash/bank mode, reference, posting voucher, and reversal state.
- `payment_allocations` links a payment amount to exactly one invoice or purchase bill.
- `amount_paid` and `outstanding_amount` on documents are database-managed summaries derived from active allocations.
- Document status is recalculated as Draft, Open, Partial, Paid, Overdue, Cancelled, or Credited.
- `record_document_payment` locks the document row, recalculates its balance, rejects over-allocation, posts a balanced voucher, and creates the payment/allocation in one transaction.
- `reverse_payment_allocation` requires a reason, posts an equal and opposite voucher, marks the allocation reversed, and recalculates the document.
- Existing `settle_document` callers remain compatible, but now use the safe allocation function.
- Invoice, purchase, dashboard, and sales-report figures use allocated and outstanding amounts instead of the old paid/unpaid flag.

## Migration order

Use a database backup and staging project first.

1. Apply all existing baseline migrations required by the current project.
2. Apply `sql/phaseP0_posting.sql` if it is not already present.
3. Apply `sql/phaseP0_1_manual_vouchers.sql`.
4. Apply `sql/phaseP0_2_payment_allocations.sql`.
5. Run the verification queries in `sql/phaseP0_2_payment_allocations_verify.sql`.
6. Rebuild and deploy the complete `dist` directory.

Do not apply the Stage 2 migration before the invoice, purchase bill, voucher, account, and party tables/functions exist.

## Legacy data handling

The migration converts existing documents marked Paid, or documents with a pre-existing positive `amount_paid`, into explicit legacy payment/allocation rows. Because older releases did not reliably store payment date and mode, migrated rows are marked `is_legacy = true` and use a review note. Verify these records against bank/cash evidence before production use.

## Acceptance tests

### Invoice

1. Create an NPR 100 invoice.
2. Record an NPR 1 receipt.
3. Confirm `amount_paid = 1`, `outstanding_amount = 99`, and status is Partial, or Overdue when the due date has passed.
4. Confirm the receipt voucher debits Cash/Bank and credits the customer/control account by NPR 1.
5. Try to record NPR 100 more; confirm the RPC rejects the overpayment.
6. Record NPR 99; confirm status becomes Paid and outstanding becomes zero.
7. Reverse the NPR 99 allocation with a reason.
8. Confirm status returns to Partial/Overdue, outstanding returns to NPR 99, and a reversing voucher is posted.

### Purchase bill

Repeat the same sequence for an NPR 100 purchase bill. The original payment voucher must debit the vendor/control account and credit Cash/Bank. The reversal must post the opposite entries.

### Concurrency

Open the same document in two sessions and attempt to allocate the full outstanding amount simultaneously. Only one allocation should commit; the second must be rejected after the document lock sees the updated balance.

## Verification limits

The React production build succeeds locally. This package does not contain a local Supabase/PostgreSQL runtime, so the SQL migration still requires execution and transaction-level acceptance testing in the owner's staging project.

## Remaining high-risk work

Stage 3 remains required before live trading-business bookkeeping: inventory purchases and sales must post Inventory Asset and Cost of Goods Sold using a documented valuation method, and stock valuation must reconcile to the general ledger.
