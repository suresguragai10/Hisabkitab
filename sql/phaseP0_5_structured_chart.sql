-- ============================================================
-- HisabKitab Stage 5 - structured Chart of Accounts
-- Apply after phaseP0_4_document_lifecycle.sql.
--
-- Implements:
--   * account codes and parent hierarchy
--   * report class, subtype, normal balance and cash-flow category
--   * system/control/manual-posting flags
--   * safe account create/update/deactivation RPCs
--   * balanced opening journals and legacy-opening conversion
--   * structured Trial Balance, P&L, Balance Sheet and dashboard inputs
-- ============================================================

begin;

-- Stage 4 compatibility hotfix: use JSON field access so the shared trigger
-- never references invoice-only fields on bills or note-only fields elsewhere.
create or replace function protect_document_identity()
returns trigger
language plpgsql
set search_path=public
as $$
declare v_new jsonb:=to_jsonb(new); v_old jsonb:=to_jsonb(old);
begin
  if v_new->>'user_id' is distinct from v_old->>'user_id'
     or v_new->>'fiscal_year' is distinct from v_old->>'fiscal_year' then
    raise exception 'Document owner and fiscal year are immutable.';
  end if;
  if tg_table_name='invoices' and v_new->>'invoice_number' is distinct from v_old->>'invoice_number' then
    raise exception 'Invoice number is immutable.';
  elsif tg_table_name='purchase_bills' and v_new->>'bill_number' is distinct from v_old->>'bill_number' then
    raise exception 'Bill number is immutable.';
  elsif tg_table_name='credit_notes' and v_new->>'cn_number' is distinct from v_old->>'cn_number' then
    raise exception 'Credit note number is immutable.';
  elsif tg_table_name='debit_notes' and v_new->>'dn_number' is distinct from v_old->>'dn_number' then
    raise exception 'Debit note number is immutable.';
  end if;
  return new;
end;
$$;

-- ------------------------------------------------------------
-- 1. Structured account fields.
-- ------------------------------------------------------------
alter table accounts
  add column if not exists account_code text,
  add column if not exists parent_account_id uuid references accounts(id) on delete restrict,
  add column if not exists report_class text,
  add column if not exists account_subtype text,
  add column if not exists normal_balance text,
  add column if not exists cash_flow_category text,
  add column if not exists is_control_account boolean not null default false,
  add column if not exists is_system_account boolean not null default false,
  add column if not exists allow_manual_posting boolean not null default true,
  add column if not exists updated_at timestamptz not null default now();

-- One-time classification. Display names/groups are used only to migrate the
-- legacy model; all runtime reports use report_class/account_subtype afterwards.
update accounts
set report_class = case
  when account_type='asset' and (
    system_code in ('cash','bank','ar_control','inventory_asset','vat_receivable')
    or is_party_account
    or group_name in ('Cash-in-Hand','Bank Accounts','Sundry Debtors','Duties & Taxes','Current Assets','Stock-in-Hand','General')
  ) then 'current_asset'
  when account_type='asset' then 'non_current_asset'
  when account_type='liability' and (
    system_code in ('ap_control','vat_payable')
    or is_party_account
    or group_name in ('Duties & Taxes','Sundry Creditors','General','Current Liabilities')
  ) then 'current_liability'
  when account_type='liability' then 'non_current_liability'
  when account_type='equity' then 'equity'
  when account_type='income' and (system_code='sales' or group_name='Direct Income') then 'revenue'
  when account_type='income' then 'other_income'
  when account_type='expense' and system_code in ('purchase','cogs','stock_adjustment','purchase_return') then 'cost_of_sales'
  when account_type='expense' and group_name='Direct Expense' then 'cost_of_sales'
  when account_type='expense' and group_name='Indirect Expense' then 'operating_expense'
  when account_type='expense' then 'other_expense'
  else report_class
end
where report_class is null;

update accounts
set account_subtype = case
  when system_code='cash' then 'cash'
  when system_code='bank' then 'bank'
  when system_code='ar_control' then 'receivable_control'
  when system_code='ap_control' then 'payable_control'
  when system_code='inventory_asset' then 'inventory'
  when system_code='vat_receivable' then 'input_tax'
  when system_code='vat_payable' then 'output_tax'
  when system_code='sales' then 'sales'
  when system_code='purchase' then 'purchases'
  when system_code='cogs' then 'cost_of_goods_sold'
  when system_code='stock_adjustment' then 'stock_adjustment'
  when system_code='purchase_return' then 'purchase_return'
  when system_code='inventory_opening' then 'opening_equity'
  when is_party_account and account_type='asset' then 'receivable'
  when is_party_account and account_type='liability' then 'payable'
  when account_type='equity' and lower(name) like '%drawing%' then 'drawings'
  when account_type='equity' then 'capital'
  when report_class='non_current_asset' then 'fixed_asset'
  when report_class='operating_expense' then 'operating_expense'
  when report_class='other_expense' then 'other_expense'
  when report_class='other_income' then 'other_income'
  else 'general'
