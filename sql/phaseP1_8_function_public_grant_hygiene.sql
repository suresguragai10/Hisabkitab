-- ============================================================
-- HisabKitab P1.8 — Close the "PUBLIC execute by default" gap
-- across every function in the public schema.
--
-- PostgreSQL grants EXECUTE on new functions to PUBLIC by default,
-- and every role (including authenticated/anon) implicitly inherits
-- from PUBLIC. None of this project's migrations ever explicitly
-- revoked that default, so a full audit (has_function_privilege
-- against 'public') found 57 functions still reachable this way --
-- this is what caught the write_audit_log() gap fixed in P1.7.
--
-- Categorized:
--   1. Trigger functions -- PostgreSQL refuses to invoke these
--      directly under any role ("trigger functions can only be
--      called as triggers"), so the PUBLIC grant is inert. Revoked
--      for hygiene only, no re-grant needed.
--   2. resolve_system_account() -- confirmed via grep, never called
--      directly by the frontend (only internally by other
--      functions, which run as the function owner regardless of
--      this grant). Same class as assert_user_posting_period_open/
--      next_structured_account_code fixed earlier today: revoked
--      entirely, no re-grant.
--   3. check_rate_limit/log_rate_limit -- must stay reachable by
--      anon (pre-login rate limiting has no auth.uid() yet).
--   4. Everything else -- real app RPCs (and the RLS-policy helper
--      functions get_my_role/get_workspace_owner/can_access_workspace/
--      is_org_member/has_org_role -- these are called FROM WITHIN
--      RLS policy expressions themselves, evaluated as the querying
--      role, so authenticated MUST keep execute on these or every
--      query against a table with such a policy would break).
--      Revoked from PUBLIC, re-granted explicitly to authenticated.
-- ============================================================

-- 1. Trigger functions: revoke only, no re-grant possible or needed.
revoke execute on function
  enforce_voucher_period_lock(),
  protect_account_structure(),
  protect_document_payment_summary(),
  protect_inventory_valuation(),
  trg_account_deactivate_audit(),
  trg_party_create_audit(),
  trg_voucher_void_audit(),
  validate_account_hierarchy(),
  validate_document_vat_treatment(),
  validate_payment_allocation(),
  normalize_stage2_document_status()
from public;

-- 2. Internal-only helper: revoke entirely (public, authenticated, anon).
revoke execute on function resolve_system_account(text) from public, authenticated, anon;

-- 3 & 4. Everything else: revoke the default PUBLIC grant.
revoke execute on function
  accept_invite(text),
  allocate_number(uuid,uuid,text),
  backfill_post_existing(),
  can_access_workspace(uuid),
  check_rate_limit(text,text),
  complete_onboarding(text,text,text,text,text,text,text),
  create_contact(text,text,boolean,boolean,text,text,text,text,text,text,text,integer,boolean,numeric,text,numeric,text),
  create_item(text,text,text,text,text,uuid,text,text,numeric,numeric,uuid,numeric,numeric,uuid,uuid,boolean,numeric,numeric,numeric,text,date,text),
  create_item_category(text,text,uuid,text),
  create_organization(text,text,boolean,text,text,text,date,date),
  create_tds_entry(date,text,text,text,text,uuid,numeric,numeric,text,text,text),
  get_my_role(),
  get_or_create_business_profile(),
  get_stock_valuation(),
  get_tax_rates(),
  get_workspace_owner(),
  has_org_role(uuid,text[]),
  invite_member(text,text),
  is_org_member(uuid),
  is_period_locked(date),
  list_my_team(),
  list_my_workspaces(),
  log_rate_limit(text,text,boolean),
  match_statement_line(uuid,uuid),
  next_bill_number(text),
  next_doc_number(text,text),
  next_invoice_number(text),
  next_voucher_number(text,text),
  post_journal_entry(uuid,uuid,date,text,text,uuid,jsonb),
  post_voucher(text,text,date,text,jsonb),
  reconcile_statement(uuid),
  remove_member(uuid),
  reverse_journal_entry(uuid,text),
  reverse_voucher(uuid,text),
  save_bill_draft(jsonb,jsonb,uuid),
  save_business_profile(text,text,text,text,text,text,text,text),
  save_invoice_draft(jsonb,jsonb,uuid),
  seed_default_accounts(),
  set_opening_balances(numeric,numeric,numeric,numeric,numeric),
  switch_workspace(uuid),
  unmatch_statement_line(uuid),
  update_contact(uuid,text,text,boolean,boolean,text,text,text,text,text,text,text,integer,boolean,numeric,text,boolean),
  update_item(uuid,text,text,text,text,text,uuid,text,text,numeric,numeric,uuid,numeric,numeric,uuid,uuid,boolean,numeric,text,boolean),
  void_manual_voucher(uuid,text)
from public;

-- Re-grant to authenticated (all of the above except the pre-auth pair).
grant execute on function
  accept_invite(text),
  allocate_number(uuid,uuid,text),
  backfill_post_existing(),
  can_access_workspace(uuid),
  complete_onboarding(text,text,text,text,text,text,text),
  create_contact(text,text,boolean,boolean,text,text,text,text,text,text,text,integer,boolean,numeric,text,numeric,text),
  create_item(text,text,text,text,text,uuid,text,text,numeric,numeric,uuid,numeric,numeric,uuid,uuid,boolean,numeric,numeric,numeric,text,date,text),
  create_item_category(text,text,uuid,text),
  create_organization(text,text,boolean,text,text,text,date,date),
  create_tds_entry(date,text,text,text,text,uuid,numeric,numeric,text,text,text),
  get_my_role(),
  get_or_create_business_profile(),
  get_stock_valuation(),
  get_tax_rates(),
  get_workspace_owner(),
  has_org_role(uuid,text[]),
  invite_member(text,text),
  is_org_member(uuid),
  is_period_locked(date),
  list_my_team(),
  list_my_workspaces(),
  match_statement_line(uuid,uuid),
  next_bill_number(text),
  next_doc_number(text,text),
  next_invoice_number(text),
  next_voucher_number(text,text),
  post_journal_entry(uuid,uuid,date,text,text,uuid,jsonb),
  post_voucher(text,text,date,text,jsonb),
  reconcile_statement(uuid),
  remove_member(uuid),
  reverse_journal_entry(uuid,text),
  reverse_voucher(uuid,text),
  save_bill_draft(jsonb,jsonb,uuid),
  save_business_profile(text,text,text,text,text,text,text,text),
  save_invoice_draft(jsonb,jsonb,uuid),
  seed_default_accounts(),
  set_opening_balances(numeric,numeric,numeric,numeric,numeric),
  switch_workspace(uuid),
  unmatch_statement_line(uuid),
  update_contact(uuid,text,text,boolean,boolean,text,text,text,text,text,text,text,integer,boolean,numeric,text,boolean),
  update_item(uuid,text,text,text,text,text,uuid,text,text,numeric,numeric,uuid,numeric,numeric,uuid,uuid,boolean,numeric,text,boolean),
  void_manual_voucher(uuid,text)
to authenticated;

-- Pre-auth pair: needs both authenticated and anon.
grant execute on function check_rate_limit(text,text), log_rate_limit(text,text,boolean)
  to authenticated, anon;
