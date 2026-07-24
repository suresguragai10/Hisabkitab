-- ============================================================
-- HisabKitab P1.3 — Close remaining direct-write gaps found by
-- the full-table grant audit (authenticated + anon, all public
-- base tables).
--
-- Real, currently-exploitable gaps:
--   * parties        -- INSERT bypasses create_contact()'s atomic
--                        creation of the matching ledger account,
--                        so a client could insert an account-less
--                        "customer" the rest of the app doesn't
--                        expect. (UPDATE/DELETE already have no
--                        policy at all, so those were already safe;
--                        tightened here anyway for defense in depth.)
--   * doc_sequences   -- its "own sequences" policy lets an
--                        authenticated user directly edit their own
--                        row, bypassing next_doc_number()'s atomic
--                        increment -- self-contained risk (their own
--                        invoice/bill numbering could collide or
--                        skip), not cross-tenant.
--
-- Everything else revoked here (audit_log, audit_events,
-- number_sequences, rate_limit_log, stage7_backup_*) was already
-- inert: RLS is enabled with no matching write policy (or, for the
-- stage7_backup_* / rate_limit_log tables, no policy at all), so
-- Postgres already denied these by default. Revoking the redundant
-- grant is just hygiene -- relying on "RLS happens to have no
-- policy" is fragile if a policy is ever added later without
-- re-checking the grant.
-- ============================================================

revoke insert, update, delete on parties from authenticated, anon;
revoke insert, update, delete on doc_sequences from authenticated, anon;
revoke insert, update, delete on audit_log from authenticated, anon;
revoke insert, update, delete on audit_events from authenticated, anon;
revoke insert, update, delete on number_sequences from authenticated, anon;
revoke insert, update, delete on rate_limit_log from authenticated, anon;
revoke insert, update, delete on stage7_backup_fiscal_periods from authenticated, anon;
revoke insert, update, delete on stage7_backup_tax_rates from authenticated, anon;

grant select on parties to authenticated;
