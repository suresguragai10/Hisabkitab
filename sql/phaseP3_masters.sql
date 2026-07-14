-- ============================================================
-- HisabKitab — Phase P3: Masters Unification
-- ============================================================
-- Turns the shallow "Parties" and free-text-category "Inventory Items"
-- into professional-grade masters that a CA actually wants to work with.
--
-- What this migration does:
--   1. Enhances `parties` with fields a real CA needs (is_customer /
--      is_vendor booleans, separate PAN/VAT, TDS, payment terms,
--      Devanagari name, billing/shipping addresses, notes).
--   2. Creates a real `item_categories` table with FK integrity.
--   3. Enhances `inventory_items` with the fields a CA + IRD invoice
--      need (HSN, brand, SKU, Devanagari name, default sales/purchase
--      accounts and tax rates, preferred vendor, item_type, track flag,
--      opening stock).
--   4. Migrates existing data — no data loss, no manual work required.
--   5. Adds RPC helpers `create_contact`, `create_item`,
--      `create_item_category` for atomic creation with backing accounts.
--
-- Design principle: ADDITIVE. Every existing column is kept. Old app
-- pages keep working. New pages read from the enhanced masters. This
-- lets you ship the new UX one page at a time without breaking anything.
--
-- Safety: every statement is idempotent (IF NOT EXISTS / OR REPLACE /
-- ALTER TABLE ADD COLUMN IF NOT EXISTS). Safe to re-run.
--
-- Run: Supabase Dashboard → SQL Editor → New query → paste → Run.
-- ============================================================


-- ============================================================
-- SECTION 1 — CONTACTS (enhanced `parties` table)
-- ============================================================
-- The table stays named `parties` for backward compatibility with all
-- existing FKs (invoices.party_id, purchase_bills.party_id, etc). The
-- UX presents it as "Contacts". Every new column is nullable so
-- existing rows remain valid.
-- ============================================================

alter table parties add column if not exists name_np text;
alter table parties add column if not exists contact_person text;
alter table parties add column if not exists is_customer boolean;
alter table parties add column if not exists is_vendor boolean;
alter table parties add column if not exists billing_address text;
alter table parties add column if not exists shipping_address text;
alter table parties add column if not exists pan_number text;
alter table parties add column if not exists vat_number text;
alter table parties add column if not exists payment_terms_days integer;
alter table parties add column if not exists tds_applicable boolean not null default false;
alter table parties add column if not exists tds_rate numeric(5,2);
alter table parties add column if not exists notes text;
alter table parties add column if not exists is_active boolean not null default true;
alter table parties add column if not exists updated_at timestamptz not null default now();

-- Data migration: only for existing rows that haven't been split yet.
update parties
set is_customer = case when party_type in ('customer','both') then true else false end,
    is_vendor   = case when party_type in ('vendor','both')   then true else false end
where is_customer is null or is_vendor is null;

-- pan_vat_number was overloaded (some CAs put PAN, some VAT). Copy it
-- to pan_number by default; the user can move it to vat_number later.
update parties
set pan_number = pan_vat_number
where pan_number is null and pan_vat_number is not null;

-- Older `address` column becomes the billing_address.
update parties
set billing_address = address
where billing_address is null and address is not null;

-- Now that data is populated, add checks + defaults.
alter table parties alter column is_customer set default false;
alter table parties alter column is_vendor   set default false;
alter table parties alter column is_customer set not null;
alter table parties alter column is_vendor   set not null;

-- A contact must be at least one role.
do $$ begin
  if not exists (
    select 1 from pg_constraint where conname = 'parties_role_check'
  ) then
    alter table parties add constraint parties_role_check
      check (is_customer or is_vendor);
  end if;
end $$;

create index if not exists idx_parties_is_customer on parties(is_customer) where is_customer;
create index if not exists idx_parties_is_vendor   on parties(is_vendor)   where is_vendor;
create index if not exists idx_parties_active      on parties(is_active)   where is_active;


-- ============================================================
-- SECTION 2 — ITEM CATEGORIES (new table)
-- ============================================================
-- Replaces the free-text `category` column on inventory_items with a
-- real relational category. Supports nesting via parent_id so a CA can
-- have "Beverages > Energy Drinks" if they want.
-- ============================================================

create table if not exists item_categories (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references auth.users(id) on delete cascade,
  name         text not null,
  name_np      text,
  parent_id    uuid references item_categories(id) on delete set null,
  sort_order   integer not null default 0,
  notes        text,
  is_active    boolean not null default true,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (user_id, name)
);

