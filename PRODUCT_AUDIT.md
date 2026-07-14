# HisabKitab Product, Accounting, UI and Technical Audit

## Audit scope

This review covered the supplied React/Vite source code, Supabase SQL migrations, navigation structure, report calculations, inventory posting, access controls, responsiveness, maintainability, documentation, and a production build.

The production build completes, but that does not mean the application is operationally complete. Several defects only appear when a user opens or uses a module.

## Executive conclusion

HisabKitab is a useful prototype with a broad feature concept, but it is not ready to be trusted as production accounting software. The biggest risks are:

1. The manual voucher entry screen is missing and replaced by a duplicate voucher list.
2. Several visible modules depend on database tables and RPC functions that are absent from the supplied migrations.
3. Inventory movements are not fully integrated with the general ledger, so Profit & Loss and Balance Sheet results can be materially wrong for trading businesses.
4. Partial receipts/payments are marked as fully paid.
5. Reports labelled as ageing are not actual ageing reports.
6. The navigation and UI expose too many low-level masters as primary menu items and lack a consistent professional design system.
7. Security-definer database functions do not consistently validate that every referenced account, item, category, contact, or vendor belongs to the active business.

Recommended current positioning: **development prototype / internal test environment**, not production bookkeeping.

---

# 1. Critical functional defects

## 1.1 Voucher Entry is not a voucher entry screen

`src/pages/VoucherEntry.jsx` exports a component named `VoucherList` and contains another “Recent Vouchers” table. In `src/App.jsx`, both `VoucherEntry` and `VoucherList` are rendered together.

Result:

- Accounting → Vouchers shows duplicate voucher lists.
- There is no form for journal, receipt, payment, or contra entry.
- A Reverse button calls `handleReverse`, which is not defined.
- Dashboard’s “New Voucher” action opens a page where a voucher cannot be created.

Priority: **P0 — fix immediately**.

## 1.2 Supplied SQL does not support all visible modules

The frontend references relations that are not created in the supplied SQL:

- `bank_statement_lines`
- `bank_statements`
- `credit_notes`
- `debit_notes`
- `tds_entries`
- `tds_remittances`
- `user_workspace_pref`

The frontend calls RPCs that are also missing from the supplied SQL:

- `accept_invite`
- `complete_onboarding`
- `create_fiscal_periods`
- `create_tds_entry`
- `get_my_role`
- `get_payment_history`
- `get_tax_rates`
- `invite_member`
- `list_fiscal_periods`
- `list_my_team`
- `list_my_workspaces`
- `match_statement_line`
- `post_closing_stock`
- `reconcile_statement`
- `remit_tds`
- `remove_member`
- `set_opening_balances`
- `set_period_lock`
- `switch_workspace`
- `unmatch_statement_line`

Result: a clean deployment cannot reliably use onboarding, TDS, bank reconciliation, period locking, credit/debit notes, payment history, team membership, or workspace switching.

Priority: **P0 — create one authoritative migration set and verify it from a blank database**.

## 1.3 Setup flow can promise completion when backend functions are absent

The setup wizard calls missing RPCs such as opening-balance and onboarding functions. Its completion screen states that the chart and opening balances are ready, but the package does not include all backend definitions needed to guarantee that.

There is also a visible branding typo: `KitabHisabKitab` in the wizard logo.

Priority: **P0/P1**.

---

# 2. Accounting integrity audit

## 2.1 Inventory and cost of sales are not correctly posted to the ledger

The invoice posting creates:

- Debit customer / receivable
- Credit sales
- Credit output VAT

It reduces stock quantity, but it does not create the corresponding accounting entry:

- Debit Cost of Goods Sold
- Credit Inventory Asset

Purchase posting creates:

- Debit Purchase Account
- Debit input VAT
- Credit supplier

It also increases inventory quantity. This can produce a mismatch between operational stock and financial accounts. The application attempts to repair this through a closing-stock action, but `post_closing_stock` is absent from the supplied SQL.

Consequences:

- Profit may be overstated or understated.
- Inventory may not appear correctly in the Balance Sheet.
- Purchases and closing stock can be double-counted or inconsistently treated.
- Dashboard stock value and financial statements can disagree.

Recommended design:

- Use a perpetual inventory method: every sale posts COGS and reduces Inventory Asset using a defined valuation method.
- Or use a periodic method, but then formally implement opening stock, purchases, closing stock, and COGS adjustments with period locking.
- Choose and document weighted average or FIFO. Do not label a value “weighted average” unless the cost engine actually recalculates weighted average after every purchase.

Priority: **P0**.

## 2.2 Partial payments are treated as full settlement

`settle_document` accepts any positive amount and then changes the invoice or bill status to `paid`. It does not check whether the payment equals the remaining balance, and it stores only one settlement voucher reference.

