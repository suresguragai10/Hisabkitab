-- ============================================================
-- HisabKitab P1.9 — Fix a gap missed in P1.8's PUBLIC-grant sweep.
--
-- post_closing_stock() was in the original 57-function list of
-- functions still reachable via the PUBLIC default grant, but was
-- left out of phaseP1_8's revoke/re-grant lists by mistake. It's a
-- legitimate, properly-scoped feature (checks auth.uid(), validates
-- a positive amount, respects period locks) that just isn't wired to
-- any frontend page yet -- same category as the other real app RPCs
-- in P1.8, not an internal-only helper.
-- ============================================================

revoke execute on function post_closing_stock(date, numeric, text, text) from public;
grant execute on function post_closing_stock(date, numeric, text, text) to authenticated;
