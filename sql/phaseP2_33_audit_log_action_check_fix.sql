-- ============================================================
-- HisabKitab P2.33 -- audit_log_action_check was missing the three
-- new lifecycle actions phaseP2_32 introduced (confirm_sales_order,
-- send_rfq, convert_sales_order_to_invoice/convert_rfq_to_bill),
-- which made every one of those calls fail with "new row for
-- relation audit_log violates check constraint audit_log_action_check"
-- -- rolling back the whole function, including the stock-commitment
-- update and status change. Confirmed 2026-07-26 by the user: a
-- Sales Order never actually reached "confirmed" status because of
-- this, so the "Convert to Invoice" option never appeared.
--
-- Fetched the LIVE constraint (pg_get_constraintdef) rather than
-- trusting the repo's phaseP0_4_document_lifecycle.sql copy, which
-- was stale -- same repo-vs-live drift as the item_summary view
-- fixed in phaseP2_32. The live list already had 6 more values
-- (lock, unlock, file, remit, close, configure) than the repo file,
-- picked up by migrations never captured back into this repo. It was
-- STILL missing 'delete' and 'merge', which delete_structured_account
-- and merge_account (Chart of Accounts "Delete"/"Merge into...") have
-- been calling all along -- meaning those two features have likely
-- been silently failing in production the same way Sales Order
-- confirmation just did. Fixed here too.
--
-- Full list = live 18 values + confirm/convert/send (this migration's
-- own new actions) + delete/merge (pre-existing, already-broken
-- calls). Nothing removed from what's live today.
-- ============================================================

alter table audit_log drop constraint if exists audit_log_action_check;
alter table audit_log add constraint audit_log_action_check check (
  action in (
    'create','update','void','deactivate','login','logout','reverse',
    'create_draft','update_draft','delete_draft','post','cancel',
    'lock','unlock','file','remit','close','configure',
    'confirm','send','convert','delete','merge'
  )
);
