-- ============================================================
-- HisabKitab P2.4 — Merge one custom account into another.
--
-- Covers the common real-world mistake of creating two accounts for
-- the same thing (e.g. "Legal and Professional" and "Professional
-- Fee" as separate expense heads). Moves every posted voucher line
-- from the source account to the target, folds in any legacy
-- opening balance, then deletes the now-empty source account --
-- all in one step, self-service from the frontend from now on.
-- ============================================================

create or replace function merge_account(p_source_id uuid, p_target_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  src accounts%rowtype;
  tgt accounts%rowtype;
  v_count integer;
  v_signed numeric;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  if p_source_id = p_target_id then raise exception 'Cannot merge an account into itself.'; end if;

  select * into src from accounts where id = p_source_id and user_id = uid;
  if not found then raise exception 'Source account not found.'; end if;
  select * into tgt from accounts where id = p_target_id and user_id = uid;
  if not found then raise exception 'Target account not found.'; end if;

  if src.is_system_account or src.is_control_account or src.is_party_account then
    raise exception 'System, control and party accounts cannot be merged away.';
  end if;
  if not tgt.is_active then raise exception 'Target account is not active.'; end if;
  if src.report_class <> tgt.report_class or src.account_type <> tgt.account_type then
    raise exception 'Accounts must be the same type and report class to merge.';
  end if;
  if exists(select 1 from accounts where parent_account_id = p_source_id) then
    raise exception 'Move or delete child accounts of the source account first.';
  end if;

  update voucher_lines
     set account_id = p_target_id,
         description = nullif(btrim(coalesce(description,'') || ' (merged from ' || src.name || ')'), '')
   where account_id = p_source_id;
  get diagnostics v_count = row_count;

  -- Fold any legacy opening balance into the target, preserving sign.
  v_signed := (case when tgt.opening_balance_type='debit' then tgt.opening_balance else -tgt.opening_balance end)
            + (case when src.opening_balance_type='debit' then src.opening_balance else -src.opening_balance end);
  update accounts
     set opening_balance = abs(v_signed),
         opening_balance_type = case when v_signed >= 0 then 'debit' else 'credit' end
   where id = p_target_id and user_id = uid;

  delete from accounts where id = p_source_id and user_id = uid;

  perform write_audit_log('merge','accounts',p_source_id::text,to_jsonb(src),
    jsonb_build_object('merged_into', p_target_id, 'lines_moved', v_count));
end;
$$;

revoke all on function merge_account(uuid, uuid) from public;
grant execute on function merge_account(uuid, uuid) to authenticated;
