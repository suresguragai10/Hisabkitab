-- ============================================================
-- HisabKitab P1.5 — Fix invite_member()'s broken token generation.
--
-- Both workspace_members.invite_token's column default and
-- invite_member()'s own ON CONFLICT branch call gen_random_bytes()
-- unqualified. That function lives in the `extensions` schema on
-- this project (confirmed via pg_extension), not `public` -- and
-- invite_member() pins search_path to just 'public', so every call
-- to gen_random_bytes() has always failed with
-- "function gen_random_bytes(integer) does not exist". This means
-- the team-invite feature has never actually worked end to end
-- before now; it was only just exercised for the first time while
-- testing the workspace_members grant fix.
-- ============================================================

alter table workspace_members
  alter column invite_token set default encode(extensions.gen_random_bytes(24), 'hex'::text);

create or replace function invite_member(p_email text, p_role text)
returns text
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  uid   uuid := auth.uid();
  token text;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  if p_role not in ('accountant','staff','viewer') then
    raise exception 'Invalid role. Use: accountant, staff, or viewer';
  end if;
  if p_email = (select email from auth.users where id = uid) then
    raise exception 'You cannot invite yourself';
  end if;

  insert into workspace_members (owner_user_id, member_email, role)
  values (uid, lower(trim(p_email)), p_role)
  on conflict (owner_user_id, member_email) do update
    set role   = excluded.role,
        status = 'pending',
        invite_token = encode(extensions.gen_random_bytes(24),'hex'),
        invited_at   = now()
  returning invite_token into token;

  return token;
end;
$$;