Consequences:

- A payment of NPR 1 against an NPR 100,000 invoice can mark it paid.
- Multiple instalments are not modelled safely.
- Outstanding reports and sales collection figures become wrong.

Recommended design:

Create a payment allocation table with:

- payment voucher ID
- invoice/bill ID
- allocated amount
- allocation date
- reversal status

Derive status as Draft, Sent/Open, Partially Paid, Paid, Overdue, Cancelled, or Credited from allocations and document total.

Priority: **P0**.

## 2.3 “Ageing” is only a party balance list

The ageing report computes the net balance of each party account. It does not allocate balances to ageing buckets such as:

- Current
- 1–30 days
- 31–60 days
- 61–90 days
- Over 90 days

It also does not age individual invoices or apply payments against them.

Recommendation: rename the current report to “Receivables and Payables Summary” until invoice-level ageing is implemented.

Priority: **P1**.

## 2.4 Sales collection figures are status-based, not balance-based

The Sales Report counts the entire invoice total as collected when status is `paid`, and the entire total as outstanding for every other status. It does not use payment allocations or remaining balances.

Priority: **P0/P1**, dependent on payment allocation redesign.

## 2.5 VAT report is document-total based and incomplete

The VAT report totals invoice VAT minus purchase-bill VAT. It does not visibly incorporate:

- credit notes and debit notes
- sales or purchase returns
- exempt or zero-rated transactions
- import VAT
- bad-debt adjustments
- period locking and return status
- reconciliation to VAT ledger accounts

Recommendation: make the VAT report ledger-reconciled and transaction-classified, then add export formats only after statutory review.

Priority: **P1**.

## 2.6 Credit/debit notes appear detached from the accounting engine

The credit/debit-note UI references missing tables and does not have a supplied, auditable posting migration. Notes should automatically reverse revenue/purchase, VAT, receivable/payable, and stock where applicable.

Priority: **P0/P1**.

## 2.7 Financial statements rely on fragile account classifications

Balance Sheet grouping is hardcoded using strings such as `Cash-in-Hand`, `Bank Accounts`, `Duties & Taxes`, `General`, and `Sundry Debtors`. Custom group names can therefore be classified incorrectly.

Recommended Chart of Accounts fields:

- account code
- parent account/group ID
- report class
- account subtype
- normal balance
- cash-flow category
- control-account flag
- system-account flag
- allow-manual-posting flag

Reports should use structured classifications, not display-name strings.

Priority: **P1**.

## 2.8 Opening balances need one controlled opening journal

Opening balances are stored directly on individual account records. This can make the Trial Balance or Balance Sheet unbalanced unless a matching capital or suspense amount is entered separately.

Recommended design:

- Create a dated opening-balance voucher.
- Require total debit = total credit.
- Lock it after approval.
- Carry forward only Balance Sheet accounts during year close.

Priority: **P1**.

## 2.9 Fiscal-year and period controls are incomplete in the package

The UI references fiscal-period creation and locking functions that are not included. Accounting software needs server-enforced controls preventing posting into locked periods. UI-only restrictions are insufficient.

Priority: **P0/P1**.

---

# 3. Navigation and information architecture audit

## Current issue

The sidebar exposes many technical master records as separate primary modules. This makes the product feel like a collection of forms rather than a coherent accounting workflow.

Examples:

- Categories is a top-level item.
- Audit Log is under Reports & Compliance.
- Bank Reconciliation is inside Accounting rather than a Banking area.
- Credit and Debit Notes are combined under Sales even though purchase debit notes may follow a different workflow.
- Contacts is a whole main section containing only one page.
- Items, Categories, and Inventory are separated even though users normally manage categories inside Item settings.

## Recommended sidebar

### Home
- Dashboard

### Sales
- Invoices
- Receipts
- Sales Returns / Credit Notes
- Customers

### Purchases
- Bills
- Payments
- Purchase Returns / Debit Notes
- Suppliers

### Banking
- Bank & Cash Accounts
- Bank Transactions
- Reconciliation

### Accounting
- Journal Entries
- Chart of Accounts
- General Ledger
- Day Book
- Opening Balances
- Period Close

### Inventory
- Items
- Stock Overview
- Stock Movements
- Stock Valuation
- Warehouses later

### Reports
- Trial Balance
- Profit & Loss
- Balance Sheet
- Cash Flow
- Receivables Ageing
- Payables Ageing
- Sales Register
- Purchase Register
- Stock Reports

### Tax & Compliance
- VAT
- TDS
- Fiscal Periods

### Settings
- Business Profile
- Invoice Templates
- Tax Rates
- Users & Roles
- Audit Log
- Import / Export / Backup

Keep Item Categories as a tab or drawer inside Items, not a permanent top-level destination.

---

