-- ============================================================
-- HisabKitab P2.27 -- RBAC batch 5: vouchers/journals/TDS/period
-- lock/VAT prepare (owner + accountant), backfill utility (owner
-- only -- a sweeping bulk-data operation, not routine work).
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
  perform assert_role(array['owner','accountant']);

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
  perform assert_role(array['owner','accountant']);

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
  perform assert_role(array['owner','accountant']);
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
  perform assert_role(array['owner','accountant']);
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
  perform assert_role(array['owner']);

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
      select coalesce(payable_account_id, account_id) into creditor_acct from parties where id = r.vendor_id and user_id = uid;
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

create or replace function preview_fiscal_year_close(p_fiscal_year text, p_next_fiscal_year text, p_closing_date date, p_opening_date date)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare uid uuid:=get_workspace_owner(); v_from date; v_to date; v_period_count integer; v_unlocked integer; v_drafts integer; v_next_period_count integer; v_next_from date; v_tb jsonb; v_stock jsonb; v_vat jsonb; v_pl jsonb; v_bs jsonb; v_existing boolean;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  perform assert_role(array['owner','accountant']);
  select min(from_date),max(to_date),count(*),count(*) filter(where not is_locked) into v_from,v_to,v_period_count,v_unlocked
    from fiscal_periods where user_id=uid and fiscal_year=p_fiscal_year;
  select count(*),min(from_date) into v_next_period_count,v_next_from
    from fiscal_periods where user_id=uid and fiscal_year=p_next_fiscal_year;
  select count(*) into v_drafts from (
    select id from invoices where user_id=uid and fiscal_year=p_fiscal_year and document_status='draft'
    union all select id from purchase_bills where user_id=uid and fiscal_year=p_fiscal_year and document_status='draft'
  ) x;
  v_existing:=exists(select 1 from fiscal_year_closures where user_id=uid and fiscal_year=p_fiscal_year);
  if v_from is not null then
    v_tb:=get_trial_balance_report(p_closing_date); v_stock:=get_stock_valuation_report(p_closing_date);
    v_vat:=get_vat_report(v_from,least(v_to,p_closing_date),p_fiscal_year); v_pl:=get_profit_loss_report(v_from,least(v_to,p_closing_date),p_fiscal_year); v_bs:=get_balance_sheet_report(p_closing_date);
  else
    v_tb:='{}'::jsonb; v_stock:='{}'::jsonb; v_vat:='{}'::jsonb; v_pl:='{}'::jsonb; v_bs:='{}'::jsonb;
  end if;
  return jsonb_build_object('fiscal_year',p_fiscal_year,'next_fiscal_year',p_next_fiscal_year,'closing_date',p_closing_date,'opening_date',p_opening_date,
    'period_from',v_from,'period_to',v_to,'period_count',v_period_count,'unlocked_periods',v_unlocked,'draft_documents',v_drafts,'already_closed',v_existing,
    'next_period_count',v_next_period_count,'next_period_from',v_next_from,
    'closing_date_matches_period_end',p_closing_date=v_to,'opening_date_is_next_day',p_opening_date=v_to+1,
    'next_period_starts_on_opening_date',v_next_from=p_opening_date,
    'trial_balance',v_tb,'stock',v_stock,'vat',v_vat,'profit_loss',v_pl,'balance_sheet',v_bs,
    'can_close',v_period_count=12 and v_unlocked=0 and v_drafts=0 and not v_existing
      and v_next_period_count=12 and v_next_from=p_opening_date
      and p_closing_date=v_to and p_opening_date=v_to+1 and nullif(btrim(p_next_fiscal_year),'') is not null and p_next_fiscal_year<>p_fiscal_year
      and coalesce((v_tb->>'balanced')::boolean,false) and coalesce((v_stock->>'reconciled')::boolean,false)
      and coalesce((v_vat->>'reconciled')::boolean,false) and coalesce((v_bs->>'balanced')::boolean,false));
end; $$;