create index if not exists idx_item_categories_user on item_categories(user_id);
create index if not exists idx_item_categories_parent on item_categories(parent_id);

alter table item_categories enable row level security;

drop policy if exists cat_all on item_categories;
create policy cat_all on item_categories for all
  using (auth.uid() = user_id) with check (auth.uid() = user_id);


-- ============================================================
-- SECTION 3 — ITEMS (enhanced `inventory_items` table)
-- ============================================================
-- Table name stays `inventory_items` for FK compatibility. Existing
-- columns kept; new columns added; data migrated.
-- ============================================================

alter table inventory_items add column if not exists name_np text;
alter table inventory_items add column if not exists sku text;
alter table inventory_items add column if not exists hsn_code text;
alter table inventory_items add column if not exists brand text;
alter table inventory_items add column if not exists category_id uuid references item_categories(id) on delete set null;
alter table inventory_items add column if not exists item_type text not null default 'goods'
  check (item_type in ('goods','service','non_inventory'));
alter table inventory_items add column if not exists sales_tax_rate numeric(5,2) not null default 13;
alter table inventory_items add column if not exists sales_account_id uuid references accounts(id) on delete set null;
alter table inventory_items add column if not exists purchase_tax_rate numeric(5,2) not null default 13;
alter table inventory_items add column if not exists purchase_account_id uuid references accounts(id) on delete set null;
alter table inventory_items add column if not exists preferred_vendor_id uuid references parties(id) on delete set null;
alter table inventory_items add column if not exists track_inventory boolean not null default true;
alter table inventory_items add column if not exists opening_stock numeric(14,3) not null default 0;
alter table inventory_items add column if not exists opening_stock_value numeric(14,2) not null default 0;
alter table inventory_items add column if not exists updated_at timestamptz not null default now();

-- Alias new price names to old ones so old code (using selling_price /
-- cost_price) keeps working AND new code (using sales_price /
-- purchase_price) sees the same value. Implemented as generated columns
-- that read the existing columns.
--
-- We use IF NOT EXISTS on the alter to make it re-runnable.
do $$ begin
  if not exists (
    select 1 from information_schema.columns
    where table_name='inventory_items' and column_name='sales_price'
  ) then
    alter table inventory_items add column sales_price numeric(14,2)
      generated always as (selling_price) stored;
  end if;
  if not exists (
    select 1 from information_schema.columns
    where table_name='inventory_items' and column_name='purchase_price'
  ) then
    alter table inventory_items add column purchase_price numeric(14,2)
      generated always as (cost_price) stored;
  end if;
end $$;

-- Data migration: for each unique free-text category on inventory_items,
-- create an item_categories row (per user) and link it via category_id.
do $$
declare
  r record;
  cat_id uuid;
begin
  for r in
    select distinct user_id, category
    from inventory_items
    where category is not null and category <> '' and category_id is null
  loop
    insert into item_categories (user_id, name)
    values (r.user_id, r.category)
    on conflict (user_id, name) do nothing;

    select id into cat_id
    from item_categories
    where user_id = r.user_id and name = r.category;

    update inventory_items
    set category_id = cat_id
    where user_id = r.user_id and category = r.category and category_id is null;
  end loop;
end $$;

create index if not exists idx_items_category on inventory_items(category_id);
create index if not exists idx_items_brand    on inventory_items(brand) where brand is not null;
create index if not exists idx_items_active   on inventory_items(is_active) where is_active;


-- ============================================================
-- SECTION 4 — INVOICE + BILL LINES: HSN snapshot
-- ============================================================
-- Store HSN on the line at post time so that when the item's HSN is
-- changed later, historic invoices still print correctly. Also useful
-- for VAT purchase/sales register grouping by HSN.
-- ============================================================

alter table invoice_lines       add column if not exists hsn_code text;
alter table purchase_bill_lines add column if not exists hsn_code text;


-- ============================================================
-- SECTION 5 — RPC: create_contact
-- ============================================================
-- Atomically creates a contact (parties row) plus the backing sub-
-- ledger account(s) it needs based on role.
--
--   * customer only  → one AR sub-ledger account under Sundry Debtors
--   * vendor only    → one AP sub-ledger account under Sundry Creditors
--   * both           → same as customer (single account); most Nepali
--                       businesses run "both" contacts through a single
--                       ledger. If the user wants separate AR and AP
--                       for the same contact, they can create two
--                       contact rows. This mirrors what Odoo does by
--                       default and keeps the ledger simpler for SMBs.
-- ============================================================

