-- ============================================================
-- HisabKitab P2.0 — Revoke anon's default EXECUTE grant from every
-- function that doesn't genuinely need it.
--
-- A verification query after P1.8 showed nearly every function in
-- the public schema is executable by anon (unauthenticated
-- requests) -- not caused by today's fixes, but a pre-existing,
-- systemic default (consistent with how Supabase provisions new
-- projects: EXECUTE on new public-schema functions is granted to
-- anon/authenticated by default unless explicitly revoked).
--
-- Every function checked this session guards itself with an
-- `auth.uid() is null` check, so this was not silently exploitable
-- -- an anon call fails immediately inside the function. This is a
-- defense-in-depth fix, not a patch for active data exposure.
--
-- Rather than hand-list ~100 function signatures (error-prone --
-- P1.8 already missed one this way), this dynamically revokes anon
-- execute from every function that currently has it, except the two
-- that must keep it (pre-login rate limiting has no auth.uid() yet).
-- The trailing ALTER DEFAULT PRIVILEGES makes this the default for
-- any function created from now on, so this doesn't quietly recur.
-- ============================================================

do $$
declare
  r record;
begin
  for r in
    select p.oid::regprocedure as sig
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and has_function_privilege('anon', p.oid, 'execute')
      and p.proname not in ('check_rate_limit', 'log_rate_limit')
  loop
    begin
      execute format('revoke execute on function %s from anon;', r.sig);
    exception when others then
      raise notice 'Failed to revoke % from anon: %', r.sig, sqlerrm;
    end;
  end loop;
end $$;

alter default privileges in schema public revoke execute on functions from anon;
alter default privileges in schema public revoke execute on functions from public;
