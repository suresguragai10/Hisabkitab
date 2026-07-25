-- ============================================================
-- HisabKitab P2.13 -- Workspace-scoping fix, batch 6: Vouchers and
-- journal.
--
-- Part of the larger workspace-scoping remediation (see memory:
-- workspace_scoping_gap.md). Fetched live and fixed with the minimal,
-- mechanical change: the uid variable's source only (auth.uid() ->
-- get_workspace_owner()). No other logic touched.
--
-- reverse_journal_entry deliberately excluded: it operates on
-- journal_entries/organization_id/has_org_role, which belongs to the
-- old dead "Layer 3" org-rewrite architecture (confirmed unused --
-- no frontend reference anywhere), not this live user_id-based model.
-- ============================================================

create or replace function post_voucher(
  p_type text, p_fiscal_year text, p_date date, p_narration text, p_lines jsonb
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := get_workspace_owner();
  v_id uuid;
  v_num integer;
  tot_debit numeric(14,2);
  tot_credit numeric(14,2);
  invalid_line_count integer;
  foreign_account_count integer;
begin
  if uid is null then
    raise exception 'Not authenticated';
  end if;

  if p_type not in ('journal','payment','receipt','contra','sales','purchase') then
    raise exception 'Unsupported voucher type: %', p_type;
  end if;

  if p_fiscal_year is null or btrim(p_fiscal_year) = '' then
    raise exception 'Fiscal year is required';
  end if;

  if p_date is null then
    raise exception 'Voucher date is required';
  end if;

  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) < 2 then
    raise exception 'A voucher requires at least two lines';
  end if;

  select count(*)
    into invalid_line_count
    from jsonb_array_elements(p_lines) line
   where nullif(line->>'account_id', '') is null
      or coalesce((line->>'debit')::numeric, 0) < 0
      or coalesce((line->>'credit')::numeric, 0) < 0
      or (
        coalesce((line->>'debit')::numeric, 0) = 0
        and coalesce((line->>'credit')::numeric, 0) = 0
      )
      or (
        coalesce((line->>'debit')::numeric, 0) > 0
        and coalesce((line->>'credit')::numeric, 0) > 0
      );

  if invalid_line_count > 0 then
    raise exception 'Each voucher line must contain one account and either a positive debit or a positive credit';
  end if;

  select count(*)
    into foreign_account_count
    from jsonb_array_elements(p_lines) line
    left join accounts account
      on account.id = (line->>'account_id')::uuid
     and account.user_id = uid
     and account.is_active = true
   where account.id is null;

  if foreign_account_count > 0 then
    raise exception 'One or more voucher accounts are invalid, inactive, or do not belong to this business';
  end if;

  select
    coalesce(sum((line->>'debit')::numeric), 0),
    coalesce(sum((line->>'credit')::numeric), 0)
    into tot_debit, tot_credit
    from jsonb_array_elements(p_lines) line;

  if abs(tot_debit - tot_credit) > 0.005 then
    raise exception 'Voucher not balanced: debit % vs credit %', tot_debit, tot_credit;
  end if;

  if tot_debit <= 0 then
    raise exception 'Voucher amount must be greater than zero';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(uid::text || ':' || p_type || ':' || p_fiscal_year, 0)
  );

  select coalesce(max(voucher_number), 0) + 1
    into v_num
    from vouchers
   where user_id = uid
     and voucher_type = p_type
     and fiscal_year = p_fiscal_year;

  insert into vouchers (
    user_id,
    voucher_type,
    voucher_number,
    fiscal_year,
    voucher_date,
    narration
  ) values (
    uid,
    p_type,
    v_num,
    p_fiscal_year,
    p_date,
    nullif(btrim(p_narration), '')
  )
  returning id into v_id;

  insert into voucher_lines (
    voucher_id,
    account_id,
    debit,
    credit,
    description
  )
  select
    v_id,
    (line->>'account_id')::uuid,
    coalesce((line->>'debit')::numeric, 0),
    coalesce((line->>'credit')::numeric, 0),
    nullif(btrim(line->>'description'), '')
  from jsonb_array_elements(p_lines) line;

  return v_id;
end;
$$;

