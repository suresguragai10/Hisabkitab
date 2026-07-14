# HisabKitab

HisabKitab is a React and Supabase prototype for Nepal-focused cloud accounting. It includes invoicing, purchases, inventory, double-entry vouchers, ledgers, reports, tax-related screens, team features, and Bikram Sambat date support.

## Product status

The project is under active correction and is **not yet ready for production bookkeeping**. Some visible modules still need complete database migrations and accounting-integrity work. Review these files before deployment:

- `IMPLEMENTATION_PLAN.md` — ordered improvement and release plan
- `PRODUCT_AUDIT.md` — source-code and accounting audit
- `hisabkitab-erp-roadmap.md` — original feature roadmap

## Stage 1 and Stage 2 improvements included

This revision restores the manual voucher workflow:

- Real Journal, Payment, Receipt, and Contra entry form
- Multi-line debit and credit entry
- Balanced-voucher validation
- Atomic database posting for voucher header and lines
- Account ownership and active-account validation
- Safer sequential voucher numbering under concurrent posting
- In-app void dialog with a required reason
- Sales and purchase vouchers protected from direct voiding in the general voucher list
- Separate receipt/payment records and document allocations
- Correct partial-payment, paid, overdue, and outstanding calculations
- Payment history with controlled allocation reversal
- Allocation-based invoice, purchase, dashboard, and sales-report totals

## Database setup

Use a separate staging Supabase project first. Apply the existing SQL files in their intended phase order, then apply:

```text
sql/phaseP0_1_manual_vouchers.sql
sql/phaseP0_2_payment_allocations.sql
```

The Stage 1 migration replaces `post_voucher` with a safer version and adds `void_manual_voucher`. The Stage 2 migration adds payment/allocation tables, derived balances, payment history, over-allocation protection, and controlled reversals.

Do not apply migrations directly to production without a database backup and a staging test.

## Run locally

```bash
npm install
npm run dev
```

Vite prints the local development URL, normally `http://localhost:5173`.

## Build

```bash
npm run build
```

The compiled application is written to `dist/`.

The current build succeeds, although Vite reports that the main JavaScript bundle is larger than 500 kB. Route-based code splitting is included later in the implementation plan.

## Configuration

Supabase configuration currently lives in `src/config.js`. Use environment variables and separate credentials for development, staging, and production before a commercial release.

## Stage 1 verification

After applying the Stage 1 migration:

1. Open **Accounting → Vouchers**.
2. Create a journal with one debit and one credit of the same amount.
3. Confirm it appears once in Recent Vouchers.
4. Confirm both account ledgers contain the entry.
5. Try to save an unbalanced entry and confirm it is rejected.
6. Void the test journal with a reason and confirm ledger reports exclude it.

## Stage 2 verification

After applying the Stage 2 migration in staging:

1. Create an NPR 100 invoice and record an NPR 1 receipt.
2. Confirm NPR 1 is collected and NPR 99 remains outstanding.
3. Complete the payment and confirm the status becomes Paid.
4. Attempt an overpayment and confirm it is rejected.
5. Reverse an allocation with a reason and confirm both the document balance and ledger are restored.
6. Repeat the same tests for a purchase bill.

## Next priority

The next development stage is inventory and Cost of Goods Sold accounting. Do not use the product for live trading-business books until Stage 3 reconciles stock valuation to the Inventory Asset ledger.
