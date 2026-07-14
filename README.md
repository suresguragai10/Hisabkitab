# HisabKitab

HisabKitab is a React and Supabase prototype for Nepal-focused cloud accounting. It includes invoicing, purchases, inventory, double-entry vouchers, ledgers, reports, tax-related screens, team features, and Bikram Sambat date support.

## Product status

The project is under active correction and is **not yet ready for production bookkeeping**. Some visible modules still need complete database migrations and accounting-integrity work. Review these files before deployment:

- `IMPLEMENTATION_PLAN.md` — ordered improvement and release plan
- `PRODUCT_AUDIT.md` — source-code and accounting audit
- `hisabkitab-erp-roadmap.md` — original feature roadmap

## Included remediation stages

### Stage 1 — Manual vouchers

- Balanced Journal, Payment, Receipt, and Contra vouchers
- Atomic posting, ownership validation, safer numbering, and controlled voiding

### Stage 2 — Payment allocations

- Separate payment and allocation records
- Accurate partial-payment, paid, overdue, and outstanding balances
- Payment history and controlled allocation reversals

### Stage 3 — Perpetual inventory

- Moving weighted-average valuation
- Tracked purchases debit Inventory Asset
- Tracked sales debit COGS and credit Inventory Asset
- Valued opening stock and damage/shrinkage adjustments
- Stock ledger with quantity/value balances
- Live reconciliation of stock valuation to the Inventory Asset ledger
- Inventory cutover-date and chronological movement controls

## Database setup

Use a separate staging Supabase project first. Apply the existing SQL files in their intended phase order, then apply the remediation migrations in order:

```text
sql/phaseP0_1_manual_vouchers.sql
sql/phaseP0_2_payment_allocations.sql
sql/phaseP0_3_inventory_cogs.sql
```

Run `sql/phaseP0_3_inventory_cogs_preflight.sql` before Stage 3, then run each matching verification script after its migration. Stage 3 initializes existing quantities and values but does not automatically post a catch-up journal; review the Inventory reconciliation in staging first.

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

## Stage 3 verification

After applying the Stage 3 migration, run:

```text
sql/phaseP0_3_inventory_cogs_verify.sql
```

Then complete the weighted-average purchase, sale, damage, and reconciliation test in `STAGE3_IMPLEMENTATION_NOTES.md`.

## Next priority

Stage 4 will add controlled posted-document cancellation/reversal and complete credit/debit-note return workflows. Full returns must not be simulated with a manual stock adjustment because VAT and receivable/payable balances must reverse with the stock.
