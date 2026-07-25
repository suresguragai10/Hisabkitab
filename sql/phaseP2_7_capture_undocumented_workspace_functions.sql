-- ============================================================
-- HisabKitab P2.7 -- Reproducibility baseline: capture live functions
-- that existed only in the deployed database, never in source control.
--
-- Found during an independent audit cross-check (2026-07-25): these
-- functions were flagged as "missing" by a static repo review. They
-- all exist live and are correctly grant-restricted (verified: not
-- executable by anon/public, only authenticated) -- so the audit's
-- security conclusion was wrong, but its underlying point was fair:
-- the repository could not previously rebuild these from source. This
-- file closes that gap by committing their exact live definitions
-- verbatim (no behavior change).
--
-- (create_tds_entry, get_tax_rates, file_vat_return, create_fiscal_periods,
-- list_fiscal_periods, list_vat_returns, prepare_vat_return, remit_tds
-- and set_period_lock are captured separately in
-- phaseP2_6_workspace_scoping_and_tax_overloads.sql, since those needed
-- an actual fix rather than a verbatim copy.)
-- ============================================================

create or replace function accept_invite(p_token text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  uid     uuid := auth.uid();
  rec     workspace_members%rowtype;
  biz_name text;
begin
  if uid is null then raise exception 'Not authenticated'; end if;

  select * into rec from workspace_members
   where invite_token = p_token and status = 'pending';

  if not found then
    raise exception 'Invite link is invalid or has already been used.';
  end if;

  if rec.member_email != lower((select email from auth.users where id = uid)) then
    raise exception 'This invite was sent to a different email address.';
  end if;

  update workspace_members
     set member_user_id = uid,
         status         = 'active',
         invite_token   = null,
         joined_at      = now()
   where id = rec.id;

  insert into user_workspace_pref (user_id, active_workspace)
  values (uid, rec.owner_user_id)
  on conflict (user_id) do update set active_workspace = rec.owner_user_id;

  select coalesce(biz_name, 'the workspace') into biz_name
    from business_profile where user_id = rec.owner_user_id;

  return coalesce(biz_name, 'the workspace');
end;
$$;

create or replace function complete_onboarding(p_biz_name text, p_biz_name_np text, p_address text, p_city text, p_pan_vat text, p_phone text, p_biz_type text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  insert into business_profile
    (user_id, biz_name, biz_name_np, address, city, pan_vat, phone, business_type, onboarding_completed)
  values
    (uid, p_biz_name, p_biz_name_np, p_address, p_city, p_pan_vat, p_phone, p_biz_type, true)
  on conflict (user_id) do update set
    biz_name             = excluded.biz_name,
    biz_name_np          = excluded.biz_name_np,
    address              = excluded.address,
    city                 = excluded.city,
    pan_vat              = excluded.pan_vat,
    phone                = excluded.phone,
    business_type        = excluded.business_type,
    onboarding_completed = true,
    updated_at           = now();
end; $$;

create or replace function get_my_role()
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  owner_id uuid := get_workspace_owner();
  v_role   text;
begin
  if owner_id = auth.uid() then return 'owner'; end if;
  select role into v_role from workspace_members
   where owner_user_id = owner_id
     and member_user_id = auth.uid()
     and status = 'active';
  return coalesce(v_role, 'viewer');
end;
$$;

create or replace function list_my_team()
returns table(id uuid, member_email text, member_user_id uuid, role text, status text, joined_at timestamptz)
language sql
stable
security definer
set search_path = public
as $$
  select id, member_email, member_user_id, role, status, joined_at
    from workspace_members
   where owner_user_id = auth.uid() and status != 'removed'
   order by invited_at;
$$;

create or replace function list_my_workspaces()
returns table(owner_user_id uuid, biz_name text, role text)
language sql
stable
security definer
set search_path = public
as $$
  select wm.owner_user_id,
         coalesce(bp.biz_name, 'Business ' || left(wm.owner_user_id::text, 8)) as biz_name,
         wm.role
    from workspace_members wm
    left join business_profile bp on bp.user_id = wm.owner_user_id
   where wm.member_user_id = auth.uid() and wm.status = 'active';
$$;

create or replace function match_statement_line(p_line_id uuid, p_voucher_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$ begin update bank_statement_lines set matched_voucher_id = p_voucher_id, is_matched = true where id = p_line_id and user_id = get_workspace_owner(); end; $$;

create or replace function reconcile_statement(p_statement_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$ begin update bank_statements set status = 'reconciled' where id = p_statement_id and user_id = get_workspace_owner(); end; $$;

create or replace function remove_member(p_member_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  update workspace_members
     set status = 'removed'
   where owner_user_id = uid and member_user_id = p_member_user_id;
  update user_workspace_pref
     set active_workspace = null
   where user_id = p_member_user_id and active_workspace = uid;
end;
$$;

create or replace function switch_workspace(p_owner_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'Not authenticated'; end if;

  if p_owner_id is not null and p_owner_id != uid then
    if not exists (
      select 1 from workspace_members
       where owner_user_id = p_owner_id and member_user_id = uid and status = 'active'
    ) then
      raise exception 'You do not have access to this workspace';
    end if;
  end if;

  insert into user_workspace_pref (user_id, active_workspace)
  values (uid, case when p_owner_id = uid then null else p_owner_id end)
  on conflict (user_id) do update
    set active_workspace = case when p_owner_id = uid then null else p_owner_id end;
end;
$$;

create or replace function unmatch_statement_line(p_line_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$ begin update bank_statement_lines set matched_voucher_id = null, is_matched = false where id = p_line_id and user_id = get_workspace_owner(); end; $$;

grant execute on function accept_invite(text) to authenticated;
grant execute on function complete_onboarding(text,text,text,text,text,text,text) to authenticated;
grant execute on function get_my_role() to authenticated;
grant execute on function list_my_team() to authenticated;
grant execute on function list_my_workspaces() to authenticated;
grant execute on function match_statement_line(uuid,uuid) to authenticated;
grant execute on function reconcile_statement(uuid) to authenticated;
grant execute on function remove_member(uuid) to authenticated;
grant execute on function switch_workspace(uuid) to authenticated;
grant execute on function unmatch_statement_line(uuid) to authenticated;
revoke all on function accept_invite(text) from public, anon;
revoke all on function complete_onboarding(text,text,text,text,text,text,text) from public, anon;
revoke all on function get_my_role() from public, anon;
revoke all on function list_my_team() from public, anon;
revoke all on function list_my_workspaces() from public, anon;
revoke all on function match_statement_line(uuid,uuid) from public, anon;
revoke all on function reconcile_statement(uuid) from public, anon;
revoke all on function remove_member(uuid) from public, anon;
revoke all on function switch_workspace(uuid) from public, anon;
revoke all on function unmatch_statement_line(uuid) from public, anon;
