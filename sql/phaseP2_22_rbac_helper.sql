-- ============================================================
-- HisabKitab P2.22 -- RBAC helper: assert_role().
--
-- Right now every SECURITY DEFINER write function only checks "does
-- this person belong to this workspace" (get_workspace_owner()) --
-- never "is their ROLE allowed to do this specific action." The two
-- role-aware RLS policies that exist ("write accounts", "write
-- parties") are effectively dead: SECURITY DEFINER functions execute
-- as the function owner and bypass RLS entirely, so those checks
-- never actually run for any real write path in this app.
--
-- assert_role() is a single, reusable guard: every write function
-- that needs a role restriction adds one line,
-- `perform assert_role(array['owner','accountant']);`, right after
-- its existing `if uid is null then raise exception ...` check.
-- Keeps the same one-line-per-function mechanical pattern already
-- used for the workspace-scoping fix, rather than duplicating
-- if/raise logic in every function body.
-- ============================================================

create or replace function assert_role(p_allowed_roles text[])
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_role text := get_my_role();
begin
  if not (v_role = any(p_allowed_roles)) then
    raise exception 'Your role (%) does not have permission to perform this action.', v_role;
  end if;
end;
$$;

grant execute on function assert_role(text[]) to authenticated;
revoke all on function assert_role(text[]) from public, anon;
