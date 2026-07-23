-- ============================================================
-- HisabKitab P0.9 — Close the direct-write gap on business_profile
-- and user_workspace_pref, confirmed safe via a code check:
--
--   * business_profile: all reads/writes in the app already go
--     through get_or_create_business_profile() / save_business_profile()
--     (src/lib/businessProfile.js). The only direct table access
--     anywhere in the frontend is a read-only SELECT in App.jsx.
--
--   * user_workspace_pref: the app only ever reads this table
--     directly (src/lib/workspace.js). Every write already goes
--     through switch_workspace() / accept_invite(), both
--     SECURITY DEFINER and unaffected by this revoke.
--
-- item_categories and bank_statements/bank_statement_lines are
-- deliberately NOT included here -- those still have a genuine
-- direct-write dependency in the frontend and need a proper
-- function written first, before their grants can be closed.
-- ============================================================

grant select on business_profile to authenticated;
revoke insert, update, delete on business_profile from authenticated;

grant select on user_workspace_pref to authenticated;
revoke insert, update, delete on user_workspace_pref from authenticated;