# 4. UI and UX audit

## 4.1 No reusable design system

The project contains roughly 360 inline `style={{...}}` usages, and almost all global CSS is embedded inside `App.jsx`. There are no dedicated CSS files or component-level style modules.

Consequences:

- inconsistent spacing, typography, button sizes, and colour use
- difficult global redesign
- duplicated UI logic
- higher regression risk

Recommendation: create reusable primitives:

- `PageHeader`
- `Card`
- `Button`
- `Input`, `Select`, `DateInput`
- `DataTable`
- `Tabs`
- `Badge`
- `Modal`, `Drawer`
- `EmptyState`
- `Toast`
- `ConfirmDialog`
- `Money`
- `StatusBadge`

Use central design tokens for spacing, typography, radius, shadow, colours, and breakpoints.

## 4.2 Emoji icons reduce professional consistency

The sidebar and dashboard use mixed emoji icons. Their appearance differs by device and operating system. Replace them with a consistent SVG icon set and use text labels as the primary cue.

## 4.3 Every page is visually treated as one large panel

This produces weak hierarchy. Professional accounting screens should normally have:

- breadcrumb or section title
- clear primary action
- summary metrics
- filter/search toolbar
- table/content area
- contextual side panel or modal

## 4.4 Tables are not mobile-safe

There are no reusable horizontal-scroll wrappers or responsive table patterns. Wide invoice, stock, TDS, reconciliation, and report tables will overflow narrow screens.

Recommendation:

- wrap all tables in a scroll container
- freeze important columns on desktop
- use compact card rows on mobile
- add pagination or virtualisation for large datasets

## 4.5 Accessibility is almost absent

Static review found no `aria-*` attributes despite approximately 148 buttons. Clickable business-type cards are `<div>` elements rather than accessible buttons. Icon-only close/menu controls need labels.

Recommendation: target WCAG 2.2 AA basics, keyboard navigation, focus states, labelled controls, semantic dialogs, and accessible error messages.

## 4.6 Browser navigation is missing

The app uses local state instead of routes. This means:

- browser Back does not navigate between modules
- refreshing returns the user to Dashboard
- pages cannot be bookmarked or shared
- individual records do not have stable URLs

Recommendation: add routing, for example:

- `/sales/invoices`
- `/sales/invoices/:id`
- `/accounting/journals/new`
- `/reports/profit-loss`

## 4.7 Feedback patterns are inconsistent

The app uses `alert`, `prompt`, and `confirm` in several workflows. Replace them with branded toast messages and confirmation dialogs, especially for voiding, reversing, deactivating, and reconciliation completion.

## 4.8 Bilingual support is incomplete

The navigation has translation keys, but large portions of page content are hardcoded in English or permanently mixed English/Nepali. Choose one active language at a time, while allowing dual-language invoice output where required.

## 4.9 Dashboard needs more decision value

Current cards are useful, but the dashboard should add:

- cash-flow trend
- overdue amount, not just count
- top overdue customers
- bills due soon
- bank items awaiting reconciliation
- current VAT/TDS obligations
- gross margin
- negative-stock exceptions
- recent audit/security activity for owners

---

# 5. Security and data-isolation audit

## 5.1 Role restrictions are mainly presentation-level in supplied code

Sidebar access rules hide modules based on role, but the supplied SQL does not include the workspace/team schema and role-enforcement functions. A secure system must enforce every permission in the database, not only in React.

## 5.2 Security-definer functions need ownership checks for every foreign key

Functions such as voucher posting and item creation accept account IDs, item IDs, category IDs, and vendor IDs. Not every function verifies that each supplied ID belongs to `auth.uid()` or the active workspace before inserting it.

Risk: if a foreign UUID is known, cross-tenant references may be inserted even when direct table RLS would block them.

Recommendation: create reusable database assertions such as:

- `assert_account_access(account_id)`
- `assert_item_access(item_id)`
- `assert_contact_access(contact_id)`
- `assert_workspace_role(required_role)`

Call them inside every security-definer function.

## 5.3 Audit trail can be spoofed by authenticated clients

`write_audit_log` is granted directly to authenticated users and accepts action, table name, record ID, old data, and new data from the client. A user can therefore create misleading audit entries.

Recommendation:

- revoke direct execution from clients
- write audit records only from trusted trigger/functions
- capture authenticated user, workspace, role, request ID, timestamp, and changed columns server-side
- use append-only storage and retention controls

## 5.4 Audit coverage is incomplete

The migration describes an immutable audit trail for every write, but triggers only cover selected actions. All create, update, void, reverse, allocation, reconciliation, stock adjustment, period lock, user role, and settings changes should be audited.

## 5.5 Rate limiting is client-callable and can be polluted

