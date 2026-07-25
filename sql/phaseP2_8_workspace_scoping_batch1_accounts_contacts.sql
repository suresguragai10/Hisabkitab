-- ============================================================
-- HisabKitab P2.8 -- Workspace-scoping fix, batch 1: Chart of
-- Accounts + Contacts.
--
-- Part of the larger workspace-scoping remediation (see memory:
-- workspace_scoping_gap.md). Each function below scopes data by
-- auth.uid() directly instead of get_workspace_owner() -- dormant for
-- a solo owner, but breaks an invited accountant/staff member acting
-- inside someone else's workspace. Fetched live (not from repo) and
-- fixed with the minimal, mechanical change: the uid variable's
-- source only. No other logic touched. invite_member deliberately
-- left unchanged -- auth.uid() there is correct (only a true owner
-- should invite team members).
-- ============================================================

create or replace function create_contact(
  p_name text, p_name_np text default null, p_is_customer boolean default true, p_is_vendor boolean default false,
  p_contact_person text default null, p_phone text default null, p_email text default null,
  p_billing_address text default null, p_shipping_address text default null,
  p_pan_number text default null, p_vat_number text default null, p_payment_terms_days integer default null,
  p_tds_applicable boolean default false, p_tds_rate numeric default null, p_notes text default null,
  p_opening_balance numeric default 0, p_opening_balance_type text default 'debit'
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare uid uuid:=get_workspace_owner(); v_acct uuid; v_payable_acct uuid; v_party uuid; v_type text; v_code text;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  if p_name is null or btrim(p_name)='' then raise exception 'Contact name is required.'; end if;
  if not (p_is_customer or p_is_vendor) then raise exception 'Contact must be a customer or vendor.'; end if;
  if abs(coalesce(p_opening_balance,0))>0.005 then
    raise exception 'Create the contact first, then post its opening balance through Chart of Accounts > Opening Journal.';
  end if;

  if p_is_customer then
    v_code:=next_structured_account_code(uid,'current_asset','AR');
    insert into accounts(user_id,name,account_code,account_type,group_name,report_class,account_subtype,normal_balance,cash_flow_category,is_party_account,allow_manual_posting,opening_balance,opening_balance_type)
    values(uid,btrim(p_name),v_code,'asset','Current Asset','current_asset','receivable','debit','operating',true,true,0,'debit') returning id into v_acct;
  else
    v_code:=next_structured_account_code(uid,'current_liability','AP');
    insert into accounts(user_id,name,account_code,account_type,group_name,report_class,account_subtype,normal_balance,cash_flow_category,is_party_account,allow_manual_posting,opening_balance,opening_balance_type)
    values(uid,btrim(p_name),v_code,'liability','Current Liability','current_liability','payable','credit','operating',true,true,0,'credit') returning id into v_acct;
  end if;

  if p_is_customer and p_is_vendor then
    v_code:=next_structured_account_code(uid,'current_liability','AP');
    insert into accounts(user_id,name,account_code,account_type,group_name,report_class,account_subtype,normal_balance,cash_flow_category,is_party_account,allow_manual_posting,opening_balance,opening_balance_type)
    values(uid,btrim(p_name),v_code,'liability','Current Liability','current_liability','payable','credit','operating',true,true,0,'credit') returning id into v_payable_acct;
  end if;

  v_type:=case when p_is_customer and p_is_vendor then 'both' when p_is_customer then 'customer' else 'vendor' end;
  insert into parties(user_id,account_id,payable_account_id,party_type,name_np,contact_person,is_customer,is_vendor,phone,email,address,billing_address,shipping_address,pan_vat_number,pan_number,vat_number,payment_terms_days,tds_applicable,tds_rate,notes,is_active)
  values(uid,v_acct,v_payable_acct,v_type,p_name_np,p_contact_person,p_is_customer,p_is_vendor,p_phone,p_email,p_billing_address,p_billing_address,p_shipping_address,p_pan_number,p_pan_number,p_vat_number,p_payment_terms_days,coalesce(p_tds_applicable,false),p_tds_rate,p_notes,true)
  returning id into v_party;
  perform write_audit_log('create','parties',v_party::text,null,jsonb_build_object('name',p_name,'account_code',v_code));
  return v_party;
end;
$$;

create or replace function update_contact(
  p_id uuid, p_name text, p_name_np text default null, p_is_customer boolean default null, p_is_vendor boolean default null,
  p_contact_person text default null, p_phone text default null, p_email text default null,
  p_billing_address text default null, p_shipping_address text default null,
  p_pan_number text default null, p_vat_number text default null, p_payment_terms_days integer default null,
  p_tds_applicable boolean default null, p_tds_rate numeric default null, p_notes text default null,
  p_is_active boolean default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := get_workspace_owner();
  v_acct uuid;
  v_payable_acct uuid;
  v_is_both boolean;
  v_code text;
begin
  if uid is null then raise exception 'Not authenticated'; end if;

  update parties set
    name_np            = coalesce(p_name_np, name_np),
    is_customer        = coalesce(p_is_customer, is_customer),
    is_vendor          = coalesce(p_is_vendor, is_vendor),
    contact_person     = coalesce(p_contact_person, contact_person),
    phone              = coalesce(p_phone, phone),
    email              = coalesce(p_email, email),
    billing_address    = coalesce(p_billing_address, billing_address),
    address            = coalesce(p_billing_address, address),
    shipping_address   = coalesce(p_shipping_address, shipping_address),
    pan_number         = coalesce(p_pan_number, pan_number),
    pan_vat_number     = coalesce(p_pan_number, pan_vat_number),
    vat_number         = coalesce(p_vat_number, vat_number),
    payment_terms_days = coalesce(p_payment_terms_days, payment_terms_days),
    tds_applicable     = coalesce(p_tds_applicable, tds_applicable),
    tds_rate           = coalesce(p_tds_rate, tds_rate),
    notes              = coalesce(p_notes, notes),
    is_active          = coalesce(p_is_active, is_active),
    party_type         = case
      when coalesce(p_is_customer, is_customer) and coalesce(p_is_vendor, is_vendor) then 'both'
      when coalesce(p_is_customer, is_customer) then 'customer'
      else 'vendor'
    end,
    updated_at         = now()
  where id = p_id and user_id = uid
  returning account_id, payable_account_id, (party_type = 'both') into v_acct, v_payable_acct, v_is_both;

  if v_acct is not null then
    update accounts set name = p_name where id = v_acct and user_id = uid;
  end if;

  if v_is_both and v_payable_acct is null then
    v_code := next_structured_account_code(uid, 'current_liability', 'AP');
    insert into accounts(user_id,name,account_code,account_type,group_name,report_class,account_subtype,normal_balance,cash_flow_category,is_party_account,allow_manual_posting,opening_balance,opening_balance_type)
    values(uid, p_name, v_code, 'liability','Current Liability','current_liability','payable','credit','operating',true,true,0,'credit')
    returning id into v_payable_acct;
    update parties set payable_account_id = v_payable_acct where id = p_id and user_id = uid;
  end if;

  perform write_audit_log('update','parties', p_id::text, null, jsonb_build_object('name', p_name));
end;
$$;

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

create or replace function resolve_system_account(p_code text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare uid uuid:=get_workspace_owner(); acc_id uuid; v record;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  select id into acc_id from accounts where user_id=uid and system_code=p_code limit 1;
  if acc_id is not null then return acc_id; end if;
  select * into v from (values
    ('cash','1000','Cash in Hand','asset','current_asset','cash','debit','not_applicable',false,true),
    ('bank','1010','Bank Account','asset','current_asset','bank','debit','not_applicable',false,true),
    ('ar_control','1100','Sundry Debtors (Control)','asset','current_asset','receivable_control','debit','operating',true,false),
    ('inventory_asset','1200','Inventory Asset','asset','current_asset','inventory','debit','operating',true,false),
    ('vat_receivable','1300','VAT Receivable','asset','current_asset','input_tax','debit','operating',true,false),
    ('ap_control','2000','Sundry Creditors (Control)','liability','current_liability','payable_control','credit','operating',true,false),
    ('vat_payable','2100','VAT Payable','liability','current_liability','output_tax','credit','operating',true,false),
    ('tds_payable','2200','TDS Payable','liability','current_liability','withholding_tax_payable','credit','operating',true,false),
    ('inventory_opening','3100','Inventory Opening Equity','equity','equity','opening_equity','credit','financing',false,false),
    ('retained_earnings','3200','Retained Earnings','equity','equity','retained_earnings','credit','financing',false,false),
    ('sales','4000','Sales Account','income','revenue','sales','credit','operating',false,false),
    ('purchase','5000','Purchase Account','expense','cost_of_sales','purchases','debit','operating',false,false),
    ('cogs','5100','Cost of Goods Sold','expense','cost_of_sales','cost_of_goods_sold','debit','operating',false,false),
    ('stock_adjustment','5200','Stock Adjustment','expense','cost_of_sales','stock_adjustment','debit','operating',false,false),
    ('purchase_return','5210','Purchase Return','expense','cost_of_sales','purchase_return','debit','operating',false,false),
    ('tds_expense','6100','General TDS Expense','expense','operating_expense','withholding_expense','debit','operating',false,true)
  ) x(code,acct_code,name,acct_type,report_class,subtype,normal,cf,is_control,allow_manual) where code=p_code;
  if not found then raise exception 'Unknown system account code: %',p_code; end if;
  if exists(select 1 from accounts where user_id=uid and account_code=v.acct_code) then v.acct_code:=next_structured_account_code(uid,v.report_class,null); end if;
  insert into accounts(user_id,name,account_code,account_type,group_name,report_class,account_subtype,normal_balance,cash_flow_category,
    is_party_account,is_control_account,is_system_account,allow_manual_posting,opening_balance,opening_balance_type,system_code)
  values(uid,v.name,v.acct_code,v.acct_type,replace(initcap(replace(v.report_class,'_',' ')),' And ',' & '),v.report_class,v.subtype,v.normal,v.cf,
    false,v.is_control,true,v.allow_manual,0,v.normal,p_code) returning id into acc_id;
  return acc_id;
end; $$;

create or replace function seed_default_accounts()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare uid uuid:=get_workspace_owner();
begin
  if uid is null then raise exception 'Not authenticated'; end if;
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