create or replace function create_contact(
  p_name                text,
  p_name_np             text default null,
  p_is_customer         boolean default true,
  p_is_vendor           boolean default false,
  p_contact_person      text default null,
  p_phone               text default null,
  p_email               text default null,
  p_billing_address     text default null,
  p_shipping_address    text default null,
  p_pan_number          text default null,
  p_vat_number          text default null,
  p_payment_terms_days  integer default null,
  p_tds_applicable      boolean default false,
  p_tds_rate            numeric default null,
  p_notes               text default null,
  p_opening_balance     numeric default 0,
  p_opening_balance_type text default 'debit'
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  v_acct uuid;
  v_party uuid;
  v_group text;
  v_acct_type text;
  v_party_type text;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  if not (p_is_customer or p_is_vendor) then
    raise exception 'Contact must be at least a customer or a vendor';
  end if;

  -- Backing account: default to Debtors when a role includes customer,
  -- otherwise Creditors. (A pure vendor gets AP.)
  if p_is_customer then
    v_group := 'Sundry Debtors';
    v_acct_type := 'asset';
  else
    v_group := 'Sundry Creditors';
    v_acct_type := 'liability';
  end if;

  insert into accounts (user_id, name, account_type, group_name,
                        is_party_account, opening_balance, opening_balance_type)
  values (uid, p_name, v_acct_type, v_group, true,
          coalesce(p_opening_balance, 0),
          coalesce(p_opening_balance_type, 'debit'))
  returning id into v_acct;

  -- Derive the legacy party_type value for backward compat with any
  -- code that still reads it.
  v_party_type := case
    when p_is_customer and p_is_vendor then 'both'
    when p_is_customer then 'customer'
    else 'vendor'
  end;

  insert into parties (
    user_id, account_id, party_type, name_np, contact_person,
    is_customer, is_vendor, phone, email,
    address, billing_address, shipping_address,
    pan_vat_number, pan_number, vat_number,
    payment_terms_days, tds_applicable, tds_rate, notes,
    is_active
  ) values (
    uid, v_acct, v_party_type, p_name_np, p_contact_person,
    p_is_customer, p_is_vendor, p_phone, p_email,
    p_billing_address, p_billing_address, p_shipping_address,
    p_pan_number, p_pan_number, p_vat_number,
    p_payment_terms_days, coalesce(p_tds_applicable,false), p_tds_rate, p_notes,
    true
  ) returning id into v_party;

  perform write_audit_log('create','parties', v_party::text, null,
    jsonb_build_object('name', p_name, 'is_customer', p_is_customer, 'is_vendor', p_is_vendor));

  return v_party;
end;
$$;

grant execute on function create_contact(
  text, text, boolean, boolean, text, text, text, text, text,
  text, text, integer, boolean, numeric, text, numeric, text
) to authenticated;


-- ============================================================
-- SECTION 6 — RPC: update_contact
-- ============================================================
-- Updates the mutable fields of a contact. The name change also
-- updates the backing account name so ledger reports stay in sync.
-- ============================================================

create or replace function update_contact(
  p_id                  uuid,
  p_name                text,
  p_name_np             text default null,
  p_is_customer         boolean default null,
  p_is_vendor           boolean default null,
  p_contact_person      text default null,
  p_phone               text default null,
  p_email               text default null,
  p_billing_address     text default null,
  p_shipping_address    text default null,
  p_pan_number          text default null,
  p_vat_number          text default null,
  p_payment_terms_days  integer default null,
  p_tds_applicable      boolean default null,
  p_tds_rate            numeric default null,
  p_notes               text default null,
  p_is_active           boolean default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  v_acct uuid;
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
  returning account_id into v_acct;

  if v_acct is not null then
    update accounts set name = p_name where id = v_acct and user_id = uid;
  end if;

  perform write_audit_log('update','parties', p_id::text, null,
    jsonb_build_object('name', p_name));
end;
$$;

grant execute on function update_contact(
  uuid, text, text, boolean, boolean, text, text, text, text, text,
  text, text, integer, boolean, numeric, text, boolean
) to authenticated;


-- ============================================================
-- SECTION 7 — RPC: create_item_category
-- ============================================================

create or replace function create_item_category(
  p_name     text,
  p_name_np  text default null,
  p_parent_id uuid default null,
  p_notes    text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  v_id uuid;
begin
  if uid is null then raise exception 'Not authenticated'; end if;

  insert into item_categories (user_id, name, name_np, parent_id, notes)
  values (uid, p_name, p_name_np, p_parent_id, p_notes)
  on conflict (user_id, name) do update
    set name_np = excluded.name_np, notes = excluded.notes, updated_at = now()
  returning id into v_id;

  return v_id;
end;
$$;

grant execute on function create_item_category(text, text, uuid, text) to authenticated;


-- ============================================================
-- SECTION 8 — RPC: create_item
-- ============================================================
-- Creates an item with proper category linkage + sensible default
-- accounts if the caller didn't specify them.
-- ============================================================

create or replace function create_item(
  p_name              text,
  p_name_np           text default null,
  p_sku               text default null,
  p_hsn_code          text default null,
  p_brand             text default null,
  p_category_id       uuid default null,
  p_item_type         text default 'goods',
  p_unit              text default 'pcs',
  p_sales_price       numeric default 0,
  p_sales_tax_rate    numeric default 13,
  p_sales_account_id  uuid default null,
  p_purchase_price    numeric default 0,
  p_purchase_tax_rate numeric default 13,
  p_purchase_account_id uuid default null,
  p_preferred_vendor_id uuid default null,
  p_track_inventory   boolean default true,
  p_opening_stock     numeric default 0,
  p_opening_stock_value numeric default 0,
  p_reorder_level     numeric default 0,
  p_description       text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  v_id uuid;
  v_sales_acct uuid := p_sales_account_id;
  v_purch_acct uuid := p_purchase_account_id;
begin
  if uid is null then raise exception 'Not authenticated'; end if;

  -- If the caller didn't specify accounts, fall back to system accounts
  -- (Sales for income, Purchase for expense). resolve_system_account
  -- was introduced in Phase P0.
  if v_sales_acct is null then
    begin
      v_sales_acct := resolve_system_account('sales');
    exception when others then null; end;
  end if;
  if v_purch_acct is null then
    begin
      v_purch_acct := resolve_system_account('purchase');
    exception when others then null; end;
  end if;

  insert into inventory_items (
    user_id, name, name_np, sku, hsn_code, brand, category_id,
    category, item_type, unit,
    selling_price, sales_tax_rate, sales_account_id,
    cost_price, purchase_tax_rate, purchase_account_id,
    preferred_vendor_id, track_inventory,
    opening_stock, opening_stock_value, current_stock,
    reorder_level, description, is_active
  ) values (
    uid, p_name, p_name_np, p_sku, p_hsn_code, p_brand, p_category_id,
    coalesce((select name from item_categories where id = p_category_id), 'General'),
    coalesce(p_item_type,'goods'), coalesce(p_unit,'pcs'),
    coalesce(p_sales_price,0), coalesce(p_sales_tax_rate,13), v_sales_acct,
    coalesce(p_purchase_price,0), coalesce(p_purchase_tax_rate,13), v_purch_acct,
    p_preferred_vendor_id, coalesce(p_track_inventory,true),
    coalesce(p_opening_stock,0), coalesce(p_opening_stock_value,0), coalesce(p_opening_stock,0),
    coalesce(p_reorder_level,0), p_description, true
  ) returning id into v_id;

  perform write_audit_log('create','inventory_items', v_id::text, null,
    jsonb_build_object('name', p_name, 'category_id', p_category_id, 'sku', p_sku));

  return v_id;
end;
$$;

grant execute on function create_item(
  text, text, text, text, text, uuid, text, text,
  numeric, numeric, uuid,
  numeric, numeric, uuid,
  uuid, boolean, numeric, numeric, numeric, text
) to authenticated;


-- ============================================================
-- SECTION 9 — RPC: update_item
-- ============================================================

create or replace function update_item(
  p_id                uuid,
  p_name              text default null,
  p_name_np           text default null,
  p_sku               text default null,
  p_hsn_code          text default null,
  p_brand             text default null,
  p_category_id       uuid default null,
  p_item_type         text default null,
  p_unit              text default null,
  p_sales_price       numeric default null,
  p_sales_tax_rate    numeric default null,
  p_sales_account_id  uuid default null,
  p_purchase_price    numeric default null,
  p_purchase_tax_rate numeric default null,
  p_purchase_account_id uuid default null,
  p_preferred_vendor_id uuid default null,
  p_track_inventory   boolean default null,
  p_reorder_level     numeric default null,
  p_description       text default null,
  p_is_active         boolean default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
begin
  if uid is null then raise exception 'Not authenticated'; end if;

  update inventory_items set
    name                = coalesce(p_name, name),
    name_np             = coalesce(p_name_np, name_np),
    sku                 = coalesce(p_sku, sku),
    hsn_code            = coalesce(p_hsn_code, hsn_code),
    brand               = coalesce(p_brand, brand),
    category_id         = coalesce(p_category_id, category_id),
    category            = coalesce((select name from item_categories where id = coalesce(p_category_id, category_id)), category),
    item_type           = coalesce(p_item_type, item_type),
    unit                = coalesce(p_unit, unit),
    selling_price       = coalesce(p_sales_price, selling_price),
    sales_tax_rate      = coalesce(p_sales_tax_rate, sales_tax_rate),
    sales_account_id    = coalesce(p_sales_account_id, sales_account_id),
    cost_price          = coalesce(p_purchase_price, cost_price),
    purchase_tax_rate   = coalesce(p_purchase_tax_rate, purchase_tax_rate),
    purchase_account_id = coalesce(p_purchase_account_id, purchase_account_id),
    preferred_vendor_id = coalesce(p_preferred_vendor_id, preferred_vendor_id),
    track_inventory     = coalesce(p_track_inventory, track_inventory),
    reorder_level       = coalesce(p_reorder_level, reorder_level),
    description         = coalesce(p_description, description),
    is_active           = coalesce(p_is_active, is_active),
    updated_at          = now()
  where id = p_id and user_id = uid;

  perform write_audit_log('update','inventory_items', p_id::text, null,
    jsonb_build_object('name', p_name));
end;
$$;

grant execute on function update_item(
  uuid, text, text, text, text, text, uuid, text, text,
  numeric, numeric, uuid, numeric, numeric, uuid,
  uuid, boolean, numeric, text, boolean
) to authenticated;


-- ============================================================
-- SECTION 10 — Convenience view: contact_summary
-- ============================================================
-- One row per contact with the fields the Contacts list needs, plus
-- current outstanding balance from the ledger. The Contacts page reads
-- from this view.
-- ============================================================

create or replace view contact_summary as
select
  p.id,
  p.user_id,
  a.name,
  p.name_np,
  p.contact_person,
  p.is_customer,
  p.is_vendor,
  case
    when p.is_customer and p.is_vendor then 'both'
    when p.is_customer then 'customer'
    else 'vendor'
  end as role,
  p.phone,
  p.email,
  coalesce(p.billing_address, p.address) as billing_address,
  p.shipping_address,
  coalesce(p.pan_number, p.pan_vat_number) as pan_number,
  p.vat_number,
  p.payment_terms_days,
  p.tds_applicable,
  p.tds_rate,
  p.notes,
  p.is_active,
  a.id as account_id,
  a.opening_balance,
  a.opening_balance_type,
  -- Outstanding = opening + posted_debits - posted_credits
  --   Positive for a customer = they owe you.
  --   Negative for a vendor account (liability) = you owe them.
  (case a.opening_balance_type when 'debit' then a.opening_balance else -a.opening_balance end)
  + coalesce((
      select sum(vl.debit - vl.credit)
      from voucher_lines vl join vouchers v on v.id = vl.voucher_id
      where vl.account_id = a.id and not v.is_void
  ),0) as outstanding,
  p.created_at,
  p.updated_at
from parties p
join accounts a on a.id = p.account_id;

grant select on contact_summary to authenticated;


-- ============================================================
-- SECTION 11 — Convenience view: item_summary
-- ============================================================

create or replace view item_summary as
select
  i.id,
  i.user_id,
  i.name,
  i.name_np,
  i.sku,
  i.hsn_code,
  i.brand,
  i.category_id,
  c.name as category_name,
  i.item_type,
  i.unit,
  i.selling_price   as sales_price,
  i.sales_tax_rate,
  i.sales_account_id,
  i.cost_price      as purchase_price,
  i.purchase_tax_rate,
  i.purchase_account_id,
  i.preferred_vendor_id,
  pv_a.name as preferred_vendor_name,
  i.track_inventory,
  i.current_stock,
  i.reorder_level,
  case when i.reorder_level > 0 and i.current_stock <= i.reorder_level
       then true else false end as is_low_stock,
  i.description,
  i.is_active,
  i.created_at,
  i.updated_at
from inventory_items i
left join item_categories c on c.id = i.category_id
left join parties pv on pv.id = i.preferred_vendor_id
left join accounts pv_a on pv_a.id = pv.account_id;

grant select on item_summary to authenticated;


-- ============================================================
-- End of Phase P3 — Masters Unification.
-- ============================================================
-- Next: ship Contacts.jsx, Items.jsx, ItemCategories.jsx that read
-- from these enhanced masters, and rewire the Invoice/Bill line
-- pickers to autofill from item defaults.
-- ============================================================
