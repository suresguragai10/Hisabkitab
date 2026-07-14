# HisabKitab

HisabKitab is a React 18, Vite, Supabase, and PostgreSQL accounting prototype for Nepal-focused businesses. It includes invoicing, purchases, inventory, double-entry vouchers, ledgers, reports, tax-related screens, team features, and Bikram Sambat date support.

## Product status

Version **6.4.0** contains the source implementation through Stage 5 of the remediation plan. It remains a **development prototype** and is not approved for production bookkeeping or statutory reliance. Complete staging migration, acceptance, reconciliation, role/RLS, report, tax, backup, and professional accounting review gates before using real business data.

Review these files before deployment:

- `IMPLEMENTATION_PLAN.md` — ordered release plan
- `PRODUCT_AUDIT.md` — accounting, security, UI, and technical audit
- `STAGE2_IMPLEMENTATION_NOTES.md` — payment allocations
- `STAGE3_IMPLEMENTATION_NOTES.md` — perpetual inventory and COGS
- `STAGE4_IMPLEMENTATION_NOTES.md` — document lifecycle, reversals, and notes
- `STAGE5_IMPLEMENTATION_NOTES.md` — structured Chart of Accounts and opening journals

## Implemented remediation stages

### Stage 1 — manual vouchers

- Journal, Payment, Receipt, and Contra entry
- Multi-line balanced posting in one PostgreSQL transaction
- Account ownership checks and safer numbering
- Controlled voiding of manual vouchers

### Stage 2 — payment allocations

- Separate payments and document allocations
- Open, Partial, Paid, and Overdue balances derived from allocations
- Over-allocation prevention and controlled payment-allocation reversal
- Payment history on invoices and bills

### Stage 3 — inventory and COGS

- Perpetual inventory with moving weighted-average cost
- Inventory Asset and Cost of Goods Sold posting
- Purchase, sale, opening stock, damage, and adjustment valuation
- Stock valuation versus Inventory Asset reconciliation

### Stage 4 — document lifecycle

- Separate Draft, Posted, Cancelled, and Credited lifecycle states
- Editable drafts and immutable posted invoice/bill identities
- Controlled source-document and note cancellation vouchers
- Source links and reversal links on generated vouchers
- Immutable invoice, bill, credit-note, and debit-note numbering by fiscal year
- Sales credit notes and purchase debit notes with VAT, party, stock, and COGS posting
- Private document attachments and internal notes


### Stage 5 — structured Chart of Accounts

- Stable account codes and parent-child hierarchy
- Report classes, account subtypes, normal balances, and cash-flow categories
- Protected system and control accounts
- Controlled create, update, and deactivation RPCs
- Balanced opening journals and legacy-opening conversion
- P&L, Balance Sheet, Trial Balance, dashboard, bank, and voucher selection based on structured fields

## Database application order

Use a separate staging Supabase project and create a backup first. Apply the accepted baseline migrations in their documented order. For the latest changes, run:

```text
sql/phaseP0_5_structured_chart_preflight.sql
sql/phaseP0_5_structured_chart.sql
sql/phaseP0_5_structured_chart_verify.sql
```

Every preflight result labelled missing, duplicate, or blocking should be resolved before the main migration. Review every verification result and complete the acceptance tests in `STAGE5_IMPLEMENTATION_NOTES.md` before production scheduling.

## Run locally

```bash
npm install
npm run dev
```

Vite normally prints `http://localhost:5173`.

## Build

```bash
npm run build
```

The compiled application is written to `dist/`. The current build succeeds; Vite still warns that the main bundle is larger than 500 kB. Route-level code splitting remains a later UI/engineering task.

## Configuration and security

Supabase browser configuration is in `src/config.js`. Use only the project URL and a browser-safe publishable/anon key. Never place a service-role key, database password, SMTP password, or deployment token in the frontend bundle.

Use separate development, staging, and production projects. Do not apply migrations directly to production without a verified backup and rollback procedure.

## Next priority

After Stage 5 is migrated and accepted in staging, proceed to **Stage 6: trustworthy reports**, beginning with General Ledger, Day Book, Trial Balance, Profit & Loss, and Balance Sheet reconciliation.
