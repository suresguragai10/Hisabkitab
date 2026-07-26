# HisabKitab

HisabKitab is a React, Vite, Supabase (PostgreSQL) accounting application for Nepal-focused businesses.

## What it does today

- Invoicing, purchase bills, credit/debit notes — draft → post → cancel lifecycle, with payment allocations and partial-payment status.
- Sales Orders and RFQ/Purchase Quotations — pre-invoice/pre-bill commitments (draft → confirmed/sent → converted or cancelled) that convert into an invoice/bill draft; Sales Orders reserve stock (`committed_stock`) until converted or cancelled.
- Perpetual weighted-average inventory and COGS, posted automatically on invoice/bill posting.
- Manual vouchers (journal/payment/receipt/contra), structured Chart of Accounts, balanced opening journals, fiscal-period locking.
- VAT preparation (Annex 13 export) and TDS (deduction, remittance, certificates).
- Multi-user workspaces with real role-based access control (owner / accountant / staff / viewer), enforced in the database via `assert_role()`, not just hidden in the UI.
- Bank reconciliation, structured financial reports (Trial Balance, P&L, Balance Sheet, Cash Flow, Ageing, Sales/Purchase Register, Stock Valuation) with drill-down and CSV export.
- Bilingual (English/Nepali) print documents for Invoices, Bills, and Credit/Debit Notes. The rest of the app UI is still English-only.
- Dashboard with cash position, sales trend, overdue/due-soon receivables and payables, TDS/bank-reconciliation alerts, gross margin, and top-overdue-customers.

The application is a working prototype under active development, not yet certified for production bookkeeping or statutory reliance without independent review. See `docs/AUDIT_TRACKER.md` for the current, maintained status of every known gap (security, UI/UX, testing) — it's the live source of truth, not this file.

## Local development

```bash
npm install
npm run dev
```

## Testing and linting

```bash
npm test          # vitest
npm run lint       # eslint
npm run format     # prettier --write
```

## Production build

```bash
npm run build
```

Deploy the complete generated `dist` directory as one release. Do not mix `index.html` or asset files from different builds.

## Database migrations

All schema/function changes live in `sql/`, named `phase<N>_<description>.sql` in the order they should be applied. Apply new migrations against a staging Supabase project first when possible. Live-database state can drift from what's in this repo (several tables/views were built directly in Supabase Studio before being captured back into git) — when in doubt, check the live definition (`pg_proc`, `pg_views`, `information_schema`) rather than assuming the repo file is current.

## Configuration and secrets

Supabase browser configuration is in `src/config.js`. The frontend must use only a browser-safe publishable/anon key. Never place a service-role key, database password, SMTP password, or deployment token in frontend source or Git.

## Documentation

- `docs/AUDIT_TRACKER.md` — the maintained, cross-session tracker of every audit finding and its current status. Start here.
- `PRODUCT_AUDIT.md` — the original independent product/accounting/security/UI audit report.
- `IMPLEMENTATION_PLAN.md`, `STAGE2_IMPLEMENTATION_NOTES.md` through `STAGE6_IMPLEMENTATION_NOTES.md` — historical implementation notes from earlier development stages.
