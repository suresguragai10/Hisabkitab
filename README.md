# HisabKitab

HisabKitab is a React, Vite, Supabase, and PostgreSQL accounting prototype for Nepal-focused businesses.

## Current release

Version **6.5.0** includes remediation Stages 1–6:

- safe manual double-entry vouchers;
- payment allocations and partial-payment status;
- perpetual moving-weighted-average inventory and COGS;
- controlled document lifecycle, reversals, credit notes, and debit notes;
- structured Chart of Accounts and balanced opening journals;
- database-generated, ledger-reconciled financial and operational reports.

The application remains a controlled development prototype and is not approved for production bookkeeping or statutory reliance. Complete the remaining tax, fiscal-period, security, testing, backup, and professional-review gates in `IMPLEMENTATION_PLAN.md`.

## Stage 6 reports

- General Ledger
- Day Book
- Trial Balance
- Profit & Loss
- Balance Sheet
- Cash Flow
- Receivables Ageing
- Payables Ageing
- Sales Register
- Purchase Register
- VAT Report
- Stock Valuation

Reports support date/as-of selection, fiscal-year filtering where applicable, print, CSV export, and account drill-down. Reconciliation differences are shown rather than hidden.

## Database migration

Use a staging Supabase project and take a backup first. Apply the migration chain in order. For Stage 6:

```text
sql/phaseP0_6_trustworthy_reports_preflight.sql
sql/phaseP0_6_trustworthy_reports.sql
sql/phaseP0_6_trustworthy_reports_verify.sql
```

The repository also contains the corrected Stage 5 migration, including the null-safe control-account flag and credit/debit-note voucher types.

## Local development

```bash
npm install
npm run dev
```

## Production build

```bash
npm run build
```

Deploy the complete generated `dist` directory as one release. Do not mix `index.html` or asset files from different builds.

## Configuration and secrets

Supabase browser configuration is in `src/config.js`. The frontend must use only a browser-safe publishable/anon key. Never place a service-role key, database password, SMTP password, or deployment token in frontend source or Git.

## Documentation

- `IMPLEMENTATION_PLAN.md` — ordered remediation roadmap
- `PRODUCT_AUDIT.md` — accounting, product, security, and UI audit
- `STAGE6_IMPLEMENTATION_NOTES.md` — Stage 6 migration and acceptance procedure
