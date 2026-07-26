-- ============================================================
-- HisabKitab P2.35 -- Close a real, live cross-tenant data leak
-- (audit item 5.6).
--
-- Postgres views without `security_invoker=true` check the
-- underlying tables' row-level security using the VIEW OWNER's
-- privileges, not the querying user's. All views in this project are
-- owned by `postgres`, which has rolbypassrls=true (confirmed live
-- 2026-07-26) -- so any view without security_invoker=true bypasses
-- RLS on its underlying tables ENTIRELY, regardless of what
-- auth.uid() would evaluate to, because the bypass happens at the
-- permission-checking layer before a policy's USING clause is even
-- consulted.
--
-- trial_balance already had security_invoker=true (fixed at some
-- earlier point, in phaseP0_5_structured_chart.sql). item_summary,
-- contact_summary, and inventory_valuation did not -- confirmed live
-- via pg_class.reloptions. This means, until this migration runs,
-- ANY authenticated user querying these three views sees EVERY
-- business's items/contacts/inventory valuation, not just their own.
--
-- Fix is minimal and additive: flip the option, no redefinition of
-- the view's SELECT logic needed.
-- ============================================================

alter view item_summary set (security_invoker = true);
alter view contact_summary set (security_invoker = true);
alter view inventory_valuation set (security_invoker = true);