end
where account_subtype is null;

update accounts
set normal_balance = case
  when account_subtype in ('drawings') then 'debit'
  when account_type in ('asset','expense') then 'debit'
  else 'credit'
end
where normal_balance is null;

update accounts
set cash_flow_category = case
  when account_subtype in ('cash','bank') then 'not_applicable'
  when report_class in ('current_asset','current_liability','revenue','cost_of_sales','operating_expense','other_income','other_expense') then 'operating'
  when report_class in ('non_current_asset') then 'investing'
  when report_class in ('non_current_liability','equity') then 'financing'
  else 'not_applicable'
end
where cash_flow_category is null;

update accounts
set is_system_account = (system_code is not null),
    is_control_account = coalesce(
      system_code in ('ar_control','ap_control','inventory_asset','vat_receivable','vat_payable'),
      false
    ),
    allow_manual_posting = case
      when system_code in ('sales','purchase','cogs','inventory_asset','vat_receivable','vat_payable','stock_adjustment','purchase_return','inventory_opening','ar_control','ap_control') then false
      else true
    end;

-- Stable codes for known system accounts.
update accounts set account_code = case system_code
  when 'cash' then '1000'
  when 'bank' then '1010'
  when 'ar_control' then '1100'
  when 'inventory_asset' then '1200'
  when 'vat_receivable' then '1300'
  when 'ap_control' then '2000'
  when 'vat_payable' then '2100'
  when 'inventory_opening' then '3100'
  when 'sales' then '4000'
  when 'purchase' then '5000'
  when 'cogs' then '5100'
  when 'stock_adjustment' then '5200'
  when 'purchase_return' then '5210'
  else account_code
end
where system_code is not null and account_code is null;

-- Party sub-ledger codes.
with ranked as (
  select id,
         case when account_type='liability' then 'AP-' else 'AR-' end ||
         lpad(row_number() over (
           partition by user_id, case when account_type='liability' then 'AP' else 'AR' end
           order by created_at,id
         )::text,4,'0') as generated_code
  from accounts
  where account_code is null and is_party_account
)
update accounts a set account_code=r.generated_code
from ranked r where r.id=a.id;

-- Other legacy accounts receive deterministic class-prefixed codes.
with ranked as (
  select id,
    (case report_class
      when 'current_asset' then 'CA'
      when 'non_current_asset' then 'NCA'
      when 'current_liability' then 'CL'
      when 'non_current_liability' then 'NCL'
      when 'equity' then 'EQ'
      when 'revenue' then 'REV'
      when 'cost_of_sales' then 'COS'
      when 'operating_expense' then 'OPEX'
      when 'other_income' then 'OI'
      else 'OE'
    end) || '-' || lpad(row_number() over (partition by user_id,report_class order by created_at,id)::text,4,'0') as generated_code
  from accounts
  where account_code is null
)
update accounts a set account_code=r.generated_code
from ranked r where r.id=a.id;

alter table accounts alter column account_code set not null;
alter table accounts alter column report_class set not null;
alter table accounts alter column account_subtype set not null;
alter table accounts alter column normal_balance set not null;
alter table accounts alter column cash_flow_category set not null;

alter table accounts drop constraint if exists accounts_account_code_nonblank;
alter table accounts add constraint accounts_account_code_nonblank check (btrim(account_code) <> '');
alter table accounts drop constraint if exists accounts_report_class_check;
alter table accounts add constraint accounts_report_class_check check (report_class in (
  'current_asset','non_current_asset','current_liability','non_current_liability',
  'equity','revenue','cost_of_sales','operating_expense','other_income','other_expense'
));
alter table accounts drop constraint if exists accounts_normal_balance_check;
alter table accounts add constraint accounts_normal_balance_check check (normal_balance in ('debit','credit'));
alter table accounts drop constraint if exists accounts_cash_flow_category_check;
alter table accounts add constraint accounts_cash_flow_category_check check (cash_flow_category in (
  'operating','investing','financing','non_cash','not_applicable'
));
alter table accounts drop constraint if exists accounts_report_class_type_check;
alter table accounts add constraint accounts_report_class_type_check check (
  (account_type='asset' and report_class in ('current_asset','non_current_asset')) or
  (account_type='liability' and report_class in ('current_liability','non_current_liability')) or
  (account_type='equity' and report_class='equity') or
  (account_type='income' and report_class in ('revenue','other_income')) or
  (account_type='expense' and report_class in ('cost_of_sales','operating_expense','other_expense'))
);

