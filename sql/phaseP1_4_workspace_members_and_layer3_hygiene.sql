-- ============================================================
-- HisabKitab P1.4 — Close the workspace_members direct-write gap,
-- and lock down the unused Layer 3 (organization_id-based) tables
-- as hygiene.
--
-- workspace_members: TeamMembers.jsx only ever calls invite_member/
-- remove_member/accept_invite/list_my_team (all confirmed SECURITY
-- DEFINER). Its RLS policy scopes insert/update/delete to
-- owner_user_id = auth.uid(), so this was never cross-tenant
-- exploitable -- but direct table access lets an owner bypass the
-- token-based invite flow (e.g. add an arbitrary existing user to
-- their own workspace with any role, with none of the validation
-- invite_member/accept_invite do).
--
-- Layer 3 tables (organizations, organization_members,
-- organization_settings, journal_entries, journal_entry_lines,
-- v2_accounts, fiscal_years, accounting_periods) have zero rows and
-- zero frontend usage as of 2026-07-23 -- this is pure defense in
-- depth, not a live risk, but kept consistent with the "grant
-- should never be broader than what's actually used" rule applied
-- everywhere else in this audit.
-- ============================================================

revoke insert, update, delete on workspace_members from authenticated, anon;
grant select on workspace_members to authenticated;

revoke insert, update, delete on organizations from authenticated, anon;
revoke insert, update, delete on organization_members from authenticated, anon;
revoke insert, update, delete on organization_settings from authenticated, anon;
revoke insert, update, delete on journal_entries from authenticated, anon;
revoke insert, update, delete on journal_entry_lines from authenticated, anon;
revoke insert, update, delete on v2_accounts from authenticated, anon;
revoke insert, update, delete on fiscal_years from authenticated, anon;
revoke insert, update, delete on accounting_periods from authenticated, anon;