create or replace function set_period_lock(p_period_id uuid, p_locked boolean, p_reason text default null::text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare uid uuid:=get_workspace_owner(); actor uuid:=auth.uid(); p fiscal_periods%rowtype;
begin
  if actor is null then raise exception 'Not authenticated'; end if;
  perform assert_role(array['owner','accountant']);
  select * into p from fiscal_periods where id=p_period_id and user_id=uid for update;
  if not found then raise exception 'Fiscal period not found.'; end if;
  if exists(select 1 from fiscal_year_closures where user_id=uid and fiscal_year=p.fiscal_year) then raise exception 'A closed fiscal year cannot be unlocked or changed.'; end if;
  if not p_locked and exists(select 1 from vat_returns where user_id=uid and fiscal_period_id=p.id and status='filed') then raise exception 'A period with a filed VAT return cannot be unlocked through the application.'; end if;
  update fiscal_periods set is_locked=p_locked,lock_reason=case when p_locked then coalesce(nullif(btrim(p_reason),''),'Period locked') else null end,
    locked_at=case when p_locked then now() else null end,locked_by=case when p_locked then actor else null end where id=p.id;
  perform write_audit_log(case when p_locked then 'lock' else 'unlock' end,'fiscal_periods',p.id::text,to_jsonb(p),jsonb_build_object('locked',p_locked,'reason',p_reason));
end; $$;

create or replace function create_tds_entry(
  p_date date, p_fiscal_year text, p_tds_type text, p_payee_name text, p_payee_pan text,
  p_payee_id uuid, p_gross numeric, p_rate numeric, p_mode text, p_reference text, p_notes text,
  p_expense_account_id uuid default null::uuid
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := get_workspace_owner();
  v_id uuid; v_tds numeric(14,2); v_net numeric(14,2); v_cash uuid; v_tds_acct uuid; v_expense uuid; v_voucher uuid; v_due_day integer; v_due date; v_period_end date;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  perform assert_role(array['owner','accountant']);
  if p_date is null or nullif(btrim(p_fiscal_year),'') is null then raise exception 'Date and fiscal year are required.'; end if;
  if nullif(btrim(p_payee_name),'') is null then raise exception 'Payee name is required.'; end if;
  if p_gross<=0 or p_rate<=0 or p_rate>100 then raise exception 'Gross amount and a valid positive TDS rate are required.'; end if;
  if lower(p_mode) not in ('cash','bank') then raise exception 'Payment mode must be cash or bank.'; end if;
  if p_payee_id is not null and not exists(select 1 from parties where id=p_payee_id and user_id=uid) then raise exception 'Payee does not belong to this business.'; end if;
  insert into tax_compliance_settings(user_id) values(uid) on conflict(user_id) do nothing;
  if (select require_pan_for_tds from tax_compliance_settings where user_id=uid) and nullif(btrim(p_payee_pan),'') is null then raise exception 'Payee PAN is required by your compliance settings.'; end if;
  v_expense:=coalesce(p_expense_account_id,resolve_system_account('tds_expense'));
  if not exists(select 1 from accounts where id=v_expense and user_id=uid and is_active=true and report_class in ('cost_of_sales','operating_expense','other_expense')) then raise exception 'Select an active expense account owned by this business.'; end if;
  v_tds:=round(p_gross*p_rate/100,2); v_net:=round(p_gross-v_tds,2);
  if v_tds<=0 or v_net<0 then raise exception 'Invalid TDS calculation.'; end if;
  v_cash:=resolve_system_account(lower(p_mode)); v_tds_acct:=resolve_system_account('tds_payable');
  v_voucher:=post_voucher('payment',p_fiscal_year,p_date,'TDS deduction - '||btrim(p_payee_name),jsonb_build_array(
    jsonb_build_object('account_id',v_expense,'debit',round(p_gross,2),'credit',0,'description',p_tds_type||' gross expense'),
    jsonb_build_object('account_id',v_cash,'debit',0,'credit',v_net,'description','Net paid to '||btrim(p_payee_name)),
    jsonb_build_object('account_id',v_tds_acct,'debit',0,'credit',v_tds,'description','TDS withheld')
  ));
  select tds_due_day into v_due_day from tax_compliance_settings where user_id=uid;
  select to_date into v_period_end
    from fiscal_periods
   where user_id=uid and p_date between from_date and to_date
   order by from_date
   limit 1;
  v_due:=coalesce(v_period_end,p_date)+v_due_day;
  insert into tds_entries(user_id,entry_date,fiscal_year,tds_type,payee_name,payee_pan,payee_id,expense_account_id,gross_amount,tds_rate,tds_amount,net_amount,
    payment_mode,reference,notes,status,due_date,voucher_id)
  values(uid,p_date,btrim(p_fiscal_year),btrim(p_tds_type),btrim(p_payee_name),nullif(btrim(p_payee_pan),''),p_payee_id,v_expense,round(p_gross,2),round(p_rate,4),v_tds,v_net,
    lower(p_mode),nullif(btrim(p_reference),''),nullif(btrim(p_notes),''),'deducted',v_due,v_voucher) returning id into v_id;
  update vouchers set source_document_type='tds_entry',source_document_id=v_id where id=v_voucher and user_id=uid;
  perform write_audit_log('create','tds_entries',v_id::text,null,jsonb_build_object('gross',p_gross,'tds',v_tds,'voucher_id',v_voucher));
  return v_id;
end; $$;

create or replace function remit_tds(p_entry_ids uuid[], p_date date, p_fiscal_year text, p_period_label text, p_mode text, p_challan_no text, p_notes text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare uid uuid:=get_workspace_owner(); v_total numeric(14,2); v_count integer; v_id uuid; v_voucher uuid; v_tds uuid; v_cash uuid;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  perform assert_role(array['owner','accountant']);
  if p_entry_ids is null or cardinality(p_entry_ids)=0 then raise exception 'Select at least one TDS entry.'; end if;
  if p_date is null or nullif(btrim(p_fiscal_year),'') is null or nullif(btrim(p_period_label),'') is null then raise exception 'Date, fiscal year and period are required.'; end if;
  if lower(p_mode) not in ('cash','bank') then raise exception 'Payment mode must be cash or bank.'; end if;
  with selected as (
    select * from tds_entries where user_id=uid and id=any(p_entry_ids) and status='deducted'
      and fiscal_year=btrim(p_fiscal_year) and entry_date<=p_date for update
  )
  select count(*),round(coalesce(sum(tds_amount),0),2) into v_count,v_total from selected;
  if v_count<>cardinality(p_entry_ids) then raise exception 'One or more selected entries are missing, already remitted, reversed, or dated after the remittance.'; end if;
  v_tds:=resolve_system_account('tds_payable'); v_cash:=resolve_system_account(lower(p_mode));
  v_voucher:=post_voucher('payment',p_fiscal_year,p_date,'TDS remittance - '||btrim(p_period_label),jsonb_build_array(
    jsonb_build_object('account_id',v_tds,'debit',v_total,'credit',0,'description','TDS liability remitted'),
    jsonb_build_object('account_id',v_cash,'debit',0,'credit',v_total,'description','Paid to tax authority')
  ));
  insert into tds_remittances(user_id,remittance_date,fiscal_year,period_label,total_tds,payment_mode,challan_no,notes,voucher_id)
  values(uid,p_date,btrim(p_fiscal_year),btrim(p_period_label),v_total,lower(p_mode),nullif(btrim(p_challan_no),''),nullif(btrim(p_notes),''),v_voucher) returning id into v_id;
  update tds_entries set status='remitted',remittance_id=v_id where user_id=uid and id=any(p_entry_ids);
  update vouchers set source_document_type='tds_remittance',source_document_id=v_id where id=v_voucher and user_id=uid;
  perform write_audit_log('remit','tds_remittances',v_id::text,null,jsonb_build_object('entry_count',v_count,'total_tds',v_total,'voucher_id',v_voucher));
  return v_id;
end; $$;

create or replace function reverse_tds_entry(p_entry_id uuid, p_reason text, p_date date default current_date)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare uid uuid:=get_workspace_owner(); e tds_entries%rowtype; v_cash uuid; v_tds uuid; v_voucher uuid;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  perform assert_role(array['owner','accountant']);
  if nullif(btrim(p_reason),'') is null or length(btrim(p_reason))<3 then raise exception 'A reversal reason is required.'; end if;
  select * into e from tds_entries where id=p_entry_id and user_id=uid for update;
  if not found then raise exception 'TDS entry not found.'; end if;
  if e.status<>'deducted' then raise exception 'Only an unremitted TDS entry can be reversed.'; end if;
  if p_date<e.entry_date then raise exception 'Reversal date cannot precede the deduction.'; end if;
  v_cash:=resolve_system_account(e.payment_mode); v_tds:=resolve_system_account('tds_payable');
  v_voucher:=post_voucher('journal',e.fiscal_year,p_date,'Reversal of TDS deduction: '||btrim(p_reason),jsonb_build_array(
    jsonb_build_object('account_id',v_cash,'debit',e.net_amount,'credit',0,'description','Reverse net payment'),
    jsonb_build_object('account_id',v_tds,'debit',e.tds_amount,'credit',0,'description','Reverse TDS liability'),
    jsonb_build_object('account_id',e.expense_account_id,'debit',0,'credit',e.gross_amount,'description','Reverse expense')
  ));
  update tds_entries set status='reversed',reversal_voucher_id=v_voucher,reversal_reason=btrim(p_reason),reversed_at=now() where id=e.id;
  update vouchers set source_document_type='tds_entry_reversal',source_document_id=e.id,reverses_voucher_id=e.voucher_id where id=v_voucher and user_id=uid;
  update vouchers set reversed_by_voucher_id=v_voucher where id=e.voucher_id and user_id=uid;
  perform write_audit_log('reverse','tds_entries',e.id::text,to_jsonb(e),jsonb_build_object('reason',p_reason,'voucher_id',v_voucher));
  return v_voucher;
end; $$;

create or replace function prepare_vat_return(p_period_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare uid uuid:=get_workspace_owner(); p fiscal_periods%rowtype; v_report jsonb; v_id uuid;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  perform assert_role(array['owner','accountant']);
  select * into p from fiscal_periods where id=p_period_id and user_id=uid;
  if not found then raise exception 'Fiscal period not found.'; end if;
  v_report:=get_vat_report(p.from_date,p.to_date,p.fiscal_year);
  insert into vat_returns(user_id,fiscal_period_id,fiscal_year,from_date,to_date,status,snapshot,prepared_at)
  values(uid,p.id,p.fiscal_year,p.from_date,p.to_date,'draft',v_report,now())
  on conflict(user_id,fiscal_period_id) do update set snapshot=excluded.snapshot,prepared_at=now()
    where vat_returns.status='draft'
  returning id into v_id;
  if v_id is null then raise exception 'The VAT return is already filed.'; end if;
  perform write_audit_log('create_draft','vat_returns',v_id::text,null,jsonb_build_object('period_id',p.id,'reconciled',v_report->'reconciled'));
  return v_id;
end; $$;