create unique index if not exists uq_accounts_code on accounts(user_id,account_code);
create index if not exists idx_accounts_parent on accounts(parent_account_id);
create index if not exists idx_accounts_report on accounts(user_id,report_class,account_code);

-- ------------------------------------------------------------
-- 2. Hierarchy and structural protections.
-- ------------------------------------------------------------
create or replace function validate_account_hierarchy()
returns trigger
language plpgsql
set search_path=public
as $$
declare
  v_parent_user uuid;
  v_cycle boolean;
begin
  if new.parent_account_id is null then return new; end if;
  if new.parent_account_id = new.id then raise exception 'An account cannot be its own parent.'; end if;

  select user_id into v_parent_user from accounts where id=new.parent_account_id;
  if v_parent_user is null or v_parent_user <> new.user_id then
    raise exception 'Parent account must belong to the same business.';
  end if;

  with recursive ancestors(id,parent_account_id) as (
    select id,parent_account_id from accounts where id=new.parent_account_id
    union all
    select a.id,a.parent_account_id from accounts a join ancestors x on a.id=x.parent_account_id
  )
  select exists(select 1 from ancestors where id=new.id) into v_cycle;
  if v_cycle then raise exception 'Account hierarchy cannot contain a cycle.'; end if;
  return new;
end;
$$;

drop trigger if exists trg_validate_account_hierarchy on accounts;
create trigger trg_validate_account_hierarchy
before insert or update of parent_account_id,user_id on accounts
for each row execute function validate_account_hierarchy();

create or replace function protect_account_structure()
returns trigger
language plpgsql
set search_path=public
as $$
declare
  v_has_entries boolean;
  v_has_children boolean;
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
    if v_has_entries then raise exception 'An account with ledger entries cannot be deactivated.'; end if;
    select exists(select 1 from accounts where parent_account_id=old.id and is_active) into v_has_children;
    if v_has_children then raise exception 'Deactivate or move child accounts first.'; end if;
  end if;

  if new.opening_balance is distinct from old.opening_balance
     or new.opening_balance_type is distinct from old.opening_balance_type then
    if current_user in ('anon','authenticated') then
      raise exception 'Opening balances must be posted through a balanced opening journal.';
    end if;
  end if;

  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists trg_protect_account_structure on accounts;
create trigger trg_protect_account_structure
before update on accounts
for each row execute function protect_account_structure();

-- ------------------------------------------------------------
-- 3. Helpers and controlled account RPCs.
-- ------------------------------------------------------------
create or replace function next_structured_account_code(
  p_user_id uuid,
  p_report_class text,
  p_party_prefix text default null
)
returns text
language plpgsql
security definer
set search_path=public
as $$
declare
  v_prefix text;
  v_num integer;
begin
  v_prefix := case
    when p_party_prefix in ('AR','AP') then p_party_prefix
    when p_report_class='current_asset' then 'CA'
    when p_report_class='non_current_asset' then 'NCA'
    when p_report_class='current_liability' then 'CL'
    when p_report_class='non_current_liability' then 'NCL'
    when p_report_class='equity' then 'EQ'
    when p_report_class='revenue' then 'REV'
    when p_report_class='cost_of_sales' then 'COS'
    when p_report_class='operating_expense' then 'OPEX'
    when p_report_class='other_income' then 'OI'
    else 'OE'
  end;
  perform pg_advisory_xact_lock(hashtextextended(p_user_id::text || ':account-code:' || v_prefix,0));
  select coalesce(max(nullif(regexp_replace(account_code,'\D','','g'),'')::integer),0)+1
    into v_num from accounts where user_id=p_user_id and account_code like v_prefix || '-%';
  return v_prefix || '-' || lpad(v_num::text,4,'0');
end;
$$;

