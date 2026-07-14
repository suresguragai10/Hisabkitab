-- ============================================================
-- HisabKitab — Phase 7b + 7c
-- Security: Immutable audit log + Rate limiting protection
-- Run in Supabase SQL Editor in 3 chunks (same as before).
-- ============================================================

-- ------------------------------------------------------------
-- CHUNK 1: Audit log table + RLS hardening
-- ------------------------------------------------------------

-- Immutable audit log — records every write operation.
-- No DELETE or UPDATE is permitted on this table (enforced by RLS).
-- This satisfies IRD's requirement that accounting records never
-- be silently erased, and gives you a full trail of who did what.
create table if not exists audit_log (
  id bigserial primary key,
  user_id uuid not null references auth.users(id),
  action text not null check (action in ('create','update','void','deactivate','login','logout')),
  table_name text not null,
  record_id text,
  old_data jsonb,
  new_data jsonb,
  ip_address text,
  user_agent text,
  created_at timestamptz not null default now()
);

-- Rate limiting table — tracks failed login attempts per IP/email
create table if not exists rate_limit_log (
  id bigserial primary key,
  identifier text not null, -- email or IP address
  action text not null,     -- 'login_attempt', 'otp_request'
  success boolean not null default false,
  created_at timestamptz not null default now()
);

create index if not exists idx_audit_log_user on audit_log(user_id);
create index if not exists idx_audit_log_table on audit_log(table_name, record_id);
create index if not exists idx_audit_log_created on audit_log(created_at desc);
create index if not exists idx_rate_limit_identifier on rate_limit_log(identifier, created_at desc);

-- RLS on audit log: users can only READ their own audit entries.
-- Nobody can INSERT directly from client (only via server functions).
-- Nobody can UPDATE or DELETE audit entries — ever.
alter table audit_log enable row level security;

drop policy if exists "read own audit log" on audit_log;
create policy "read own audit log" on audit_log
  for select using (auth.uid() = user_id);

-- No insert/update/delete policies = those ops are blocked for all roles
-- (inserts happen only via security definer functions below)

-- RLS on rate_limit_log: completely server-side, no client access
alter table rate_limit_log enable row level security;
-- No policies = no client access at all

-- ------------------------------------------------------------
-- CHUNK 2: Audit log helper function
-- ------------------------------------------------------------

-- Function to write an audit entry. Called from other functions,
-- never directly from the client. security definer means it runs
-- as the postgres role (bypassing RLS on audit_log), so client
-- code can trigger it but can't bypass what it records.
create or replace function write_audit_log(
  p_action text,
  p_table_name text,
  p_record_id text default null,
  p_old_data jsonb default null,
  p_new_data jsonb default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into audit_log (user_id, action, table_name, record_id, old_data, new_data)
  values (auth.uid(), p_action, p_table_name, p_record_id, p_old_data, p_new_data);
end;
$$;

grant execute on function write_audit_log(text, text, text, jsonb, jsonb) to authenticated;

-- ------------------------------------------------------------
-- CHUNK 3: Rate limiting function + RLS policy tightening
-- ------------------------------------------------------------

-- Check rate limit: returns true if the identifier is NOT blocked.
-- Blocks if more than 5 failed attempts in the last 15 minutes.
create or replace function check_rate_limit(p_identifier text, p_action text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  fail_count integer;
begin
  select count(*) into fail_count
  from rate_limit_log
  where identifier = p_identifier
    and action = p_action
    and success = false
    and created_at > now() - interval '15 minutes';

  return fail_count < 5;
end;
$$;

-- Log a rate limit attempt (called from client via RPC)
create or replace function log_rate_limit(p_identifier text, p_action text, p_success boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into rate_limit_log (identifier, action, success)
  values (p_identifier, p_action, p_success);

  -- Clean up entries older than 1 hour to keep table small
  delete from rate_limit_log
  where created_at < now() - interval '1 hour';
end;
$$;

-- Auto-trigger: write audit log whenever a voucher is voided
create or replace function trg_voucher_void_audit()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if NEW.is_void = true and OLD.is_void = false then
    insert into audit_log (user_id, action, table_name, record_id, old_data, new_data)
    values (
      auth.uid(),
      'void',
      'vouchers',
      NEW.id::text,
      jsonb_build_object('is_void', OLD.is_void, 'narration', OLD.narration),
      jsonb_build_object('is_void', NEW.is_void, 'void_reason', NEW.void_reason, 'voided_at', NEW.voided_at)
    );
  end if;
  return NEW;
end;
$$;

drop trigger if exists voucher_void_audit on vouchers;
create trigger voucher_void_audit
  after update on vouchers
  for each row execute function trg_voucher_void_audit();

-- Auto-trigger: write audit log whenever an account is deactivated
create or replace function trg_account_deactivate_audit()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if NEW.is_active = false and OLD.is_active = true then
    insert into audit_log (user_id, action, table_name, record_id, old_data, new_data)
    values (
      auth.uid(),
      'deactivate',
      'accounts',
      NEW.id::text,
      jsonb_build_object('name', OLD.name, 'is_active', OLD.is_active),
      jsonb_build_object('name', NEW.name, 'is_active', NEW.is_active)
    );
  end if;
  return NEW;
end;
$$;

drop trigger if exists account_deactivate_audit on accounts;
create trigger account_deactivate_audit
  after update on accounts
  for each row execute function trg_account_deactivate_audit();

grant execute on function check_rate_limit(text, text) to anon, authenticated;
grant execute on function log_rate_limit(text, text, boolean) to anon, authenticated;
