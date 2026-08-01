-- Audit item 5.5: check_rate_limit/log_rate_limit trust the client-supplied
-- p_identifier verbatim, with no ownership check, and are callable by anon.
-- Anyone can pass someone else's email as p_identifier and either read their
-- lockout state or write fake failed-attempt rows, tripping the 5-in-15min
-- lockout against a person who never touched the login form themselves.
--
-- auth.uid() is genuinely unavailable here -- these calls happen BEFORE
-- supabase.auth.signInWithPassword/signInWithOtp resolves, so there is no
-- session yet (confirmed against src/App.jsx's Login flow; this matches the
-- existing comments in phaseP1_8 and phaseP2_0 explaining why these two
-- functions were deliberately kept anon-callable). So this fix scopes to
-- the one real server-derived signal that *is* available pre-auth: the
-- caller's source IP, read from the x-forwarded-for header Supabase's edge
-- sets on every PostgREST request (documented Supabase/PostgREST GUC --
-- inet_client_addr() would return the connection-pooler's internal IP
-- instead of the real client, so that's not used here).
--
-- Two independent tightenings, both fail-open if the IP header is ever
-- missing (never blocks legitimate login over a missing header):
--   1. p_action is now constrained to the two literal values the app
--      actually uses -- closes the "arbitrary action string" hole.
--   2. A coarser per-IP cap (20 failures / 15 min, across ALL identifiers
--      from that IP) sits alongside the existing per-identifier cap (5
--      failures / 15 min, unchanged). This directly blunts the new risk
--      this audit item identified -- one machine spraying failed attempts
--      across many different *other people's* identifiers -- without
--      requiring auth.uid(), which structurally doesn't exist yet at this
--      point in the flow.
-- Identifier spoofing itself (typing a real email that isn't yours) can't
-- be fully closed pre-authentication with the tools available in this
-- environment -- that's inherent to any pre-login rate limiter, not
-- specific to this schema. This narrows the blast radius rather than
-- claiming to eliminate it.

alter table rate_limit_log add column if not exists ip_address text;

create index if not exists idx_rate_limit_ip
  on rate_limit_log(ip_address, created_at desc)
  where ip_address is not null;

create or replace function check_rate_limit(p_identifier text, p_action text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  fail_count integer;
  ip_fail_count integer;
  caller_ip text;
begin
  if p_action not in ('login_attempt', 'otp_request') then
    raise exception 'Invalid rate-limit action.';
  end if;

  select count(*) into fail_count
  from rate_limit_log
  where identifier = p_identifier
    and action = p_action
    and success = false
    and created_at > now() - interval '15 minutes';

  if fail_count >= 5 then
    return false;
  end if;

  -- Only the header-parsing step gets its own guard -- a missing/malformed
  -- request.headers GUC must never block a real login, but it must also
  -- never accidentally swallow the "invalid action" rejection above.
  begin
    caller_ip := nullif(split_part(coalesce(current_setting('request.headers', true)::json->>'x-forwarded-for', ''), ',', 1), '');
  exception when others then
    caller_ip := null;
  end;

  if caller_ip is not null then
    select count(*) into ip_fail_count
    from rate_limit_log
    where ip_address = caller_ip
      and success = false
      and created_at > now() - interval '15 minutes';

    if ip_fail_count >= 20 then
      return false;
    end if;
  end if;

  return true;
end;
$$;

create or replace function log_rate_limit(p_identifier text, p_action text, p_success boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  caller_ip text;
begin
  if p_action not in ('login_attempt', 'otp_request') then
    raise exception 'Invalid rate-limit action.';
  end if;

  begin
    caller_ip := nullif(split_part(coalesce(current_setting('request.headers', true)::json->>'x-forwarded-for', ''), ',', 1), '');
  exception when others then
    caller_ip := null;
  end;

  insert into rate_limit_log (identifier, action, success, ip_address)
  values (p_identifier, p_action, p_success, caller_ip);

  -- Clean up entries older than 1 hour to keep table small
  delete from rate_limit_log
  where created_at < now() - interval '1 hour';
end;
$$;

comment on function check_rate_limit(text, text) is
  'Pre-auth rate limiter. Blocks on >=5 failures/15min per identifier (unchanged) OR >=20 failures/15min from the same source IP across any identifiers (new, audit 5.5) -- auth.uid() is unavailable at this point in the login flow by construction, so IP is the strongest server-derived signal available pre-authentication.';
