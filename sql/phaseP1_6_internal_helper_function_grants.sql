-- ============================================================
-- HisabKitab P1.6 — Revoke direct client access to internal helper
-- functions that take p_user_id as a plain parameter instead of
-- deriving it from auth.uid().
--
-- assert_user_posting_period_open() and next_structured_account_code()
-- are only ever meant to be called internally by other functions/
-- triggers (enforce_voucher_period_lock, resolve_system_account,
-- create_structured_account), which run as the function owner and
-- so are unaffected by this revoke. Confirmed via grep: no frontend
-- code calls either directly.
--
-- Before this, any authenticated user of ANY business could call
-- either function directly with an arbitrary p_user_id belonging to
-- a different business, and learn things like whether that
-- business's fiscal year is closed, whether a specific date/period
-- is locked, or the next account-code sequence number that business
-- would get. Minor severity (no financial figures leaked), but a
-- real cross-tenant information leak -- one business should learn
-- nothing about another's existence or configuration.
-- ============================================================

revoke execute on function assert_user_posting_period_open(uuid, date, text, text) from authenticated, anon;
revoke execute on function next_structured_account_code(uuid, text, text) from authenticated, anon;