create or replace function create_structured_account(
  p_name text,
  p_account_code text,
  p_account_type text,
  p_report_class text,
  p_account_subtype text default 'general',
  p_normal_balance text default null,
  p_parent_account_id uuid default null,
  p_cash_flow_category text default 'operating',
  p_allow_manual_posting boolean default true
)
returns uuid
language plpgsql
security definer
set search_path=public
as $$
declare
  uid uuid:=auth.uid();
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

create or replace function update_structured_account(
  p_id uuid,
  p_name text,
  p_account_code text,
  p_account_type text,
  p_report_class text,
  p_account_subtype text,
  p_normal_balance text,
  p_parent_account_id uuid,
  p_cash_flow_category text,
  p_allow_manual_posting boolean
)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare uid uuid:=auth.uid(); v_old accounts%rowtype;
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
set search_path=public
as $$
declare uid uuid:=auth.uid();
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  update accounts set is_active=false where id=p_id and user_id=uid;
  if not found then raise exception 'Account not found.'; end if;
  perform write_audit_log('deactivate','accounts',p_id::text,null,null);
end;
$$;

revoke all on function next_structured_account_code(uuid,text,text) from public;
revoke all on function create_structured_account(text,text,text,text,text,text,uuid,text,boolean) from public;
revoke all on function update_structured_account(uuid,text,text,text,text,text,text,uuid,text,boolean) from public;
revoke all on function deactivate_structured_account(uuid) from public;
grant execute on function create_structured_account(text,text,text,text,text,text,uuid,text,boolean) to authenticated;
grant execute on function update_structured_account(uuid,text,text,text,text,text,text,uuid,text,boolean) to authenticated;
grant execute on function deactivate_structured_account(uuid) to authenticated;

-- ------------------------------------------------------------
-- 4. Balanced opening journal.
-- ------------------------------------------------------------
alter table vouchers drop constraint if exists vouchers_voucher_type_check;
alter table vouchers add constraint vouchers_voucher_type_check check (
  voucher_type in ('journal','payment','receipt','contra','sales','purchase','credit_note','debit_note','opening')
);

create table if not exists opening_journals(
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  fiscal_year text not null,
  opening_date date not null,
  voucher_id uuid unique references vouchers(id) on delete restrict,
  notes text,
  is_legacy_conversion boolean not null default false,
  created_at timestamptz not null default now()
);
create unique index if not exists uq_opening_journal_year on opening_journals(user_id,fiscal_year);
alter table opening_journals enable row level security;
drop policy if exists "own opening journals" on opening_journals;
create policy "own opening journals" on opening_journals for select using(auth.uid()=user_id);
grant select on opening_journals to authenticated;
revoke insert,update,delete on opening_journals from authenticated;

create or replace function post_opening_journal(
  p_fiscal_year text,
  p_date date,
  p_lines jsonb,
  p_notes text default null
)
returns uuid
language plpgsql
security definer
set search_path=public
as $$
declare
  uid uuid:=auth.uid();
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

create or replace function migrate_legacy_opening_balances(
  p_fiscal_year text,
  p_date date,
  p_offset_account_id uuid default null,
  p_notes text default 'Converted from legacy opening-balance fields'
)
returns uuid
language plpgsql
security definer
set search_path=public
as $$
declare
  uid uuid:=auth.uid();
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

revoke all on function post_opening_journal(text,date,jsonb,text) from public;
revoke all on function migrate_legacy_opening_balances(text,date,uuid,text) from public;
grant execute on function post_opening_journal(text,date,jsonb,text) to authenticated;
grant execute on function migrate_legacy_opening_balances(text,date,uuid,text) to authenticated;

-- ------------------------------------------------------------
-- 5. Structured system-account resolver and seed.
-- ------------------------------------------------------------
create or replace function resolve_system_account(p_code text)
returns uuid
language plpgsql
security definer
set search_path=public
as $$
declare uid uuid:=auth.uid(); acc_id uuid; v record;
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
    ('inventory_opening','3100','Inventory Opening Equity','equity','equity','opening_equity','credit','financing',false,false),
    ('sales','4000','Sales Account','income','revenue','sales','credit','operating',false,false),
    ('purchase','5000','Purchase Account','expense','cost_of_sales','purchases','debit','operating',false,false),
    ('cogs','5100','Cost of Goods Sold','expense','cost_of_sales','cost_of_goods_sold','debit','operating',false,false),
    ('stock_adjustment','5200','Stock Adjustment','expense','cost_of_sales','stock_adjustment','debit','operating',false,false),
    ('purchase_return','5210','Purchase Return','expense','cost_of_sales','purchase_return','debit','operating',false,false)
  ) x(code,acct_code,name,acct_type,report_class,subtype,normal,cf,is_control,allow_manual)
  where code=p_code;
  if not found then raise exception 'Unknown system account code: %',p_code; end if;

  insert into accounts(
    user_id,name,account_code,account_type,group_name,report_class,account_subtype,normal_balance,cash_flow_category,
    is_party_account,is_control_account,is_system_account,allow_manual_posting,opening_balance,opening_balance_type,system_code
  ) values(
    uid,v.name,v.acct_code,v.acct_type,replace(initcap(replace(v.report_class,'_',' ')),' And ',' & '),v.report_class,v.subtype,v.normal,v.cf,
    false,v.is_control,true,v.allow_manual,0,v.normal,p_code
  ) returning id into acc_id;
  return acc_id;
