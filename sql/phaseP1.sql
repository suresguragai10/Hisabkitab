-- ============================================================
-- HisabKitab — Phase P1: Trust & Compliance
-- Run ONCE in Supabase → SQL Editor → New query. Safe to re-run.
-- ============================================================


-- ------------------------------------------------------------
-- 1. Business Profile table — replaces localStorage
-- ------------------------------------------------------------
create table if not exists business_profile (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null unique references auth.users(id) on delete cascade,
  biz_name        text not null default '',
  biz_name_np     text not null default '',
  address         text not null default '',
  city            text not null default '',
  pan_vat         text not null default '',
  phone           text not null default '',
  email           text not null default '',
  invoice_prefix  text not null default '',
  updated_at      timestamptz not null default now()
);

alter table business_profile enable row level security;

drop policy if exists "own profile" on business_profile;
create policy "own profile" on business_profile for all
  using (auth.uid() = user_id) with check (auth.uid() = user_id);


-- ------------------------------------------------------------
-- 2. get_or_create_business_profile — called by the app on load
-- ------------------------------------------------------------
create or replace function get_or_create_business_profile()
returns setof business_profile
language plpgsql security definer set search_path = public
as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  -- create a blank row if this user has no profile yet
  insert into business_profile (user_id)
  values (uid)
  on conflict (user_id) do nothing;
  return query select * from business_profile where user_id = uid;
end; $$;
grant execute on function get_or_create_business_profile() to authenticated;


-- ------------------------------------------------------------
-- 3. save_business_profile — called when user clicks Save
-- ------------------------------------------------------------
create or replace function save_business_profile(
  p_biz_name       text default '',
  p_biz_name_np    text default '',
  p_address        text default '',
  p_city           text default '',
  p_pan_vat        text default '',
  p_phone          text default '',
  p_email          text default '',
  p_invoice_prefix text default ''
)
returns void
language plpgsql security definer set search_path = public
as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'Not authenticated'; end if;
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
grant execute on function save_business_profile(text,text,text,text,text,text,text,text) to authenticated;


-- ------------------------------------------------------------
-- 4. Add BS date + reprint columns to invoices
--    (these columns are used by the new invoice print view)
-- ------------------------------------------------------------
alter table invoices add column if not exists invoice_date_bs text;
alter table invoices add column if not exists due_date_bs     text;
alter table invoices add column if not exists is_reprint      boolean not null default false;
alter table invoices add column if not exists reprint_count   integer not null default 0;

-- Backfill BS date for existing invoices using a simple approximation
-- (the app will compute the precise BS date on next save)
update invoices set invoice_date_bs = '' where invoice_date_bs is null;


-- ------------------------------------------------------------
-- 5. Sequence-safe numbering — prevents duplicate invoice/bill
--    numbers under concurrent saves
-- ------------------------------------------------------------
create table if not exists doc_sequences (
  user_id     uuid not null references auth.users(id) on delete cascade,
  doc_type    text not null,
  fiscal_year text not null,
  last_num    integer not null default 0,
  primary key (user_id, doc_type, fiscal_year)
);

alter table doc_sequences enable row level security;
drop policy if exists "own sequences" on doc_sequences;
create policy "own sequences" on doc_sequences for all
  using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- Atomic next-number function
create or replace function next_doc_number(p_doc_type text, p_fiscal_year text)
returns integer
language plpgsql security definer set search_path = public
as $$
declare
  uid uuid := auth.uid();
  n   integer;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  insert into doc_sequences (user_id, doc_type, fiscal_year, last_num)
  values (uid, p_doc_type, p_fiscal_year, 1)
  on conflict (user_id, doc_type, fiscal_year)
  do update set last_num = doc_sequences.last_num + 1
  returning last_num into n;
  return n;
end; $$;
grant execute on function next_doc_number(text,text) to authenticated;

-- Seed from existing data so new numbers don't collide with old ones
insert into doc_sequences (user_id, doc_type, fiscal_year, last_num)
  select user_id, 'invoice', fiscal_year, max(invoice_number)
    from invoices group by user_id, fiscal_year
