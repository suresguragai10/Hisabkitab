-- ============================================================
-- HisabKitab P1.2 — Delete/archive for custom Chart of Accounts
-- ledger accounts.
--
-- Before this: an account could only ever be "deactivated", and
-- protect_account_structure() blocked that outright the moment an
-- account had even one ledger entry -- regardless of whether those
-- entries net to zero. There was also no delete path at all, so
-- accidental duplicate/misclassified custom accounts (created by a
-- customer, not the system) could never be cleaned up from the
-- frontend.
--
-- New rule for regular (non-system, non-control, non-party)
-- accounts:
--   * never used (no voucher_lines)          -> delete_structured_account
--   * used, but nets to a zero balance        -> deactivate_structured_account (archive)
--   * used, non-zero balance                  -> blocked either way
-- System/control/party accounts are unaffected -- they still can't
-- be deactivated or deleted here. Party archiving already has its
-- own correct path via parties.is_active (update_contact), untouched
-- by this change.
-- ============================================================

create or replace function protect_account_structure()
returns trigger
set search_path = public
as $$
declare
  v_has_entries boolean;
  v_has_children boolean;
  v_balance numeric;
begin
  if new.user_id is distinct from old.user_id then
    raise exception 'Account owner is immutable.';
  end if;

  select exists(select 1 from voucher_lines where account_id=old.id) into v_has_entries;

  if v_has_entries and (
       new.account_type is distinct from old.account_type
    or new.report_class is distinct from old.report_class
    or new.normal_balance is distinct from old.normal_balance
  ) then
    raise exception 'Account type, report class and normal balance cannot change after posting.';
  end if;

  if old.is_system_account and (
       new.account_code is distinct from old.account_code
    or new.account_type is distinct from old.account_type
    or new.report_class is distinct from old.report_class
    or new.account_subtype is distinct from old.account_subtype
    or new.normal_balance is distinct from old.normal_balance
    or new.is_system_account is distinct from old.is_system_account
    or new.is_control_account is distinct from old.is_control_account
  ) then
    raise exception 'System-account structure is protected.';
  end if;

  if old.is_active and not new.is_active then
    if old.is_system_account or old.is_control_account or old.is_party_account then
      raise exception 'System, control and party accounts cannot be deactivated here.';
    end if;

    if v_has_entries then
      select round(
        (case when old.opening_balance_type='debit' then old.opening_balance else -old.opening_balance end)
        + coalesce(sum(case when v.is_void=false then vl.debit-vl.credit else 0 end),0)
      ,2)
      into v_balance
      from voucher_lines vl join vouchers v on v.id=vl.voucher_id
      where vl.account_id=old.id;

      if abs(coalesce(v_balance,0)) > 0.005 then
        raise exception 'Account has a non-zero balance of %. Clear or transfer the balance before archiving.', v_balance;
      end if;
    end if;

    select exists(select 1 from accounts where parent_account_id=old.id and is_active) into v_has_children;
    if v_has_children then raise exception 'Deactivate or move child accounts first.'; end if;
  end if;

  new.updated_at := now();
  return new;
end;
$$ language plpgsql;

create or replace function delete_structured_account(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  acct accounts%rowtype;
  v_has_entries boolean;
  v_has_children boolean;
begin
  if uid is null then raise exception 'Not authenticated'; end if;

  select * into acct from accounts where id=p_id and user_id=uid;
  if not found then raise exception 'Account not found.'; end if;

  if acct.is_system_account or acct.is_control_account or acct.is_party_account then
    raise exception 'System, control and party accounts cannot be deleted.';
  end if;

  select exists(select 1 from voucher_lines where account_id=p_id) into v_has_entries;
  if v_has_entries then
    raise exception 'This account has ledger entries and cannot be deleted. Archive it instead if its balance is zero.';
  end if;

  select exists(select 1 from accounts where parent_account_id=p_id) into v_has_children;
  if v_has_children then raise exception 'Move or delete child accounts first.'; end if;

  delete from accounts where id=p_id and user_id=uid;

  perform write_audit_log('delete','accounts',p_id::text,to_jsonb(acct),null);
end;
$$;

revoke all on function delete_structured_account(uuid) from public;
grant execute on function delete_structured_account(uuid) to authenticated;