end;
$$;

create or replace function seed_default_accounts()
returns void
language plpgsql
security definer
set search_path=public
as $$
declare uid uuid:=auth.uid();
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  perform resolve_system_account('cash');
  perform resolve_system_account('bank');
  perform resolve_system_account('sales');
  perform resolve_system_account('purchase');
  perform resolve_system_account('vat_payable');
  perform resolve_system_account('vat_receivable');
  perform resolve_system_account('ar_control');
  perform resolve_system_account('ap_control');
  perform resolve_system_account('inventory_asset');
  perform resolve_system_account('cogs');
  if not exists(select 1 from accounts where user_id=uid and account_subtype='capital') then
    perform create_structured_account('Capital Account','3000','equity','equity','capital','credit',null,'financing',true);
  end if;
  if not exists(select 1 from accounts where user_id=uid and account_subtype='drawings') then
    perform create_structured_account('Drawings','3010','equity','equity','drawings','debit',null,'financing',true);
  end if;
end;
$$;

-- Contact creation now creates a structured sub-ledger account. Opening
-- balances are intentionally rejected and must use the opening journal.
create or replace function create_contact(
  p_name text, p_name_np text default null, p_is_customer boolean default true,
  p_is_vendor boolean default false, p_contact_person text default null,
  p_phone text default null, p_email text default null,
  p_billing_address text default null, p_shipping_address text default null,
  p_pan_number text default null, p_vat_number text default null,
  p_payment_terms_days integer default null, p_tds_applicable boolean default false,
  p_tds_rate numeric default null, p_notes text default null,
  p_opening_balance numeric default 0, p_opening_balance_type text default 'debit'
)
returns uuid
language plpgsql
security definer
set search_path=public
as $$
declare uid uuid:=auth.uid(); v_acct uuid; v_party uuid; v_type text; v_code text;
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
  v_type:=case when p_is_customer and p_is_vendor then 'both' when p_is_customer then 'customer' else 'vendor' end;
  insert into parties(user_id,account_id,party_type,name_np,contact_person,is_customer,is_vendor,phone,email,address,billing_address,shipping_address,pan_vat_number,pan_number,vat_number,payment_terms_days,tds_applicable,tds_rate,notes,is_active)
  values(uid,v_acct,v_type,p_name_np,p_contact_person,p_is_customer,p_is_vendor,p_phone,p_email,p_billing_address,p_billing_address,p_shipping_address,p_pan_number,p_pan_number,p_vat_number,p_payment_terms_days,coalesce(p_tds_applicable,false),p_tds_rate,p_notes,true)
  returning id into v_party;
  perform write_audit_log('create','parties',v_party::text,null,jsonb_build_object('name',p_name,'account_code',v_code));
  return v_party;
end;
$$;

-- ------------------------------------------------------------
-- 6. Structured balances and reports.
-- ------------------------------------------------------------
drop view if exists trial_balance;
create view trial_balance with (security_invoker=true) as
with movements as (
  select a.id account_id,a.user_id,a.account_code,a.name,a.account_type,a.group_name,
         a.report_class,a.account_subtype,a.normal_balance,a.parent_account_id,
         (case when a.opening_balance_type='debit' then a.opening_balance else -a.opening_balance end)
         +coalesce(sum(case when v.is_void=false then vl.debit-vl.credit else 0 end),0) balance
  from accounts a
  left join voucher_lines vl on vl.account_id=a.id
  left join vouchers v on v.id=vl.voucher_id
  where a.is_active
  group by a.id
)
select account_id,user_id,account_code,name,account_type,group_name,report_class,account_subtype,normal_balance,parent_account_id,
       case when balance>=0 then balance else 0 end debit,
       case when balance<0 then -balance else 0 end credit
from movements where abs(balance)>0.005;