create or replace function void_manual_voucher(p_voucher_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := get_workspace_owner();
  affected_rows integer;
begin
  if uid is null then
    raise exception 'Not authenticated';
  end if;

  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'A void reason is required';
  end if;

  update vouchers
     set is_void = true,
         void_reason = left(btrim(p_reason), 500),
         voided_at = now(),
         updated_at = now()
   where id = p_voucher_id
     and user_id = uid
     and is_void = false
     and voucher_type in ('journal', 'payment', 'receipt', 'contra');

  get diagnostics affected_rows = row_count;
  if affected_rows = 0 then
    raise exception 'Voucher cannot be voided. It may not exist, may already be voided, or must be corrected from its source document.';
  end if;
end;
$$;

create or replace function post_opening_journal(p_fiscal_year text, p_date date, p_lines jsonb, p_notes text default null::text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid:=get_workspace_owner();
  v_batch uuid; v_voucher uuid; v_num integer;
  v_debit numeric; v_credit numeric; v_invalid integer;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  if p_fiscal_year is null or btrim(p_fiscal_year)='' then raise exception 'Fiscal year is required.'; end if;
  if p_date is null then raise exception 'Opening date is required.'; end if;
  if p_lines is null or jsonb_typeof(p_lines)<>'array' or jsonb_array_length(p_lines)<2 then
    raise exception 'Opening journal requires at least two lines.';
  end if;
  if exists(select 1 from opening_journals where user_id=uid and fiscal_year=p_fiscal_year) then
    raise exception 'An opening journal already exists for fiscal year %.',p_fiscal_year;
  end if;

  select count(*) into v_invalid
  from jsonb_array_elements(p_lines) l
  left join accounts a on a.id=(l->>'account_id')::uuid and a.user_id=uid and a.is_active
  where a.id is null
     or a.report_class in ('revenue','cost_of_sales','operating_expense','other_income','other_expense')
     or coalesce((l->>'debit')::numeric,0)<0
     or coalesce((l->>'credit')::numeric,0)<0
     or ((coalesce((l->>'debit')::numeric,0)>0)::integer + (coalesce((l->>'credit')::numeric,0)>0)::integer)<>1;
  if v_invalid>0 then raise exception 'Opening lines must use active balance-sheet accounts and one debit or credit per line.'; end if;

  select round(coalesce(sum((l->>'debit')::numeric),0),2),
         round(coalesce(sum((l->>'credit')::numeric),0),2)
    into v_debit,v_credit from jsonb_array_elements(p_lines) l;
  if v_debit<=0 or abs(v_debit-v_credit)>0.005 then
    raise exception 'Opening journal is not balanced: debit % credit %.',v_debit,v_credit;
  end if;

  perform pg_advisory_xact_lock(hashtextextended(uid::text || ':opening:' || p_fiscal_year,0));
  insert into opening_journals(user_id,fiscal_year,opening_date,notes)
  values(uid,p_fiscal_year,p_date,nullif(btrim(p_notes),'')) returning id into v_batch;
  select coalesce(max(voucher_number),0)+1 into v_num from vouchers
   where user_id=uid and voucher_type='opening' and fiscal_year=p_fiscal_year;
  insert into vouchers(user_id,voucher_type,voucher_number,fiscal_year,voucher_date,narration,source_document_type,source_document_id)
  values(uid,'opening',v_num,p_fiscal_year,p_date,coalesce(nullif(btrim(p_notes),''),'Opening balances'),'opening_journal',v_batch)
  returning id into v_voucher;
  insert into voucher_lines(voucher_id,account_id,debit,credit,description)
  select v_voucher,(l->>'account_id')::uuid,coalesce((l->>'debit')::numeric,0),coalesce((l->>'credit')::numeric,0),nullif(btrim(l->>'description'),'')
  from jsonb_array_elements(p_lines) l;
  update opening_journals set voucher_id=v_voucher where id=v_batch;
  perform write_audit_log('post','opening_journals',v_batch::text,null,
    jsonb_build_object('fiscal_year',p_fiscal_year,'voucher_id',v_voucher,'debit',v_debit));
  return v_voucher;
end;
$$;

create or replace function migrate_legacy_opening_balances(p_fiscal_year text, p_date date, p_offset_account_id uuid default null::uuid, p_notes text default 'Converted from legacy opening-balance fields'::text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid:=get_workspace_owner();
  v_lines jsonb; v_debit numeric; v_credit numeric; v_diff numeric; v_voucher uuid;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  select round(coalesce(sum(case when opening_balance_type='debit' then opening_balance else 0 end),0),2),
         round(coalesce(sum(case when opening_balance_type='credit' then opening_balance else 0 end),0),2)
    into v_debit,v_credit from accounts where user_id=uid and opening_balance>0;
  if v_debit+v_credit<=0 then raise exception 'No legacy opening balances found.'; end if;
  v_diff:=round(v_debit-v_credit,2);
  if abs(v_diff)>0.005 then
    if p_offset_account_id is null then
      raise exception 'Legacy openings differ by %. Select a balance-sheet offset account.',abs(v_diff);
    end if;
    if not exists(select 1 from accounts where id=p_offset_account_id and user_id=uid and is_active and report_class not in ('revenue','cost_of_sales','operating_expense','other_income','other_expense')) then
      raise exception 'Offset account is invalid.';
    end if;
  end if;

  select jsonb_agg(jsonb_build_object(
    'account_id',id,
    'debit',case when opening_balance_type='debit' then opening_balance else 0 end,
    'credit',case when opening_balance_type='credit' then opening_balance else 0 end,
    'description','Legacy opening balance'
  )) into v_lines
  from accounts where user_id=uid and opening_balance>0;

  if v_diff>0.005 then
    v_lines:=v_lines || jsonb_build_array(jsonb_build_object('account_id',p_offset_account_id,'debit',0,'credit',v_diff,'description','Opening balance offset'));
  elsif v_diff< -0.005 then
    v_lines:=v_lines || jsonb_build_array(jsonb_build_object('account_id',p_offset_account_id,'debit',-v_diff,'credit',0,'description','Opening balance offset'));
  end if;

  v_voucher:=post_opening_journal(p_fiscal_year,p_date,v_lines,p_notes);
  update accounts set opening_balance=0 where user_id=uid and opening_balance<>0;
  update opening_journals set is_legacy_conversion=true where voucher_id=v_voucher and user_id=uid;
  return v_voucher;
end;
$$;

create or replace function backfill_post_existing()
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := get_workspace_owner();
  r record;
  debtor_acct uuid;
  creditor_acct uuid;
  v_id uuid;
  n_inv integer := 0;
  n_bill integer := 0;
begin
  if uid is null then raise exception 'Not authenticated'; end if;

  for r in select * from invoices
            where user_id = uid and voucher_id is null and status <> 'cancelled'
  loop
    debtor_acct := null;
    if r.party_id is not null then
      select account_id into debtor_acct from parties where id = r.party_id and user_id = uid;
    end if;
    if debtor_acct is null then debtor_acct := resolve_system_account('ar_control'); end if;

    v_id := post_voucher('sales', r.fiscal_year, r.invoice_date,
      'Sales Invoice #' || r.invoice_number,
      jsonb_build_array(
        jsonb_build_object('account_id', debtor_acct, 'debit', r.total, 'credit', 0, 'description', r.party_name),
        jsonb_build_object('account_id', resolve_system_account('sales'), 'debit', 0, 'credit', r.subtotal, 'description', 'Sales'),
        jsonb_build_object('account_id', resolve_system_account('vat_payable'), 'debit', 0, 'credit', r.vat_amount, 'description', 'Output VAT 13%')
      ));
    update invoices set voucher_id = v_id where id = r.id;
    n_inv := n_inv + 1;
  end loop;

  for r in select * from purchase_bills
            where user_id = uid and voucher_id is null and status <> 'cancelled'
  loop
    creditor_acct := null;
    if r.vendor_id is not null then
      select account_id into creditor_acct from parties where id = r.vendor_id and user_id = uid;
    end if;
    if creditor_acct is null then creditor_acct := resolve_system_account('ap_control'); end if;

    v_id := post_voucher('purchase', r.fiscal_year, r.bill_date,
      'Purchase Bill #' || r.bill_number,
      jsonb_build_array(
        jsonb_build_object('account_id', resolve_system_account('purchase'), 'debit', r.subtotal, 'credit', 0, 'description', 'Purchase'),
        jsonb_build_object('account_id', resolve_system_account('vat_receivable'), 'debit', r.vat_amount, 'credit', 0, 'description', 'Input VAT 13%'),
        jsonb_build_object('account_id', creditor_acct, 'debit', 0, 'credit', r.total, 'description', r.vendor_name)
      ));
    update purchase_bills set voucher_id = v_id where id = r.id;
    n_bill := n_bill + 1;
  end loop;

  return format('Backfilled %s invoice(s) and %s bill(s).', n_inv, n_bill);
end;
$$;