Anonymous/authenticated clients can call logging with arbitrary identifiers and success values. This is not a reliable substitute for gateway or server-side authentication rate limiting.

## 5.6 Views need explicit security behaviour

Views such as Trial Balance, contact summary, and item summary should explicitly use secure/invoker behaviour appropriate to the deployed PostgreSQL/Supabase version and be tested for tenant isolation.

---

# 6. Engineering quality audit

## Positive findings

- React components are separated by feature page.
- Supabase RLS exists for several core tables.
- Invoice and bill creation use atomic PostgreSQL functions.
- Document numbering was improved with a sequence table.
- The production build succeeds.
- Void rather than hard-delete is conceptually correct for accounting records.

## Main engineering weaknesses

### No automated tests

There are no unit, integration, end-to-end, or database tests in the project.

Minimum test suite:

- every voucher balances
- duplicate document numbers cannot occur under concurrency
- partial payment status is correct
- void/reversal restores balances and stock correctly
- P&L and Balance Sheet reconcile to Trial Balance
- period locks block server-side posting
- tenant A cannot access or reference tenant B records
- stock cannot become negative unless explicitly permitted
- credit note reverses sales, VAT, receivable, and stock/COGS

### No linting or formatting configuration

Add ESLint, Prettier, database migration checks, and CI.

### Large initial bundle

The build creates an approximately 602 KB JavaScript bundle before gzip and warns about chunk size. Add route-level lazy loading and split report/printing modules.

### Large central App component

`App.jsx` includes authentication, navigation, workspace state, error handling, and a large global stylesheet. Split it into shell, routing, auth, navigation, providers, and theme files.

### Stale documentation

The README still describes an older phase and says invoicing, inventory, purchases, and reports are not present, even though those modules are in the code. Documentation and migration order are not reliable enough for deployment.

### Calendar data needs independent verification

The BS calendar file claims verified coverage but contains a year marked “placeholder,” and its epoch comment and date value are inconsistent. Use a maintained, tested source and add conversion test vectors.

---

# 7. Recommended implementation order

## Sprint 0 — stop incorrect accounting

1. Restore a real Voucher Entry component.
2. Remove the duplicate voucher list and broken Reverse action.
3. Consolidate every SQL migration into one reproducible migration chain.
4. Add missing tables/RPCs or hide unfinished modules.
5. Redesign payments around allocations and partial-payment status.
6. Decide and implement the inventory accounting method.
7. Add database constraints and tenant/role checks.
8. Create accounting integrity tests before adding more features.

## Sprint 1 — accounting foundation

1. Structured Chart of Accounts hierarchy.
2. Opening journal and fiscal-year close.
3. Journal, receipt, payment, contra, and reversal workflows.
4. Party subledger linked to invoices/bills and allocations.
5. Correct Trial Balance, P&L, Balance Sheet, Day Book, and General Ledger.
6. Server-enforced period locking.

## Sprint 2 — workflow cleanup

1. Implement the recommended sidebar.
2. Add routing and stable record URLs.
3. Merge Item Categories into Items.
4. Separate sales returns and purchase returns appropriately.
5. Move Audit Log to Settings/Admin.
6. Create consistent list/detail/create workflows.

## Sprint 3 — professional UI system

1. Design tokens and reusable components.
2. SVG icon library.
3. Responsive table system.
4. Toasts and confirmation dialogs.
5. Accessibility pass.
6. Consistent bilingual implementation.
7. Improved dashboard and empty states.

## Sprint 4 — compliance and operational readiness

1. VAT/TDS logic reviewed by a qualified Nepal tax/accounting professional.
2. Sales and purchase register exports.
3. Credit/debit-note posting and return workflows.
4. Backup/restore and data export.
5. Audit retention and security monitoring.
6. Performance, concurrency, and disaster-recovery tests.

---

# 8. Suggested release gates

Do not call the product production-ready until all are true:

- Clean database setup succeeds from zero.
- All visible modules have matching migrations.
- Trial Balance remains balanced after every supported workflow.
- P&L and Balance Sheet reconcile to the ledger.
- Inventory valuation and COGS are tested.
- Partial payments and allocations are tested.
- Period locks are enforced in PostgreSQL.
- Roles are enforced in PostgreSQL.
- Cross-tenant security tests pass.
- Void/reversal and audit logs are complete.
- At least one accountant validates end-to-end sample books.
- Mobile and print layouts pass acceptance testing.

## Final assessment

HisabKitab has a good scope and several strong building blocks, but the current dissatisfaction is justified. The problem is not only that the headings and UI are in the wrong places. The product has grown phase-by-phase without one unified accounting model, migration system, navigation model, or design system.

The correct next move is not to add more modules. First stabilise the ledger, payments, inventory accounting, migrations, and permissions. Then reorganise the navigation and rebuild the interface on reusable components.
