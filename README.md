# HisabKitab — Phase 6b (Accounting foundation)

Cloud accounting for Nepali business. Phase 6a added OTP login; this phase
adds the real accounting core: a chart of accounts, customers/vendors,
double-entry vouchers, and per-account ledgers — all behind Row Level
Security so every user only ever sees their own books.

## What's new in 6b

- **Chart of Accounts** — a starter set of accounts (Cash, Bank, Sales,
  Purchase, VAT Payable/Receivable, Capital, common expenses) is created
  automatically the first time you sign in. Add more anytime.
- **Parties** — customers and vendors, each backed by its own ledger
  account under Sundry Debtors / Sundry Creditors.
- **Vouchers** — payment, receipt, journal, and contra entries, always
  double-entry (debit must equal credit before saving). Voiding a voucher
  keeps it in the record with a reason, rather than deleting it.
- **Ledger** — pick any account and see its running balance transaction
  by transaction.
- **Dashboard** — quick counts and recent activity.

## Database setup (do this once)

In your Supabase project, go to **SQL Editor → New query**, paste the
contents of `sql/phase6b_schema.sql`, and run it. It creates the tables,
Row Level Security policies, and two helper functions. Safe to re-run.

## Known limitation (by design, for now)

Fiscal-year labels are computed from an approximate AD cutover date
(mid-July), not a true Bikram Sambat calendar. Real BS date conversion
is planned for the localization phase — see the roadmap doc. This only
affects the fiscal-year label used for voucher numbering; amounts and
double-entry logic are unaffected.

## Run locally

```bash
npm install
npm run dev
```

Open the printed URL (usually http://localhost:5173). Enter your email,
receive a 6-digit code, and sign in.

## Configuration

Your Supabase project URL and publishable key live in `src/config.js`.
Change them there if you ever switch projects.

## Build & deploy

```bash
npm run build        # output in /dist
```

**GitHub Pages (automatic):** this repo includes
`.github/workflows/deploy.yml`. Push to `main`, then in your repo go to
Settings → Pages → Source → **GitHub Actions**. Every push deploys.

> Important for OTP: in your Supabase dashboard, add your deployed site's
> URL under Authentication → URL Configuration → Site URL / Redirect URLs,
> so login works from the live site (not just localhost).

## Notes

- Free-tier email is rate-limited (a few per hour) and codes may hit spam.
  For production, connect a real SMTP/email provider in Supabase.
- Invoicing, inventory, purchases, and detailed reports are not in this
  phase yet — see `hisabkitab-erp-roadmap.md` for the full phased plan.
- Security hardening (2FA, audit-log review, encrypted backups, rate
  limiting) is scheduled as its own phase once the core modules are done.
