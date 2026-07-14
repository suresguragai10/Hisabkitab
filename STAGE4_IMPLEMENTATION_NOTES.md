# HisabKitab Stage 4 Implementation Notes

Version: **6.3.0**  
Migration: `sql/phaseP0_4_document_lifecycle.sql`

## Last completed stage

Stage 3 perpetual weighted-average inventory and COGS was implemented, applied by the owner, and pushed to the repository. Stage 4 resumes at the next unfinished section: controlled financial-document lifecycle and returns.

## Lifecycle model

Stage 4 separates two concepts that earlier releases mixed together:

- `document_status`: `draft`, `posted`, `cancelled`, or `credited`
- `status`: payment state such as `open`, `partial`, `paid`, or `overdue`

A draft can be edited or deleted. Posting creates the accounting voucher and inventory movements in the same transaction. A posted document is not edited directly. Corrections happen through a credit/debit note or a controlled cancellation voucher. Cancelled and credited records remain visible for audit history.

## Main database changes

- Added lifecycle timestamps, cancellation fields, credited totals, and net totals to invoices and purchase bills.
- Added source-document and reversal links to vouchers.
- Added immutable fiscal-year numbering indexes for invoices, bills, credit notes, and debit notes.
- Added trusted draft save, draft post, and draft delete RPCs.
- Replaced immediate invoice/bill creation with draft-then-post processing internally.
- Added complete sales credit-note and purchase debit-note tables and posting functions.
- Added controlled cancellation for invoices, bills, credit notes, and debit notes.
- Added private internal-note and attachment metadata tables.
- Added a private Supabase Storage bucket and owner-folder storage policies.
- Revoked direct authenticated writes to financial document and note tables.
- Linked payment, payment-reversal, and inventory-movement vouchers to their source records.
- Server-side draft functions recalculate line amount, VAT, and total from quantity, rate, and VAT rate rather than trusting browser totals.

## Accounting behavior

### Posting an invoice

- Debit customer/Accounts Receivable for the invoice total.
- Credit Sales for the subtotal.
- Credit Output VAT when applicable.
- For tracked goods, debit COGS and credit Inventory Asset at the Stage 3 weighted-average cost.

### Posting a purchase bill

- Credit vendor/Accounts Payable for the bill total.
- Debit Inventory Asset for tracked goods.
- Debit Purchase Expense for non-inventory lines.
- Debit Input VAT when applicable.

### Sales credit note

A credit note must reference a posted invoice and specific original invoice lines.

- Debit Sales.
- Debit Output VAT.
- Credit customer/Accounts Receivable.
- Restore returned stock at the original invoice-line cost snapshot.
- Debit Inventory Asset and credit COGS for returned tracked goods.

The cumulative active returned quantity cannot exceed the original line quantity. Automatic credit is limited to the invoice’s unpaid and uncredited balance. Reverse or refund allocations first when a paid amount must also be returned.

### Purchase debit note

A debit note must reference a posted purchase bill and specific original bill lines.

- Debit vendor/Accounts Payable.
- Credit Input VAT.
- Credit Inventory Asset or Purchase Expense.
- Remove returned stock at the current weighted-average cost.
- Post any difference between source purchase value and current inventory value to Purchase Returns Clearing.

The cumulative active returned quantity cannot exceed the original line quantity.

### Cancellation

Cancellation requires a reason and effective date and creates an equal-and-opposite voucher. Source documents cannot be cancelled while active payments or active notes remain. Inventory cancellation can also be blocked when stock is no longer available or when a legacy source line lacks a Stage 3 cost snapshot.

## Attachments and internal notes

- Internal notes are private and are not printed.
- Files are stored in the private `document-attachments` bucket.
- Storage paths begin with the authenticated owner UUID.
- Metadata registration is limited to files no larger than 20 MB.
- Delete file attachments before deleting a draft; this prevents orphaned storage objects.

## Required migration order

Apply in a staging Supabase project after a backup:

1. Confirm the accepted Stage 1, Stage 2, and Stage 3 migrations are present.
2. Run `sql/phaseP0_4_document_lifecycle_preflight.sql`.
3. Resolve every missing, duplicate, or blocking result.
4. Apply `sql/phaseP0_4_document_lifecycle.sql` as one complete query.
5. Run `sql/phaseP0_4_document_lifecycle_verify.sql`.
6. Deploy the complete newly built `dist` folder.
7. Run the acceptance tests below in staging.
8. Record the migration, test evidence, backup ID, operator, and rollback reference.

Do not paste function signatures or fragments as standalone SQL. Run each complete SQL file in a clean Supabase SQL Editor tab.

## Acceptance tests

### Draft and posting

1. Create an invoice draft with two lines.
2. Edit its date, customer, quantities, rates, and VAT, then save again.
3. Confirm its number and fiscal year do not change.
4. Confirm no voucher or stock movement exists while it is a draft.
5. Post it and confirm exactly one balanced source-linked voucher is created.
6. Confirm tracked stock and COGS move only once.
7. Confirm the posted invoice cannot be edited or deleted through the UI or direct authenticated table writes.
8. Repeat the same flow for a purchase bill.

### Partial credit note

1. Post an unpaid invoice for 10 tracked units at NPR 100 plus VAT.
2. Issue a credit note for 2 units.
3. Confirm receivable, sales, and output VAT reduce by the note values.
4. Confirm 2 units return to stock at the original invoice-line unit cost.
5. Confirm COGS is reversed by that inventory cost.
6. Confirm invoice `credited_amount`, `net_total`, and `outstanding_amount` reconcile.
7. Attempt to return more than the remaining 8 units; it must be rejected.

### Purchase debit note

1. Post an unpaid bill for 10 tracked units.
2. Return 2 units through a debit note.
3. Confirm payable and input VAT reduce.
4. Confirm stock decreases by 2 units at current weighted-average cost.
5. Confirm Inventory Asset plus Purchase Returns Clearing/expense entries balance to the debit-note subtotal.
6. Attempt to return more than the remaining source quantity; it must be rejected.

### Cancellation controls

1. Cancel an unpaid posted invoice with no credit notes.
2. Confirm an opposite voucher, restored stock, reversed COGS, and a reversal link.
3. Confirm the source invoice remains visible as Cancelled.
4. Attempt to cancel a document with an active payment; it must be rejected.
5. Cancel a credit/debit note and confirm its stock and ledger effects reverse.
6. Attempt a stock-removing cancellation when insufficient stock is available; it must be rejected.

### Numbering and activity

1. Create simultaneous drafts and confirm no duplicate number by owner/fiscal year.
2. Confirm a document number and fiscal year cannot be changed after assignment.
3. Add an internal note and confirm it does not appear on print output.
4. Upload, open through a signed URL, and delete an attachment.
5. Confirm another authenticated owner cannot read the metadata or storage object.

## Release limitations

- Stage 4 source and build checks pass, but the migration has not been applied to the owner’s Supabase project in this workspace.
- The current return policy requires reversing/refunding payments before crediting a paid balance; an automatic customer/vendor refund workflow remains future work.
- Legacy posted inventory lines without Stage 3 cost snapshots require a reviewed correction rather than automatic return or cancellation.
- Period locks, structured Chart of Accounts classifications, comprehensive role enforcement, and statutory VAT/TDS review remain open.
- The application is still not approved for production bookkeeping.
