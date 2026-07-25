-- ============================================================
-- HisabKitab P2.23 -- RBAC batch 1: owner-only actions.
--
-- Structural chart-of-accounts changes, core business settings, and
-- fiscal year close are the most sensitive/irreversible actions in
-- the app -- owner only, matching the independent audit's suggested
-- model ("Owner: All configuration ... Cannot alter immutable posted
-- history" / accountant "Cannot manage ownership/security").
--
-- Each function gets exactly one added line,
-- perform assert_role(array['owner']);, right after the existing
-- "not authenticated" check. Nothing else changes.
-- ============================================================

create or replace function create_structured_account(p_name text, p_account_code text, p_account_type text, p_report_class text, p_account_subtype text default 'general'::text, p_normal_balance text default null::text, p_parent_account_id uuid default null::uuid, p_cash_flow_category text default 'operating'::text, p_allow_manual_posting boolean default true)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid:=get_workspace_owner();
  v_id uuid;
  v_code text;
  v_normal text;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  perform assert_role(array['owner']);
  if p_name is null or btrim(p_name)='' then raise exception 'Account name is required.'; end if;
  v_normal:=coalesce(p_normal_balance,case when p_account_type in ('asset','expense') then 'debit' else 'credit' end);
  v_code:=coalesce(nullif(btrim(p_account_code),''),next_structured_account_code(uid,p_report_class,null));

  insert into accounts(
    user_id,name,account_code,account_type,group_name,parent_account_id,
    report_class,account_subtype,normal_balance,cash_flow_category,
    is_party_account,is_control_account,is_system_account,allow_manual_posting,
    opening_balance,opening_balance_type,is_active
  ) values (
    uid,btrim(p_name),v_code,p_account_type,replace(initcap(replace(p_report_class,'_',' ')),' And ',' & '),p_parent_account_id,
    p_report_class,coalesce(nullif(btrim(p_account_subtype),''),'general'),v_normal,p_cash_flow_category,
    false,false,false,coalesce(p_allow_manual_posting,true),0,v_normal,true
  ) returning id into v_id;

  perform write_audit_log('create','accounts',v_id::text,null,
    jsonb_build_object('account_code',v_code,'name',btrim(p_name),'report_class',p_report_class));
  return v_id;
end;
$$;

create or replace function update_structured_account(p_id uuid, p_name text, p_account_code text, p_account_type text, p_report_class text, p_account_subtype text, p_normal_balance text, p_parent_account_id uuid, p_cash_flow_category text, p_allow_manual_posting boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare uid uuid:=get_workspace_owner(); v_old accounts%rowtype;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  perform assert_role(array['owner']);
  if p_name is null or btrim(p_name)='' then raise exception 'Account name is required.'; end if;
  if p_account_code is null or btrim(p_account_code)='' then raise exception 'Account code is required.'; end if;
  select * into v_old from accounts where id=p_id and user_id=uid for update;
  if not found then raise exception 'Account not found.'; end if;
  if v_old.is_system_account then raise exception 'System accounts cannot be edited from the Chart of Accounts.'; end if;
  update accounts set
    name=btrim(p_name), account_code=btrim(p_account_code), account_type=p_account_type,
    report_class=p_report_class, group_name=replace(initcap(replace(p_report_class,'_',' ')),' And ',' & '),
    account_subtype=coalesce(nullif(btrim(p_account_subtype),''),'general'), normal_balance=p_normal_balance,
    parent_account_id=p_parent_account_id, cash_flow_category=p_cash_flow_category,
    allow_manual_posting=coalesce(p_allow_manual_posting,true)
  where id=p_id and user_id=uid;
  perform write_audit_log('update','accounts',p_id::text,to_jsonb(v_old),
    jsonb_build_object('account_code',p_account_code,'name',p_name,'report_class',p_report_class));
end;
$$;

create or replace function deactivate_structured_account(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare uid uuid:=get_workspace_owner();
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  perform assert_role(array['owner']);
  update accounts set is_active=false where id=p_id and user_id=uid;
  if not found then raise exception 'Account not found.'; end if;
  perform write_audit_log('deactivate','accounts',p_id::text,null,null);
end;
$$;

create or replace function delete_structured_account(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := get_workspace_owner();
  acct accounts%rowtype;
  v_has_entries boolean;
  v_has_children boolean;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  perform assert_role(array['owner']);

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

create or replace function merge_account(p_source_id uuid, p_target_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := get_workspace_owner();
  src accounts%rowtype;
  tgt accounts%rowtype;
  v_count integer;
  v_signed numeric;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  perform assert_role(array['owner']);
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

create or replace function seed_default_accounts()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare uid uuid:=get_workspace_owner();
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  perform assert_role(array['owner']);
  perform resolve_system_account('cash'); perform resolve_system_account('bank'); perform resolve_system_account('sales');
  perform resolve_system_account('purchase'); perform resolve_system_account('vat_payable'); perform resolve_system_account('vat_receivable');
  perform resolve_system_account('ar_control'); perform resolve_system_account('ap_control'); perform resolve_system_account('inventory_asset');
  perform resolve_system_account('cogs'); perform resolve_system_account('tds_payable'); perform resolve_system_account('retained_earnings');
  if not exists(select 1 from accounts where user_id=uid and account_subtype='capital') then
    perform create_structured_account('Capital Account','3000','equity','equity','capital','credit',null,'financing',true);
  end if;
  if not exists(select 1 from accounts where user_id=uid and account_subtype='drawings') then
    perform create_structured_account('Drawings','3010','equity','equity','drawings','debit',null,'financing',true);
  end if;
end; $$;

create or replace function save_business_profile(p_biz_name text default ''::text, p_biz_name_np text default ''::text, p_address text default ''::text, p_city text default ''::text, p_pan_vat text default ''::text, p_phone text default ''::text, p_email text default ''::text, p_invoice_prefix text default ''::text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare uid uuid := get_workspace_owner();
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  perform assert_role(array['owner']);
  insert into business_profile
    (user_id, biz_name, biz_name_np, address, city, pan_vat, phone, email, invoice_prefix)
  values
    (uid, p_biz_name, p_biz_name_np, p_address, p_city, p_pan_vat, p_phone, p_email, p_invoice_prefix)
  on conflict (user_id) do update set
    biz_name        = excluded.biz_name,
    biz_name_np     = excluded.biz_name_np,
    address         = excluded.address,
    city            = excluded.city,
    pan_vat         = excluded.pan_vat,
    phone           = excluded.phone,
    email           = excluded.email,
    invoice_prefix  = excluded.invoice_prefix,
    updated_at      = now();
end; $$;

create or replace function save_compliance_settings(p_vat_due_day integer, p_tds_due_day integer, p_require_pan_for_tds boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare uid uuid:=get_workspace_owner();
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  perform assert_role(array['owner']);
  if p_vat_due_day not between 1 and 31 or p_tds_due_day not between 1 and 31 then raise exception 'Due days must be 1 to 31.'; end if;
  insert into tax_compliance_settings(user_id,vat_due_day,tds_due_day,require_pan_for_tds,updated_at)
  values(uid,p_vat_due_day,p_tds_due_day,coalesce(p_require_pan_for_tds,false),now())
  on conflict(user_id) do update set vat_due_day=excluded.vat_due_day,tds_due_day=excluded.tds_due_day,
    require_pan_for_tds=excluded.require_pan_for_tds,updated_at=now();
  perform write_audit_log('configure','tax_compliance_settings',uid::text,null,jsonb_build_object('vat_due_day',p_vat_due_day,'tds_due_day',p_tds_due_day));
end; $$;

create or replace function save_tax_rate(p_rate_type text, p_transaction_type text, p_label text, p_rate numeric, p_effective_from date, p_effective_to date default null::date, p_vat_treatment text default null::text, p_legal_reference text default null::text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare uid uuid:=get_workspace_owner(); v_id uuid;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  perform assert_role(array['owner']);
  if p_rate_type not in ('vat','tds') then raise exception 'Invalid tax rate type.'; end if;
  if nullif(btrim(p_transaction_type),'') is null or nullif(btrim(p_label),'') is null then
    raise exception 'Transaction type and label are required.';
  end if;
  if p_rate<0 or p_rate>100 then raise exception 'Rate must be between 0 and 100.'; end if;
  if p_rate_type='vat' and p_vat_treatment not in ('standard','zero_rated','exempt','out_of_scope') then
    raise exception 'VAT treatment is required for VAT rates.';
  end if;
  if p_rate_type='vat' and p_vat_treatment<>'standard' and abs(p_rate)>0.0001 then
    raise exception 'Zero-rated, exempt and out-of-scope rates must be zero.';
  end if;
  insert into tax_rates(user_id,rate_type,transaction_type,label,rate,vat_treatment,effective_from,effective_to,legal_reference)
  values(uid,p_rate_type,btrim(p_transaction_type),btrim(p_label),round(p_rate,4),p_vat_treatment,p_effective_from,p_effective_to,nullif(btrim(p_legal_reference),''))
  returning id into v_id;
  perform write_audit_log('configure','tax_rates',v_id::text,null,jsonb_build_object('type',p_rate_type,'transaction_type',p_transaction_type,'rate',p_rate));
  return v_id;
end;
$$;

create or replace function close_fiscal_year(p_fiscal_year text, p_next_fiscal_year text, p_closing_date date, p_opening_date date, p_notes text default null::text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare uid uuid:=get_workspace_owner(); v_preview jsonb; v_retained uuid; v_close_lines jsonb; v_open_lines jsonb; v_net numeric; v_closing_voucher uuid; v_opening_voucher uuid; v_id uuid;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  perform assert_role(array['owner']);
  if p_opening_date<=p_closing_date then raise exception 'Opening date must be after the closing date.'; end if;
  perform pg_advisory_xact_lock(hashtextextended(uid::text||':year-close:'||p_fiscal_year,0));
  v_preview:=preview_fiscal_year_close(p_fiscal_year,p_next_fiscal_year,p_closing_date,p_opening_date);
  if not coalesce((v_preview->>'can_close')::boolean,false) then raise exception 'Year-end close preconditions are not satisfied. Review the preview.'; end if;
  if exists(select 1 from opening_journals where user_id=uid and fiscal_year=p_next_fiscal_year) then raise exception 'An opening journal already exists for fiscal year %.',p_next_fiscal_year; end if;
  v_retained:=resolve_system_account('retained_earnings');
  with balances as (
    select a.id,a.name,round(sum(vl.debit-vl.credit),2) balance
    from accounts a join voucher_lines vl on vl.account_id=a.id join vouchers v on v.id=vl.voucher_id
    where a.user_id=uid and v.user_id=uid and v.is_void=false and v.fiscal_year=p_fiscal_year and v.voucher_date<=p_closing_date
      and coalesce(v.source_document_type,'')<>'year_end_closing'
      and a.report_class in ('revenue','other_income','cost_of_sales','operating_expense','other_expense')
    group by a.id,a.name having abs(sum(vl.debit-vl.credit))>0.005
  ), base_lines as (
    select jsonb_build_object('account_id',id,'debit',case when balance<0 then -balance else 0 end,'credit',case when balance>0 then balance else 0 end,'description','Close '||name) line,
      balance from balances
  )
  select coalesce(jsonb_agg(line),'[]'::jsonb),coalesce(sum(balance),0) into v_close_lines,v_net from base_lines;
  if jsonb_array_length(v_close_lines)>0 then
    v_close_lines:=v_close_lines||jsonb_build_array(jsonb_build_object('account_id',v_retained,'debit',case when v_net>0 then v_net else 0 end,
      'credit',case when v_net<0 then -v_net else 0 end,'description',case when v_net<0 then 'Transfer net profit' else 'Transfer net loss' end));
    perform set_config('hisabkitab.period_lock_bypass',uid::text,true);
    v_closing_voucher:=post_voucher('journal',p_fiscal_year,p_closing_date,'Year-end closing for '||p_fiscal_year,v_close_lines);
  end if;
  with activity as (select * from report_account_activity(null,p_closing_date,null)), lines as (
    select jsonb_build_object('account_id',account_id,'debit',case when closing_balance>0 then closing_balance else 0 end,
      'credit',case when closing_balance<0 then -closing_balance else 0 end,'description','Balance carried forward') line
    from activity where report_class in ('current_asset','non_current_asset','current_liability','non_current_liability','equity') and abs(closing_balance)>0.005
  ) select coalesce(jsonb_agg(line),'[]'::jsonb) into v_open_lines from lines;
  if jsonb_array_length(v_open_lines)<2 then raise exception 'There are not enough balance-sheet balances to carry forward.'; end if;
  perform set_config('hisabkitab.period_lock_bypass','',true);
  v_opening_voucher:=post_opening_journal(p_next_fiscal_year,p_opening_date,v_open_lines,'Year-end carry-forward from '||p_fiscal_year);
  insert into fiscal_year_closures(user_id,fiscal_year,next_fiscal_year,closing_date,opening_date,retained_earnings_account_id,closing_voucher_id,opening_voucher_id,snapshot,notes)
  values(uid,p_fiscal_year,p_next_fiscal_year,p_closing_date,p_opening_date,v_retained,v_closing_voucher,v_opening_voucher,v_preview,nullif(btrim(p_notes),'')) returning id into v_id;
  if v_closing_voucher is not null then
    perform set_config('hisabkitab.period_lock_bypass',uid::text,true);
    update vouchers set source_document_type='year_end_closing',source_document_id=v_id where id=v_closing_voucher and user_id=uid;
    perform set_config('hisabkitab.period_lock_bypass','',true);
  end if;
  update vouchers set source_document_type='year_end_opening',source_document_id=v_id where id=v_opening_voucher and user_id=uid;
  update fiscal_periods set is_locked=true,lock_reason='Fiscal year closed',locked_at=coalesce(locked_at,now()),locked_by=coalesce(locked_by,uid) where user_id=uid and fiscal_year=p_fiscal_year;
  perform write_audit_log('close','fiscal_year_closures',v_id::text,null,jsonb_build_object('fiscal_year',p_fiscal_year,'closing_voucher_id',v_closing_voucher,'opening_voucher_id',v_opening_voucher));
  return v_id;
end; $$;
