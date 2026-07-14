# HisabKitab — ERP Roadmap (Phase 6b onward)

Research-backed plan for turning HisabKitab from a login shell into a full
accounting/ERP system for Nepali businesses, before we harden security.

---

## 1. What Nepal's rules actually require (so we build the right things first)

- **VAT is a flat 13%**, unchanged for years. Registration is mandatory above
  NPR 50 lakh turnover (goods) or NPR 30 lakh (services/mixed) — but some
  sectors (liquor, software, telecom, hardware, hotels, etc.) must register
  from their first sale regardless of turnover.
- **VAT returns are filed monthly**, due the 25th of the following Nepali
  month, through the IRD taxpayer portal. Even a nil month needs a nil
  return. Late filing = penalty per period.
- **A valid tax invoice** needs: "Tax Invoice" heading, seller name/address/PAN,
  serial number, dual date (BS + AD), buyer name/address/PAN, line items,
  taxable value, 13% VAT amount, grand total in figures *and* words, and a
  signature/seal. Businesses must keep sales/purchase registers (Bikri
  Khata / Kharid Khata) for 6 years.
- **E-billing / CBMS (real-time invoice sync to IRD) is only mandatory above
  NPR 10 crore annual turnover** (NPR 5 crore for hotels/restaurants/canteens).
  Below that, a business just needs correctly formatted invoices — no
  government API integration required. **Good news: we don't need to build
  CBMS integration now**, but we should build the invoice/audit-trail
  architecture in a way that makes adding it later straightforward (see
  §4, Phase 9), because IRD-certified software is generally expected to:
  never hard-delete a record (edits/voids must be logged with who/when/why),
  number invoices per fiscal year, and support reprint labeling
  ("Copy of Original – 2/3…").
- **Fiscal year** runs Shrawan 1 → Ashad end (mid-July to mid-July), on the
  Bikram Sambat calendar. Year-end close needs to carry forward balances
  correctly.
- **TDS** (tax deducted at source) is a second, separate compliance track
  many businesses need alongside VAT.

## 2. What competing Nepali products already offer

Looking at Tigg, Lekhapal, OneFlow, Swastik, Karobar, and CrossOver, the
common feature bar for "serious" Nepali accounting software is:

- Double-entry bookkeeping: chart of accounts, journal/payment/receipt/contra
  vouchers
- Real-time P&L, Balance Sheet, Cash Flow, Trial Balance, Day Book
- Party ledgers with running balance + ageing (who owes you, who you owe)
- VAT & TDS auto-calculation, IRD-format sales/purchase register export
- Inventory: multi-warehouse stock, batch/expiry tracking, barcode scanning,
  low-stock alerts
- POS integration for retail/restaurant use cases
- Bank statement import + reconciliation
- Nepali calendar (BS) support throughout, bilingual UI (Nepali/English)
- Payment reminders for overdue invoices
- Multi-user roles, multi-branch
- Cloud access from any device + automatic backups

This is the bar HisabKitab needs to clear to be genuinely useful, not just
a login page.

## 3. Recommended feature set (organized by module)

**Core Accounting**
- Customizable chart of accounts, with sensible defaults per business type
- Journal, payment, receipt, and contra vouchers
- Party (customer/vendor) ledgers — running balance, "khata" style
- Trial balance, P&L, balance sheet, cash flow — computed live from vouchers
- Bank & cash books, reconciliation against imported bank statements
- Fiscal year setup (BS-based) with year-end close and balance carry-forward
- Bikram Sambat + AD dual-date support everywhere dates appear

**Billing & Invoicing**
- IRD-format tax invoices (all mandatory fields from §1), PDF export
- Quotation → Sales Order → Invoice conversion
- Credit notes / debit notes / sales returns
- Recurring invoices + automatic due-date reminders
- Custom branding: logo, business details, invoice numbering per fiscal year

**Inventory**
- Item master with categories, units, opening stock
- Multi-warehouse / multi-location stock with transfers
- Batch & expiry tracking where relevant
- Barcode scanning support
- Low-stock alerts, stock valuation (FIFO/weighted average)
- Purchase orders + goods-received notes

**Sales & Purchases**
- Auto-maintained sales/purchase registers (matches Bikri/Kharid Khata)
- Receivables & payables ageing reports
- Vendor bills, payment tracking

**Tax Compliance**
- VAT auto-calculation at 13%, exempt/zero-rated item flags
- Monthly VAT-return-ready reports (Annexure-13-style export)
- TDS tracking and reports
- Excel export matching IRD formats

**Reports & Dashboard**
- Owner-facing dashboard: cash position, sales trend, top customers/items,
  outstanding dues
- Full report library: day book, ledgers, trial balance, P&L, balance sheet,
  stock valuation, ageing, VAT summary

**Payments & Banking**
- Local payment gateway support (eSewa, Khalti, Fonepay, ConnectIPS)
- Bank statement import & reconciliation

**Multi-user & Access**
- Role-based access (owner / accountant / staff / read-only)
- Multi-branch support
- Full audit trail: every edit/void records user, timestamp, and reason
  (this lays the groundwork for CBMS eligibility later, and is good
  practice regardless)

**Usability ("maximum things easy for the user")**
- Nepali/English language toggle
- Mobile-friendly, installable as a PWA, works offline with sync-on-reconnect
- "Snap a photo of a bill" quick entry
- Reminders: overdue invoices, low stock, VAT filing deadline
- Import/export via Excel/CSV, one-click backup download
- Setup wizard with starter chart-of-accounts templates by business type
  (retail, trading, service, restaurant)

## 4. Build roadmap (continuing from Phase 6a)

| Phase | Focus | Depends on |
|---|---|---|
| 6a ✅ | Supabase OTP login | — |
| 6b | Database foundation: parties, chart of accounts, core ledger + vouchers, RLS from day one | 6a |
| 6c | Invoicing & billing (IRD-format tax invoices, quotations, credit notes) | 6b |
| 6d | Inventory & stock management | 6b |
| 6e | Purchases & vendor bills | 6b, 6d |
| 6f | Reports & dashboard (P&L, balance sheet, VAT summary, ageing) | 6b–6e |
| 6g | Banking: statement import, reconciliation, local payment gateways | 6b |
| 6h | Multi-user roles & multi-branch | 6b |
| 7 | **Security hardening**: full RLS audit, 2FA, encrypted backups, rate limiting, immutable audit log | all above |
| 8 | Nepali localization polish: language toggle, PWA/offline, BS calendar throughout | all above |
| 9 (optional, later) | CBMS/e-billing integration — only needed once turnover crosses the NPR 10 crore threshold | 7 |

Each phase is scoped to be independently shippable and testable, the same
way 6a was — no giant rewrite, just steady layering.

## 5. Immediate next step: Phase 6b

Phase 6b is the foundation everything else sits on. It needs:
- Supabase tables: `parties` (customers/vendors), `chart_of_accounts`,
  `vouchers` (journal/payment/receipt/contra) with line items
- Row Level Security from the start, scoped per authenticated user
- A basic ledger view per party and per account
- Nepali fiscal year setting (start date, BS/AD mapping)

## 6. One thing I need from you before writing Phase 6b

The chart of accounts and inventory setup differ meaningfully by business
type (a retail shop, a trading/wholesale business, and a pure service
business all need different defaults). Let me know which best describes
the primary use case so Phase 6b starts with the right defaults.