grant select on trial_balance to authenticated;

create or replace function get_dashboard_stats()
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  uid uuid:=auth.uid(); result jsonb;
  v_cash numeric; v_receivables numeric; v_payables numeric;
  v_sales_this numeric; v_sales_last numeric; v_vat_payable numeric;
  v_stock_value numeric; v_low_stock integer; v_invoice_count integer; v_overdue_count integer;
  v_overdue_amount numeric; v_invoice_outstanding numeric; v_bill_outstanding numeric;
  this_month_start date; last_month_start date; last_month_end date;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  this_month_start:=date_trunc('month',current_date)::date;
  last_month_start:=(date_trunc('month',current_date)-interval '1 month')::date;
  last_month_end:=(this_month_start-1)::date;

  with balances as (
    select a.id,a.account_subtype,a.report_class,
      (case when a.opening_balance_type='debit' then a.opening_balance else -a.opening_balance end)
      +coalesce(sum(case when v.is_void=false then vl.debit-vl.credit else 0 end),0) balance
    from accounts a left join voucher_lines vl on vl.account_id=a.id left join vouchers v on v.id=vl.voucher_id
    where a.user_id=uid and a.is_active group by a.id
  )
  select coalesce(sum(balance) filter(where account_subtype in ('cash','bank')),0),
         coalesce(sum(balance) filter(where account_subtype in ('receivable','receivable_control')),0),
         coalesce(sum(-balance) filter(where account_subtype in ('payable','payable_control')),0)
  into v_cash,v_receivables,v_payables from balances;

  select coalesce(sum(case when invoice_date>=this_month_start then subtotal else 0 end),0)
      -coalesce((select sum(subtotal) from credit_notes where user_id=uid and document_status='posted' and cn_date>=this_month_start),0),
    coalesce(sum(case when invoice_date between last_month_start and last_month_end then subtotal else 0 end),0)
      -coalesce((select sum(subtotal) from credit_notes where user_id=uid and document_status='posted' and cn_date between last_month_start and last_month_end),0)
  into v_sales_this,v_sales_last from invoices where user_id=uid and document_status in ('posted','credited');

  select coalesce((select sum(vat_amount) from invoices where user_id=uid and document_status in ('posted','credited') and invoice_date>=this_month_start),0)
    -coalesce((select sum(vat_amount) from credit_notes where user_id=uid and document_status='posted' and cn_date>=this_month_start),0)
    -coalesce((select sum(vat_amount) from purchase_bills where user_id=uid and document_status in ('posted','credited') and bill_date>=this_month_start),0)
    +coalesce((select sum(vat_amount) from debit_notes where user_id=uid and document_status='posted' and dn_date>=this_month_start),0)
  into v_vat_payable;

  select coalesce(sum(inventory_value),0),count(*) filter(where current_stock<=reorder_level)::integer
  into v_stock_value,v_low_stock from inventory_items where user_id=uid and is_active and item_type='goods' and track_inventory;
  select count(*)::integer,count(*) filter(where due_date<current_date and outstanding_amount>0.005 and status in ('open','partial','overdue'))::integer,
    coalesce(sum(outstanding_amount) filter(where due_date<current_date and outstanding_amount>0.005 and status in ('open','partial','overdue')),0),coalesce(sum(outstanding_amount),0)
  into v_invoice_count,v_overdue_count,v_overdue_amount,v_invoice_outstanding from invoices where user_id=uid and document_status='posted';
  select coalesce(sum(outstanding_amount),0) into v_bill_outstanding from purchase_bills where user_id=uid and document_status='posted';
  return jsonb_build_object('cash',v_cash,'receivables',v_receivables,'payables',v_payables,'sales_this',v_sales_this,'sales_last',v_sales_last,
    'vat_payable',v_vat_payable,'stock_value',v_stock_value,'low_stock',v_low_stock,'invoice_count',v_invoice_count,'overdue_count',v_overdue_count,
    'overdue_amount',v_overdue_amount,'invoice_outstanding',v_invoice_outstanding,'bill_outstanding',v_bill_outstanding,
    'vat_deadline',to_char(date_trunc('month',current_date)+interval '1 month'+interval '14 days','YYYY-MM-DD'));
end;
$$;
revoke all on function get_dashboard_stats() from public;
grant execute on function get_dashboard_stats() to authenticated;

-- Browser clients can read accounts, but mutations must use RPCs.
grant select on accounts to authenticated;
revoke insert,update,delete on accounts from authenticated;

commit;