on conflict (user_id, doc_type, fiscal_year) do update
  set last_num = greatest(doc_sequences.last_num, excluded.last_num);

insert into doc_sequences (user_id, doc_type, fiscal_year, last_num)
  select user_id, 'bill', fiscal_year, max(bill_number)
    from purchase_bills group by user_id, fiscal_year
on conflict (user_id, doc_type, fiscal_year) do update
  set last_num = greatest(doc_sequences.last_num, excluded.last_num);

insert into doc_sequences (user_id, doc_type, fiscal_year, last_num)
  select user_id, voucher_type, fiscal_year, max(voucher_number)
    from vouchers group by user_id, voucher_type, fiscal_year
on conflict (user_id, doc_type, fiscal_year) do update
  set last_num = greatest(doc_sequences.last_num, excluded.last_num);


-- ------------------------------------------------------------
-- 6. Update invoice/bill posting to use safe sequence numbers
-- ------------------------------------------------------------
create or replace function create_invoice_with_posting(p_header jsonb, p_lines jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  inv_id uuid; v_subtotal numeric(14,2); v_vat numeric(14,2); v_total numeric(14,2);
  debtor_acct uuid; v_id uuid; v_inv_num integer; v_fy text;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  v_fy := p_header->>'fiscal_year';
  select next_doc_number('invoice', v_fy) into v_inv_num;
  select coalesce(sum((l->>'amount')::numeric),0), coalesce(sum((l->>'vat_amount')::numeric),0)
    into v_subtotal, v_vat from jsonb_array_elements(p_lines) l;
  v_total := v_subtotal + v_vat;

  insert into invoices (
    user_id, invoice_number, fiscal_year, invoice_date, due_date,
    party_id, party_name, party_address, party_pan,
    subtotal, vat_amount, total, status, notes,
    invoice_date_bs, due_date_bs
  ) values (
    uid, v_inv_num, v_fy,
    (p_header->>'invoice_date')::date,
    nullif(p_header->>'due_date','')::date,
    nullif(p_header->>'party_id','')::uuid,
    p_header->>'party_name', p_header->>'party_address', p_header->>'party_pan',
    v_subtotal, v_vat, v_total,
    coalesce(p_header->>'status','sent'), p_header->>'notes',
    coalesce(p_header->>'invoice_date_bs',''),
    coalesce(p_header->>'due_date_bs','')
  ) returning id into inv_id;

  insert into invoice_lines (invoice_id, description, quantity, unit, rate, amount, vat_rate, vat_amount, line_total)
  select inv_id, l->>'description',
         coalesce((l->>'quantity')::numeric,1), coalesce(l->>'unit','pcs'),
         coalesce((l->>'rate')::numeric,0), coalesce((l->>'amount')::numeric,0),
         coalesce((l->>'vat_rate')::numeric,13), coalesce((l->>'vat_amount')::numeric,0),
         coalesce((l->>'line_total')::numeric,0)
  from jsonb_array_elements(p_lines) l;

  if nullif(p_header->>'party_id','') is not null then
    select account_id into debtor_acct from parties where id=(p_header->>'party_id')::uuid and user_id=uid;
  end if;
  if debtor_acct is null then debtor_acct := resolve_system_account('ar_control'); end if;

  v_id := post_voucher('sales', v_fy, (p_header->>'invoice_date')::date,
    'Sales Invoice #' || v_inv_num,
    jsonb_build_array(
      jsonb_build_object('account_id', debtor_acct,                          'debit', v_total,    'credit', 0,         'description', p_header->>'party_name'),
      jsonb_build_object('account_id', resolve_system_account('sales'),      'debit', 0,          'credit', v_subtotal, 'description', 'Sales'),
      jsonb_build_object('account_id', resolve_system_account('vat_payable'),'debit', 0,          'credit', v_vat,     'description', 'Output VAT 13%')
    ));

  update invoices set voucher_id = v_id where id = inv_id;
  perform write_audit_log('create','invoices', inv_id::text, null,
    jsonb_build_object('invoice_number', v_inv_num, 'total', v_total, 'party', p_header->>'party_name'));
  return inv_id;
end; $$;
grant execute on function create_invoice_with_posting(jsonb,jsonb) to authenticated;


create or replace function create_bill_with_posting(p_header jsonb, p_lines jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  bill_id uuid; v_subtotal numeric(14,2); v_vat numeric(14,2); v_total numeric(14,2);
  creditor_acct uuid; v_id uuid; v_bill_num integer; v_fy text;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  v_fy := p_header->>'fiscal_year';
  select next_doc_number('bill', v_fy) into v_bill_num;
  select coalesce(sum((l->>'amount')::numeric),0), coalesce(sum((l->>'vat_amount')::numeric),0)
    into v_subtotal, v_vat from jsonb_array_elements(p_lines) l;
  v_total := v_subtotal + v_vat;

  insert into purchase_bills (
    user_id, bill_number, fiscal_year, bill_date, due_date,
    vendor_id, vendor_name, vendor_address, vendor_pan, vendor_bill_ref,
    subtotal, vat_amount, total, status, notes
  ) values (
    uid, v_bill_num, v_fy,
    (p_header->>'bill_date')::date,
    nullif(p_header->>'due_date','')::date,
    nullif(p_header->>'vendor_id','')::uuid,
    p_header->>'vendor_name', p_header->>'vendor_address', p_header->>'vendor_pan', p_header->>'vendor_bill_ref',
    v_subtotal, v_vat, v_total,
    coalesce(p_header->>'status','unpaid'), p_header->>'notes'
  ) returning id into bill_id;

  insert into purchase_bill_lines (bill_id, description, quantity, unit, rate, amount, vat_rate, vat_amount, line_total)
  select bill_id, l->>'description',
         coalesce((l->>'quantity')::numeric,1), coalesce(l->>'unit','pcs'),
         coalesce((l->>'rate')::numeric,0), coalesce((l->>'amount')::numeric,0),
         coalesce((l->>'vat_rate')::numeric,13), coalesce((l->>'vat_amount')::numeric,0),
         coalesce((l->>'line_total')::numeric,0)
  from jsonb_array_elements(p_lines) l;

  if nullif(p_header->>'vendor_id','') is not null then
    select account_id into creditor_acct from parties where id=(p_header->>'vendor_id')::uuid and user_id=uid;
  end if;
  if creditor_acct is null then creditor_acct := resolve_system_account('ap_control'); end if;

  v_id := post_voucher('purchase', v_fy, (p_header->>'bill_date')::date,
    'Purchase Bill #' || v_bill_num,
    jsonb_build_array(
      jsonb_build_object('account_id', resolve_system_account('purchase'),      'debit', v_subtotal,'credit', 0,      'description','Purchase'),
      jsonb_build_object('account_id', resolve_system_account('vat_receivable'),'debit', v_vat,    'credit', 0,      'description','Input VAT 13%'),
      jsonb_build_object('account_id', creditor_acct,                           'debit', 0,        'credit', v_total,'description', p_header->>'vendor_name')
    ));

  update purchase_bills set voucher_id = v_id where id = bill_id;
  perform write_audit_log('create','purchase_bills', bill_id::text, null,
    jsonb_build_object('bill_number', v_bill_num, 'total', v_total, 'vendor', p_header->>'vendor_name'));
  return bill_id;
end; $$;
grant execute on function create_bill_with_posting(jsonb,jsonb) to authenticated;


-- ------------------------------------------------------------
-- 7. Audit trigger for party creation
-- ------------------------------------------------------------
create or replace function trg_party_create_audit()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into audit_log (user_id, action, table_name, record_id, new_data)
  values (auth.uid(), 'create', 'parties', NEW.id::text,
          jsonb_build_object('party_type', NEW.party_type));
  return NEW;
end; $$;

drop trigger if exists party_create_audit on parties;
create trigger party_create_audit
  after insert on parties for each row execute function trg_party_create_audit();
