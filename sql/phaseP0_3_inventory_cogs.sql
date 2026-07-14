-- ============================================================
-- HisabKitab Stage 3 - perpetual inventory and COGS accounting
-- Apply after:
--   1. phaseP0_posting.sql
--   2. phaseP0_1_manual_vouchers.sql
--   3. phaseP0_2_payment_allocations.sql
--   4. phaseP2.sql and phaseP3_masters.sql (where applicable)
--
-- Accounting policy implemented here:
--   * perpetual inventory
--   * moving weighted-average cost
--   * purchases of tracked goods debit Inventory Asset
--   * sales of tracked goods debit COGS and credit Inventory Asset
--   * stock changes are atomic with their ledger vouchers
--   * direct browser writes to stock balances/movements are blocked
-- ============================================================

begin;

-- ------------------------------------------------------------
-- 1. Prerequisite columns and weighted-average valuation cache.
-- ------------------------------------------------------------
alter table inventory_items
  add column if not exists valuation_method text not null default 'weighted_average',
  add column if not exists average_cost numeric(18,6) not null default 0,
  add column if not exists inventory_value numeric(18,2) not null default 0,
  add column if not exists valuation_start_date date,
  add column if not exists valuation_updated_at timestamptz;

alter table inventory_items add column if not exists item_type text not null default 'goods';
alter table inventory_items add column if not exists track_inventory boolean not null default true;
alter table inventory_items add column if not exists hsn_code text;
alter table inventory_items add column if not exists opening_stock numeric(14,3) not null default 0;
alter table inventory_items add column if not exists opening_stock_value numeric(14,2) not null default 0;
alter table inventory_items add column if not exists updated_at timestamptz not null default now();

alter table invoice_lines add column if not exists item_id uuid references inventory_items(id);
alter table invoice_lines add column if not exists hsn_code text;
alter table invoice_lines add column if not exists inventory_unit_cost numeric(18,6);
alter table invoice_lines add column if not exists inventory_cost_amount numeric(18,2);
alter table invoices add column if not exists cogs_amount numeric(18,2) not null default 0;

alter table purchase_bill_lines add column if not exists item_id uuid references inventory_items(id);
alter table purchase_bill_lines add column if not exists hsn_code text;
alter table purchase_bill_lines add column if not exists inventory_unit_cost numeric(18,6);
alter table purchase_bill_lines add column if not exists inventory_cost_amount numeric(18,2);
alter table purchase_bills add column if not exists inventory_amount numeric(18,2) not null default 0;
alter table purchase_bills add column if not exists expense_amount numeric(18,2) not null default 0;

-- Existing stock becomes the opening valuation baseline for Stage 3.
update inventory_items
   set average_cost = case
         when average_cost <> 0 then average_cost
         when current_stock <> 0 then round(cost_price::numeric, 6)
         else round(cost_price::numeric, 6)
       end,
       inventory_value = case
         when inventory_value <> 0 then inventory_value
         else round(current_stock * cost_price, 2)
       end,
       valuation_method = 'weighted_average',
       valuation_start_date = coalesce(valuation_start_date, current_date),
       valuation_updated_at = coalesce(valuation_updated_at, now());

alter table inventory_movements
  add column if not exists source_type text not null default 'legacy',
  add column if not exists source_line_id uuid,
  add column if not exists voucher_id uuid references vouchers(id),
  add column if not exists quantity_delta numeric(14,3),
  add column if not exists unit_cost numeric(18,6),
  add column if not exists total_cost numeric(18,2),
  add column if not exists stock_before numeric(14,3),
  add column if not exists stock_after numeric(14,3),
  add column if not exists value_before numeric(18,2),
  add column if not exists value_after numeric(18,2),
  add column if not exists average_cost_before numeric(18,6),
  add column if not exists average_cost_after numeric(18,6),
  add column if not exists is_legacy boolean not null default false;

update inventory_movements
   set source_type = coalesce(nullif(source_type, ''), 'legacy'),
       quantity_delta = coalesce(
         quantity_delta,
         case when movement_type = 'out' then -abs(quantity) else abs(quantity) end
       ),
       unit_cost = coalesce(unit_cost, rate),
       total_cost = coalesce(total_cost, round(abs(quantity) * rate, 2)),
       is_legacy = true
 where stock_before is null
    or stock_after is null
    or value_before is null
    or value_after is null;

create index if not exists idx_inventory_movements_source
  on inventory_movements(source_type, reference_id);
create index if not exists idx_inventory_movements_voucher
  on inventory_movements(voucher_id);
create unique index if not exists uq_inventory_source_line
  on inventory_movements(source_type, source_line_id)
  where source_line_id is not null and source_type in ('sale', 'purchase');

-- ------------------------------------------------------------
-- 2. Stable inventory accounts.
-- ------------------------------------------------------------
alter table accounts add column if not exists system_code text;
create unique index if not exists uq_accounts_system_code
  on accounts(user_id, system_code) where system_code is not null;

-- Extend the existing resolver without changing its signature.
create or replace function resolve_system_account(p_code text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  acc_id uuid;
begin
  if uid is null then raise exception 'Not authenticated'; end if;

  select id into acc_id
    from accounts
   where user_id = uid and system_code = p_code
   limit 1;
  if acc_id is not null then return acc_id; end if;

  insert into accounts (
    user_id, name, account_type, group_name,
    is_party_account, opening_balance_type, system_code
  ) values (
    uid,
    case p_code
      when 'sales'             then 'Sales Account'
      when 'purchase'          then 'Purchase Account'
      when 'vat_payable'       then 'VAT Payable'
      when 'vat_receivable'    then 'VAT Receivable'
      when 'cash'              then 'Cash in Hand'
      when 'bank'              then 'Bank Account'
      when 'ar_control'        then 'Sundry Debtors (Control)'
      when 'ap_control'        then 'Sundry Creditors (Control)'
      when 'inventory_asset'   then 'Inventory Asset'
      when 'cogs'              then 'Cost of Goods Sold'
      when 'stock_adjustment'  then 'Stock Adjustment'
      when 'purchase_return'   then 'Purchase Returns Clearing'
      when 'inventory_opening' then 'Inventory Opening Equity'
      else p_code
    end,
    case p_code
      when 'sales'             then 'income'
      when 'purchase'          then 'expense'
      when 'vat_payable'       then 'liability'
      when 'vat_receivable'    then 'asset'
      when 'ap_control'        then 'liability'
      when 'inventory_asset'   then 'asset'
      when 'cogs'              then 'expense'
      when 'stock_adjustment'  then 'expense'
      when 'purchase_return'   then 'asset'
      when 'inventory_opening' then 'equity'
      else 'asset'
    end,
    case p_code
      when 'sales'             then 'Direct Income'
      when 'purchase'          then 'Direct Expense'
      when 'vat_payable'       then 'Duties & Taxes'
      when 'vat_receivable'    then 'Duties & Taxes'
      when 'cash'              then 'Cash-in-Hand'
      when 'bank'              then 'Bank Accounts'
      when 'ar_control'        then 'Sundry Debtors'
      when 'ap_control'        then 'Sundry Creditors'
      when 'inventory_asset'   then 'Current Assets'
      when 'cogs'              then 'Direct Expense'
      when 'stock_adjustment'  then 'Direct Expense'
      when 'purchase_return'   then 'Current Assets'
      when 'inventory_opening' then 'Capital'
      else 'General'
    end,
    false,
    case p_code
      when 'sales'             then 'credit'
      when 'vat_payable'       then 'credit'
      when 'ap_control'        then 'credit'
      when 'inventory_opening' then 'credit'
      else 'debit'
    end,
    p_code
  )
  returning id into acc_id;

  return acc_id;
end;
$$;

grant execute on function resolve_system_account(text) to authenticated;

-- Create Stage 3 accounts for every existing owner without requiring auth.uid().
with owners as (
  select distinct user_id from accounts
  union
  select distinct user_id from inventory_items
), required(code, name, account_type, group_name, opening_type) as (
  values
    ('inventory_asset',   'Inventory Asset',              'asset',   'Current Assets', 'debit'),
    ('cogs',              'Cost of Goods Sold',           'expense', 'Direct Expense', 'debit'),
    ('stock_adjustment',  'Stock Adjustment',             'expense', 'Direct Expense', 'debit'),
    ('purchase_return',   'Purchase Returns Clearing',    'asset',   'Current Assets', 'debit'),
    ('inventory_opening', 'Inventory Opening Equity',     'equity',  'Capital',        'credit')
)
insert into accounts (
  user_id, name, account_type, group_name,
  is_party_account, opening_balance_type, system_code
)
select o.user_id, r.name, r.account_type, r.group_name,
       false, r.opening_type, r.code
  from owners o cross join required r
 where not exists (
   select 1 from accounts a
    where a.user_id = o.user_id and a.system_code = r.code
 );

-- ------------------------------------------------------------
-- 3. Protect derived stock values from browser writes.
-- ------------------------------------------------------------
create or replace function protect_inventory_valuation()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if current_user in ('anon', 'authenticated') and (
       new.current_stock is distinct from old.current_stock
    or new.cost_price is distinct from old.cost_price
    or new.average_cost is distinct from old.average_cost
    or new.valuation_method is distinct from old.valuation_method
    or new.inventory_value is distinct from old.inventory_value
    or new.valuation_updated_at is distinct from old.valuation_updated_at
  ) then
    raise exception 'Stock quantity and valuation are database-managed.';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_protect_inventory_valuation on inventory_items;
create trigger trg_protect_inventory_valuation
before update on inventory_items
for each row execute function protect_inventory_valuation();

alter table inventory_items enable row level security;
alter table inventory_movements enable row level security;

drop policy if exists "own items" on inventory_items;
drop policy if exists "read own items" on inventory_items;
create policy "read own items" on inventory_items for select
  using (auth.uid() = user_id);

drop policy if exists "own movements" on inventory_movements;
drop policy if exists "read own movements" on inventory_movements;
create policy "read own movements" on inventory_movements for select
  using (auth.uid() = user_id);

grant select on inventory_items, inventory_movements to authenticated;
revoke insert, update, delete on inventory_items, inventory_movements from authenticated;

-- Disable old quantity-only entry points. They cannot keep the ledger aligned.
create or replace function update_stock(p_item_id uuid, p_delta numeric)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  raise exception 'Direct stock updates are disabled. Use record_inventory_adjustment().';
end;
$$;

create or replace function record_stock_movement(
  p_item_id uuid,
  p_type text,
  p_qty numeric,
  p_rate numeric,
  p_date date,
  p_reference text,
  p_reference_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  raise exception 'Legacy stock movement entry is disabled. Use record_inventory_adjustment().';
end;
$$;

revoke all on function update_stock(uuid, numeric) from public, authenticated;
revoke all on function record_stock_movement(uuid, text, numeric, numeric, date, text, uuid) from public, authenticated;

-- ------------------------------------------------------------
-- 4. Internal moving-weighted-average engine.
--    A positive delta adds stock; a negative delta removes stock.
-- ------------------------------------------------------------
create or replace function apply_inventory_movement(
  p_item_id uuid,
  p_quantity_delta numeric,
  p_inbound_unit_cost numeric,
  p_date date,
  p_source_type text,
  p_reference text,
  p_reference_id uuid,
  p_source_line_id uuid,
  p_notes text default null
)
returns table (
  movement_id uuid,
  applied_unit_cost numeric,
  applied_total_cost numeric,
  resulting_stock numeric,
  resulting_value numeric,
  resulting_average_cost numeric
)
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  i record;
  v_delta numeric(14,3) := round(coalesce(p_quantity_delta, 0), 3);
  v_qty numeric(14,3);
  v_old_stock numeric(14,3);
  v_old_value numeric(18,2);
  v_old_avg numeric(18,6);
  v_unit_cost numeric(18,6);
  v_total_cost numeric(18,2);
  v_new_stock numeric(14,3);
  v_new_value numeric(18,2);
  v_new_avg numeric(18,6);
  v_movement_type text;
  v_latest_movement_date date;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  if p_date is null then raise exception 'Movement date is required.'; end if;
  if abs(v_delta) < 0.0005 then raise exception 'Movement quantity cannot be zero.'; end if;

  select * into i
    from inventory_items
   where id = p_item_id and user_id = uid and is_active = true
   for update;
  if not found then raise exception 'Inventory item not found.'; end if;
  if not coalesce(i.track_inventory, true) or coalesce(i.item_type, 'goods') <> 'goods' then
    raise exception 'This item is not configured as tracked inventory.';
  end if;

  if i.valuation_start_date is not null and p_date < i.valuation_start_date then
    raise exception 'Movement date % is before the inventory valuation cutover date % for %.',
      p_date, i.valuation_start_date, i.name;
  end if;

  select max(movement_date)
    into v_latest_movement_date
    from inventory_movements
   where item_id = p_item_id
     and user_id = uid
     and is_legacy = false;

  if v_latest_movement_date is not null and p_date < v_latest_movement_date then
    raise exception 'Backdated inventory movement is not allowed. Latest valued movement date for % is %.',
      i.name, v_latest_movement_date;
  end if;

  v_old_stock := round(coalesce(i.current_stock, 0), 3);
  v_old_value := round(coalesce(i.inventory_value, v_old_stock * i.cost_price), 2);
  v_old_avg := case
    when v_old_stock > 0.0005 then round(v_old_value / v_old_stock, 6)
    else round(coalesce(nullif(i.average_cost, 0), i.cost_price, 0), 6)
  end;
  v_qty := abs(v_delta);

  if v_delta > 0 then
    v_unit_cost := round(coalesce(p_inbound_unit_cost, v_old_avg, 0), 6);
    if v_unit_cost < 0 then raise exception 'Unit cost cannot be negative.'; end if;
    v_total_cost := round(v_qty * v_unit_cost, 2);
    v_new_stock := round(v_old_stock + v_qty, 3);
    v_new_value := round(v_old_value + v_total_cost, 2);
    v_new_avg := case when v_new_stock > 0.0005
      then round(v_new_value / v_new_stock, 6)
      else v_old_avg end;
    v_movement_type := 'in';
  else
    if v_old_stock + 0.0005 < v_qty then
      raise exception 'Insufficient stock for %. Available: %, requested: %.', i.name, v_old_stock, v_qty;
    end if;
    v_unit_cost := v_old_avg;
    v_total_cost := round(v_qty * v_unit_cost, 2);
    v_new_stock := round(v_old_stock - v_qty, 3);
    v_new_value := case when v_new_stock <= 0.0005
      then 0
      else greatest(round(v_old_value - v_total_cost, 2), 0)
    end;
    v_new_avg := v_old_avg;
    v_movement_type := 'out';
  end if;

  insert into inventory_movements (
    user_id, item_id, movement_type, quantity, rate,
    movement_date, reference, reference_id, notes,
    source_type, source_line_id, quantity_delta,
    unit_cost, total_cost,
    stock_before, stock_after,
    value_before, value_after,
    average_cost_before, average_cost_after,
    is_legacy
  ) values (
    uid, p_item_id, v_movement_type, v_qty, round(v_unit_cost, 2),
    p_date, p_reference, p_reference_id, p_notes,
    p_source_type, p_source_line_id, v_delta,
    v_unit_cost, v_total_cost,
    v_old_stock, v_new_stock,
    v_old_value, v_new_value,
    v_old_avg, v_new_avg,
    false
  ) returning id into movement_id;

  update inventory_items
     set current_stock = v_new_stock,
         average_cost = v_new_avg,
         cost_price = round(v_new_avg, 2),
         inventory_value = v_new_value,
         valuation_method = 'weighted_average',
         valuation_updated_at = now(),
         updated_at = now()
   where id = p_item_id and user_id = uid;

  applied_unit_cost := v_unit_cost;
  applied_total_cost := v_total_cost;
  resulting_stock := v_new_stock;
  resulting_value := v_new_value;
  resulting_average_cost := v_new_avg;
  return next;
end;
$$;

revoke all on function apply_inventory_movement(uuid, numeric, numeric, date, text, text, uuid, uuid, text) from public, authenticated;

-- ------------------------------------------------------------
-- 5. Sales posting: revenue/VAT plus COGS/Inventory Asset.
-- ------------------------------------------------------------
create or replace function create_invoice_with_posting(p_header jsonb, p_lines jsonb)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  inv_id uuid;
  v_subtotal numeric(14,2);
  v_vat numeric(14,2);
  v_total numeric(14,2);
  v_cogs_total numeric(18,2) := 0;
  debtor_acct uuid;
  v_id uuid;
  v_inv_num integer;
  v_fy text;
  line_rec jsonb;
  v_item_id uuid;
  v_line_id uuid;
  v_qty numeric(14,3);
  v_rate numeric(14,2);
  v_amount numeric(14,2);
  v_vat_rate numeric(5,2);
  v_vat_amount numeric(14,2);
  v_line_total numeric(14,2);
  v_item record;
  v_hsn text;
  v_move record;
  v_voucher_lines jsonb;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  if p_lines is null or jsonb_array_length(p_lines) = 0 then
    raise exception 'At least one invoice line is required.';
  end if;

  v_fy := nullif(p_header->>'fiscal_year', '');
  if v_fy is null then raise exception 'Fiscal year is required.'; end if;
  select next_doc_number('invoice', v_fy) into v_inv_num;

  select coalesce(sum(round((l->>'amount')::numeric, 2)), 0),
         coalesce(sum(round((l->>'vat_amount')::numeric, 2)), 0)
    into v_subtotal, v_vat
    from jsonb_array_elements(p_lines) l;
  v_total := round(v_subtotal + v_vat, 2);
  if v_total <= 0 then raise exception 'Invoice total must be positive.'; end if;

  if nullif(p_header->>'party_id', '') is not null then
    select account_id into debtor_acct
      from parties
     where id = (p_header->>'party_id')::uuid and user_id = uid;
    if debtor_acct is null then raise exception 'Customer does not belong to this business.'; end if;
  else
    debtor_acct := resolve_system_account('ar_control');
  end if;

  insert into invoices (
    user_id, invoice_number, fiscal_year, invoice_date, due_date,
    party_id, party_name, party_address, party_pan,
    subtotal, vat_amount, total, status, notes,
    invoice_date_bs, due_date_bs,
    amount_paid, outstanding_amount, payment_status_updated_at
  ) values (
    uid, v_inv_num, v_fy,
    (p_header->>'invoice_date')::date,
    nullif(p_header->>'due_date', '')::date,
    nullif(p_header->>'party_id', '')::uuid,
    p_header->>'party_name', p_header->>'party_address', p_header->>'party_pan',
    v_subtotal, v_vat, v_total,
    coalesce(nullif(p_header->>'status', ''), 'open'), p_header->>'notes',
    coalesce(p_header->>'invoice_date_bs', ''), coalesce(p_header->>'due_date_bs', ''),
    0, v_total, now()
  ) returning id into inv_id;

  for line_rec in select * from jsonb_array_elements(p_lines)
  loop
    v_item_id := nullif(line_rec->>'item_id', '')::uuid;
    v_qty := round(coalesce((line_rec->>'quantity')::numeric, 1), 3);
    v_rate := round(coalesce((line_rec->>'rate')::numeric, 0), 2);
    v_amount := round(coalesce((line_rec->>'amount')::numeric, v_qty * v_rate), 2);
    v_vat_rate := round(coalesce((line_rec->>'vat_rate')::numeric, 0), 2);
    v_vat_amount := round(coalesce((line_rec->>'vat_amount')::numeric, 0), 2);
    v_line_total := round(coalesce((line_rec->>'line_total')::numeric, v_amount + v_vat_amount), 2);

    if v_qty <= 0 then raise exception 'Invoice quantity must be positive.'; end if;

    v_hsn := nullif(line_rec->>'hsn_code', '');
    if v_item_id is not null then
      select * into v_item
        from inventory_items
       where id = v_item_id and user_id = uid and is_active = true
       for update;
      if not found then raise exception 'Invoice item does not belong to this business.'; end if;
      v_hsn := coalesce(v_hsn, v_item.hsn_code);
    end if;

    insert into invoice_lines (
      invoice_id, description, quantity, unit, rate, amount,
      vat_rate, vat_amount, line_total, item_id, hsn_code
    ) values (
      inv_id, line_rec->>'description', v_qty,
      coalesce(line_rec->>'unit', 'pcs'), v_rate, v_amount,
      v_vat_rate, v_vat_amount, v_line_total, v_item_id,
      v_hsn
    ) returning id into v_line_id;

    if v_item_id is not null
       and coalesce(v_item.track_inventory, true)
       and coalesce(v_item.item_type, 'goods') = 'goods' then
      select * into v_move
        from apply_inventory_movement(
          v_item_id, -v_qty, null,
          (p_header->>'invoice_date')::date,
          'sale', 'Invoice #' || v_inv_num,
          inv_id, v_line_id,
          'Automatic stock issue and COGS for invoice line.'
        );
      update invoice_lines
         set inventory_unit_cost = v_move.applied_unit_cost,
             inventory_cost_amount = v_move.applied_total_cost
       where id = v_line_id;
      v_cogs_total := v_cogs_total + v_move.applied_total_cost;
    end if;
  end loop;

  v_voucher_lines := jsonb_build_array(
    jsonb_build_object(
      'account_id', debtor_acct,
      'debit', v_total, 'credit', 0,
      'description', p_header->>'party_name'
    ),
    jsonb_build_object(
      'account_id', resolve_system_account('sales'),
      'debit', 0, 'credit', v_subtotal,
      'description', 'Sales'
    )
  );

  if v_vat > 0.005 then
    v_voucher_lines := v_voucher_lines || jsonb_build_array(
      jsonb_build_object(
        'account_id', resolve_system_account('vat_payable'),
        'debit', 0, 'credit', v_vat,
        'description', 'Output VAT'
      )
    );
  end if;

  if v_cogs_total > 0.005 then
    v_voucher_lines := v_voucher_lines || jsonb_build_array(
      jsonb_build_object(
        'account_id', resolve_system_account('cogs'),
        'debit', v_cogs_total, 'credit', 0,
        'description', 'Cost of goods sold'
      ),
      jsonb_build_object(
        'account_id', resolve_system_account('inventory_asset'),
        'debit', 0, 'credit', v_cogs_total,
        'description', 'Inventory issued at weighted-average cost'
      )
    );
  end if;

  v_id := post_voucher(
    'sales', v_fy, (p_header->>'invoice_date')::date,
    'Sales Invoice #' || v_inv_num,
    v_voucher_lines
  );

  update invoices
     set voucher_id = v_id, cogs_amount = round(v_cogs_total, 2)
   where id = inv_id and user_id = uid;
  update inventory_movements
     set voucher_id = v_id
   where user_id = uid and reference_id = inv_id
     and source_type = 'sale' and voucher_id is null;

  perform write_audit_log(
    'create', 'invoices', inv_id::text, null,
    jsonb_build_object(
      'invoice_number', v_inv_num,
      'total', v_total,
      'cogs', v_cogs_total,
      'inventory_method', 'moving_weighted_average'
    )
  );
  return inv_id;
end;
$$;

grant execute on function create_invoice_with_posting(jsonb, jsonb) to authenticated;

-- ------------------------------------------------------------
-- 6. Purchase posting: tracked goods debit Inventory Asset.
-- ------------------------------------------------------------
create or replace function create_bill_with_posting(p_header jsonb, p_lines jsonb)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  bill_id uuid;
  v_subtotal numeric(14,2);
  v_vat numeric(14,2);
  v_total numeric(14,2);
  v_inventory_total numeric(18,2) := 0;
  v_expense_total numeric(18,2) := 0;
  creditor_acct uuid;
  v_id uuid;
  v_bill_num integer;
  v_fy text;
  line_rec jsonb;
  v_item_id uuid;
  v_line_id uuid;
  v_qty numeric(14,3);
  v_rate numeric(14,2);
  v_amount numeric(14,2);
  v_vat_rate numeric(5,2);
  v_vat_amount numeric(14,2);
  v_line_total numeric(14,2);
  v_item record;
  v_hsn text;
  v_move record;
  v_voucher_lines jsonb;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  if p_lines is null or jsonb_array_length(p_lines) = 0 then
    raise exception 'At least one purchase line is required.';
  end if;

  v_fy := nullif(p_header->>'fiscal_year', '');
  if v_fy is null then raise exception 'Fiscal year is required.'; end if;
  select next_doc_number('bill', v_fy) into v_bill_num;

  select coalesce(sum(round((l->>'amount')::numeric, 2)), 0),
         coalesce(sum(round((l->>'vat_amount')::numeric, 2)), 0)
    into v_subtotal, v_vat
    from jsonb_array_elements(p_lines) l;
  v_total := round(v_subtotal + v_vat, 2);
  if v_total <= 0 then raise exception 'Purchase total must be positive.'; end if;

  if nullif(p_header->>'vendor_id', '') is not null then
    select account_id into creditor_acct
      from parties
     where id = (p_header->>'vendor_id')::uuid and user_id = uid;
    if creditor_acct is null then raise exception 'Vendor does not belong to this business.'; end if;
  else
    creditor_acct := resolve_system_account('ap_control');
  end if;

  insert into purchase_bills (
    user_id, bill_number, fiscal_year, bill_date, due_date,
    vendor_id, vendor_name, vendor_address, vendor_pan, vendor_bill_ref,
    subtotal, vat_amount, total, status, notes,
    amount_paid, outstanding_amount, payment_status_updated_at
  ) values (
    uid, v_bill_num, v_fy,
    (p_header->>'bill_date')::date,
    nullif(p_header->>'due_date', '')::date,
    nullif(p_header->>'vendor_id', '')::uuid,
    p_header->>'vendor_name', p_header->>'vendor_address',
    p_header->>'vendor_pan', p_header->>'vendor_bill_ref',
    v_subtotal, v_vat, v_total,
    coalesce(nullif(p_header->>'status', ''), 'open'), p_header->>'notes',
    0, v_total, now()
  ) returning id into bill_id;

  for line_rec in select * from jsonb_array_elements(p_lines)
  loop
    v_item_id := nullif(line_rec->>'item_id', '')::uuid;
    v_qty := round(coalesce((line_rec->>'quantity')::numeric, 1), 3);
    v_rate := round(coalesce((line_rec->>'rate')::numeric, 0), 2);
    v_amount := round(coalesce((line_rec->>'amount')::numeric, v_qty * v_rate), 2);
    v_vat_rate := round(coalesce((line_rec->>'vat_rate')::numeric, 0), 2);
    v_vat_amount := round(coalesce((line_rec->>'vat_amount')::numeric, 0), 2);
    v_line_total := round(coalesce((line_rec->>'line_total')::numeric, v_amount + v_vat_amount), 2);

    if v_qty <= 0 then raise exception 'Purchase quantity must be positive.'; end if;

    v_hsn := nullif(line_rec->>'hsn_code', '');
    if v_item_id is not null then
      select * into v_item
        from inventory_items
       where id = v_item_id and user_id = uid and is_active = true
       for update;
      if not found then raise exception 'Purchase item does not belong to this business.'; end if;
      v_hsn := coalesce(v_hsn, v_item.hsn_code);
    end if;

    insert into purchase_bill_lines (
      bill_id, description, quantity, unit, rate, amount,
      vat_rate, vat_amount, line_total, item_id, hsn_code
    ) values (
      bill_id, line_rec->>'description', v_qty,
      coalesce(line_rec->>'unit', 'pcs'), v_rate, v_amount,
      v_vat_rate, v_vat_amount, v_line_total, v_item_id,
      v_hsn
    ) returning id into v_line_id;

    if v_item_id is not null
       and coalesce(v_item.track_inventory, true)
       and coalesce(v_item.item_type, 'goods') = 'goods' then
      select * into v_move
        from apply_inventory_movement(
          v_item_id, v_qty, round(v_amount / v_qty, 6),
          (p_header->>'bill_date')::date,
          'purchase', 'Bill #' || v_bill_num,
          bill_id, v_line_id,
          'Automatic stock receipt at purchase cost.'
        );
      update purchase_bill_lines
         set inventory_unit_cost = v_move.applied_unit_cost,
             inventory_cost_amount = v_move.applied_total_cost
       where id = v_line_id;
      v_inventory_total := v_inventory_total + v_move.applied_total_cost;
    else
      v_expense_total := v_expense_total + v_amount;
    end if;
  end loop;

  -- Derive the non-inventory portion from the document subtotal so line discounts
  -- and two-decimal document totals remain consistent with the ledger.
  v_expense_total := round(v_subtotal - v_inventory_total, 2);
  if v_expense_total < -0.005 then
    raise exception 'Tracked inventory value % exceeds purchase subtotal %.', v_inventory_total, v_subtotal;
  end if;
  v_expense_total := greatest(v_expense_total, 0);

  v_voucher_lines := jsonb_build_array(
    jsonb_build_object(
      'account_id', creditor_acct,
      'debit', 0, 'credit', v_total,
      'description', p_header->>'vendor_name'
    )
  );

  if v_inventory_total > 0.005 then
    v_voucher_lines := v_voucher_lines || jsonb_build_array(
      jsonb_build_object(
        'account_id', resolve_system_account('inventory_asset'),
        'debit', v_inventory_total, 'credit', 0,
        'description', 'Tracked inventory purchased'
      )
    );
  end if;

  if v_expense_total > 0.005 then
    v_voucher_lines := v_voucher_lines || jsonb_build_array(
      jsonb_build_object(
        'account_id', resolve_system_account('purchase'),
        'debit', v_expense_total, 'credit', 0,
        'description', 'Non-inventory purchases and services'
      )
    );
  end if;

  if v_vat > 0.005 then
    v_voucher_lines := v_voucher_lines || jsonb_build_array(
      jsonb_build_object(
        'account_id', resolve_system_account('vat_receivable'),
        'debit', v_vat, 'credit', 0,
        'description', 'Input VAT'
      )
    );
  end if;

  v_id := post_voucher(
    'purchase', v_fy, (p_header->>'bill_date')::date,
    'Purchase Bill #' || v_bill_num,
    v_voucher_lines
  );

  update purchase_bills
     set voucher_id = v_id,
         inventory_amount = round(v_inventory_total, 2),
         expense_amount = round(greatest(v_expense_total, 0), 2)
   where id = bill_id and user_id = uid;
  update inventory_movements
     set voucher_id = v_id
   where user_id = uid and reference_id = bill_id
     and source_type = 'purchase' and voucher_id is null;

  perform write_audit_log(
    'create', 'purchase_bills', bill_id::text, null,
    jsonb_build_object(
      'bill_number', v_bill_num,
      'total', v_total,
      'inventory_debit', v_inventory_total,
      'expense_debit', greatest(v_expense_total, 0),
      'inventory_method', 'moving_weighted_average'
    )
  );
  return bill_id;
end;
$$;

grant execute on function create_bill_with_posting(jsonb, jsonb) to authenticated;

-- ------------------------------------------------------------
-- 7. Controlled stock adjustments, returns, damage, and opening.
-- ------------------------------------------------------------
create or replace function record_inventory_adjustment(
  p_item_id uuid,
  p_reason_type text,
  p_quantity numeric,
  p_unit_cost numeric,
  p_date date,
  p_fiscal_year text,
  p_reference text default null,
  p_notes text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  v_reason text := lower(coalesce(p_reason_type, ''));
  v_qty numeric(14,3) := round(abs(coalesce(p_quantity, 0)), 3);
  v_delta numeric(14,3);
  v_inbound_cost numeric(18,6);
  v_offset_code text;
  v_item record;
  v_move record;
  v_voucher_id uuid;
  v_lines jsonb;
  v_reference text;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  if p_date is null then raise exception 'Movement date is required.'; end if;
  if nullif(trim(coalesce(p_fiscal_year, '')), '') is null then raise exception 'Fiscal year is required.'; end if;
  if v_qty <= 0 then raise exception 'Quantity must be positive.'; end if;

  select * into v_item
    from inventory_items
   where id = p_item_id and user_id = uid and is_active = true
   for update;
  if not found then raise exception 'Inventory item not found.'; end if;

  case v_reason
    when 'adjustment_in' then
      v_delta := v_qty; v_offset_code := 'stock_adjustment';
    when 'adjustment_out' then
      v_delta := -v_qty; v_offset_code := 'stock_adjustment';
    when 'damage' then
      v_delta := -v_qty; v_offset_code := 'stock_adjustment';
    when 'opening' then
      v_delta := v_qty; v_offset_code := 'inventory_opening';
    else
      raise exception 'Unknown stock movement reason: %', p_reason_type;
  end case;

  v_inbound_cost := case
    when v_delta > 0 then round(coalesce(nullif(p_unit_cost, 0), nullif(v_item.average_cost, 0), v_item.cost_price, 0), 6)
    else null
  end;
  v_reference := coalesce(nullif(trim(p_reference), ''), initcap(replace(v_reason, '_', ' ')) || ' - ' || v_item.name);

  select * into v_move
    from apply_inventory_movement(
      p_item_id, v_delta, v_inbound_cost, p_date,
      v_reason, v_reference, null, null,
      nullif(trim(p_notes), '')
    );

  if v_move.applied_total_cost > 0.005 then
    if v_delta > 0 then
      v_lines := jsonb_build_array(
        jsonb_build_object(
          'account_id', resolve_system_account('inventory_asset'),
          'debit', v_move.applied_total_cost, 'credit', 0,
          'description', v_reference
        ),
        jsonb_build_object(
          'account_id', resolve_system_account(v_offset_code),
          'debit', 0, 'credit', v_move.applied_total_cost,
          'description', initcap(replace(v_reason, '_', ' '))
        )
      );
    else
      v_lines := jsonb_build_array(
        jsonb_build_object(
          'account_id', resolve_system_account(v_offset_code),
          'debit', v_move.applied_total_cost, 'credit', 0,
          'description', initcap(replace(v_reason, '_', ' '))
        ),
        jsonb_build_object(
          'account_id', resolve_system_account('inventory_asset'),
          'debit', 0, 'credit', v_move.applied_total_cost,
          'description', v_reference
        )
      );
    end if;

    v_voucher_id := post_voucher(
      'journal', p_fiscal_year, p_date,
      'Inventory ' || replace(v_reason, '_', ' ') || ': ' || v_item.name,
      v_lines
    );

    update inventory_movements
       set voucher_id = v_voucher_id
     where id = v_move.movement_id and user_id = uid;
  end if;

  perform write_audit_log(
    'create', 'inventory_movements', v_move.movement_id::text, null,
    jsonb_build_object(
      'item_id', p_item_id,
      'reason_type', v_reason,
      'quantity_delta', v_delta,
      'unit_cost', v_move.applied_unit_cost,
      'total_cost', v_move.applied_total_cost,
      'voucher_id', v_voucher_id
    )
  );

  return v_move.movement_id;
end;
$$;

revoke all on function record_inventory_adjustment(uuid, text, numeric, numeric, date, text, text, text) from public;
grant execute on function record_inventory_adjustment(uuid, text, numeric, numeric, date, text, text, text) to authenticated;

-- ------------------------------------------------------------
-- 8. Reconciliation: stock valuation must equal Inventory Asset.
-- ------------------------------------------------------------
create or replace function get_inventory_reconciliation()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  v_inventory_account uuid;
  v_stock_value numeric(18,2);
  v_ledger_value numeric(18,2);
  v_tracked_items integer;
  v_negative_items integer;
  v_unvalued_items integer;
  v_legacy_movements integer;
begin
  if uid is null then raise exception 'Not authenticated'; end if;

  v_inventory_account := resolve_system_account('inventory_asset');

  select coalesce(round(sum(inventory_value), 2), 0),
         count(*)::integer,
         count(*) filter (where current_stock < -0.0005)::integer,
         count(*) filter (where current_stock > 0.0005 and inventory_value <= 0.005)::integer
    into v_stock_value, v_tracked_items, v_negative_items, v_unvalued_items
    from inventory_items
   where user_id = uid and is_active = true
     and track_inventory = true and item_type = 'goods';

  select round(
    coalesce(case when a.opening_balance_type = 'debit' then a.opening_balance else -a.opening_balance end, 0)
    + coalesce(sum(case when v.is_void = false then vl.debit - vl.credit else 0 end), 0),
    2
  )
    into v_ledger_value
    from accounts a
    left join voucher_lines vl on vl.account_id = a.id
    left join vouchers v on v.id = vl.voucher_id
   where a.id = v_inventory_account and a.user_id = uid
   group by a.id, a.opening_balance, a.opening_balance_type;

  select count(*)::integer into v_legacy_movements
    from inventory_movements
   where user_id = uid and is_legacy = true;

  return jsonb_build_object(
    'method', 'moving_weighted_average',
    'stock_valuation', coalesce(v_stock_value, 0),
    'inventory_ledger_balance', coalesce(v_ledger_value, 0),
    'difference', round(coalesce(v_stock_value, 0) - coalesce(v_ledger_value, 0), 2),
    'tracked_items', coalesce(v_tracked_items, 0),
    'negative_stock_items', coalesce(v_negative_items, 0),
    'unvalued_stock_items', coalesce(v_unvalued_items, 0),
    'legacy_movements', coalesce(v_legacy_movements, 0),
    'as_of', current_date
  );
end;
$$;

revoke all on function get_inventory_reconciliation() from public;
grant execute on function get_inventory_reconciliation() to authenticated;

create or replace function reconcile_inventory_ledger(
  p_date date,
  p_fiscal_year text,
  p_reason text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  v_stats jsonb;
  v_difference numeric(18,2);
  v_voucher_id uuid;
  v_lines jsonb;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  if p_date is null then raise exception 'Reconciliation date is required.'; end if;
  if nullif(trim(coalesce(p_fiscal_year, '')), '') is null then raise exception 'Fiscal year is required.'; end if;
  if p_reason is null or length(trim(p_reason)) < 5 then
    raise exception 'A reconciliation reason of at least 5 characters is required.';
  end if;

  perform pg_advisory_xact_lock(hashtext(uid::text || ':inventory-reconcile'));
  v_stats := get_inventory_reconciliation();

  if coalesce((v_stats->>'negative_stock_items')::integer, 0) > 0 then
    raise exception 'Resolve negative stock before reconciling Inventory Asset.';
  end if;
  if coalesce((v_stats->>'unvalued_stock_items')::integer, 0) > 0 then
    raise exception 'Some positive stock has zero value. Set or adjust its cost before reconciliation.';
  end if;

  v_difference := round((v_stats->>'difference')::numeric, 2);
  if abs(v_difference) <= 0.005 then return null; end if;

  if v_difference > 0 then
    v_lines := jsonb_build_array(
      jsonb_build_object(
        'account_id', resolve_system_account('inventory_asset'),
        'debit', v_difference, 'credit', 0,
        'description', 'Inventory valuation reconciliation'
      ),
      jsonb_build_object(
        'account_id', resolve_system_account('inventory_opening'),
        'debit', 0, 'credit', v_difference,
        'description', trim(p_reason)
      )
    );
  else
    v_lines := jsonb_build_array(
      jsonb_build_object(
        'account_id', resolve_system_account('inventory_opening'),
        'debit', abs(v_difference), 'credit', 0,
        'description', trim(p_reason)
      ),
      jsonb_build_object(
        'account_id', resolve_system_account('inventory_asset'),
        'debit', 0, 'credit', abs(v_difference),
        'description', 'Inventory valuation reconciliation'
      )
    );
  end if;

  v_voucher_id := post_voucher(
    'journal', p_fiscal_year, p_date,
    'Inventory ledger reconciliation: ' || trim(p_reason),
    v_lines
  );

  perform write_audit_log(
    'create', 'inventory_reconciliation', v_voucher_id::text, null,
    jsonb_build_object(
      'difference_before', v_difference,
      'stock_valuation', v_stats->>'stock_valuation',
      'inventory_ledger_balance', v_stats->>'inventory_ledger_balance',
      'reason', trim(p_reason)
    )
  );

  return v_voucher_id;
end;
$$;

revoke all on function reconcile_inventory_ledger(date, text, text) from public;
grant execute on function reconcile_inventory_ledger(date, text, text) to authenticated;

-- ------------------------------------------------------------
-- 9. Item creation with atomic opening-stock posting.
-- ------------------------------------------------------------
drop function if exists public.create_item(
  text, text, text, text, text, uuid, text, text,
  numeric, numeric, uuid, numeric, numeric, uuid,
  uuid, boolean, numeric, numeric, numeric, text
);

create or replace function create_item(
  p_name text,
  p_name_np text default null,
  p_sku text default null,
  p_hsn_code text default null,
  p_brand text default null,
  p_category_id uuid default null,
  p_item_type text default 'goods',
  p_unit text default 'pcs',
  p_sales_price numeric default 0,
  p_sales_tax_rate numeric default 13,
  p_sales_account_id uuid default null,
  p_purchase_price numeric default 0,
  p_purchase_tax_rate numeric default 13,
  p_purchase_account_id uuid default null,
  p_preferred_vendor_id uuid default null,
  p_track_inventory boolean default true,
  p_opening_stock numeric default 0,
  p_opening_stock_value numeric default 0,
  p_reorder_level numeric default 0,
  p_description text default null,
  p_opening_date date default current_date,
  p_fiscal_year text default null
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
  v_track boolean := coalesce(p_track_inventory, true) and coalesce(p_item_type, 'goods') = 'goods';
  v_open_qty numeric(14,3) := round(greatest(coalesce(p_opening_stock, 0), 0), 3);
  v_open_value numeric(18,2);
  v_open_cost numeric(18,6);
  v_move record;
  v_voucher_id uuid;
  v_fy text := nullif(trim(coalesce(p_fiscal_year, '')), '');
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  if nullif(trim(coalesce(p_name, '')), '') is null then raise exception 'Item name is required.'; end if;
  if not v_track and v_open_qty > 0 then raise exception 'Opening stock is allowed only for tracked goods.'; end if;

  if p_category_id is not null and not exists (
    select 1 from item_categories where id = p_category_id and user_id = uid
  ) then raise exception 'Category does not belong to this business.'; end if;
  if p_preferred_vendor_id is not null and not exists (
    select 1 from parties where id = p_preferred_vendor_id and user_id = uid
  ) then raise exception 'Preferred vendor does not belong to this business.'; end if;

  if v_sales_acct is null then v_sales_acct := resolve_system_account('sales'); end if;
  if v_purch_acct is null then v_purch_acct := resolve_system_account('purchase'); end if;

  v_open_value := case
    when v_open_qty <= 0 then 0
    when coalesce(p_opening_stock_value, 0) > 0 then round(p_opening_stock_value, 2)
    else round(v_open_qty * greatest(coalesce(p_purchase_price, 0), 0), 2)
  end;
  v_open_cost := case when v_open_qty > 0 then round(v_open_value / v_open_qty, 6)
                      else round(greatest(coalesce(p_purchase_price, 0), 0), 6) end;

  insert into inventory_items (
    user_id, name, name_np, sku, hsn_code, brand, category_id,
    category, item_type, unit,
    selling_price, sales_tax_rate, sales_account_id,
    cost_price, average_cost, inventory_value, valuation_method,
    purchase_tax_rate, purchase_account_id,
    preferred_vendor_id, track_inventory,
    opening_stock, opening_stock_value, current_stock,
    reorder_level, description, is_active,
    valuation_start_date, valuation_updated_at
  ) values (
    uid, trim(p_name), p_name_np, p_sku, p_hsn_code, p_brand, p_category_id,
    coalesce((select name from item_categories where id = p_category_id and user_id = uid), 'General'),
    coalesce(p_item_type, 'goods'), coalesce(p_unit, 'pcs'),
    greatest(coalesce(p_sales_price, 0), 0), coalesce(p_sales_tax_rate, 13), v_sales_acct,
    round(v_open_cost, 2), v_open_cost, 0, 'weighted_average',
    coalesce(p_purchase_tax_rate, 13), v_purch_acct,
    p_preferred_vendor_id, v_track,
    v_open_qty, v_open_value, 0,
    greatest(coalesce(p_reorder_level, 0), 0), p_description, true,
    coalesce(p_opening_date, current_date), now()
  ) returning id into v_id;

  if v_track and v_open_qty > 0 then
    if v_fy is null then raise exception 'Fiscal year is required when opening stock is entered.'; end if;

    select * into v_move
      from apply_inventory_movement(
        v_id, v_open_qty, v_open_cost,
        coalesce(p_opening_date, current_date),
        'opening', 'Opening stock - ' || trim(p_name),
        v_id, null, 'Opening stock entered with item creation.'
      );

    if v_move.applied_total_cost > 0.005 then
      v_voucher_id := post_voucher(
        'journal', v_fy, coalesce(p_opening_date, current_date),
        'Opening stock - ' || trim(p_name),
        jsonb_build_array(
          jsonb_build_object(
            'account_id', resolve_system_account('inventory_asset'),
            'debit', v_move.applied_total_cost, 'credit', 0,
            'description', trim(p_name)
          ),
          jsonb_build_object(
            'account_id', resolve_system_account('inventory_opening'),
            'debit', 0, 'credit', v_move.applied_total_cost,
            'description', 'Opening inventory equity'
          )
        )
      );
      update inventory_movements set voucher_id = v_voucher_id where id = v_move.movement_id;
    end if;
  end if;

  perform write_audit_log(
    'create', 'inventory_items', v_id::text, null,
    jsonb_build_object(
      'name', trim(p_name),
      'category_id', p_category_id,
      'sku', p_sku,
      'opening_stock', v_open_qty,
      'opening_value', v_open_value,
      'opening_voucher_id', v_voucher_id
    )
  );
  return v_id;
end;
$$;

grant execute on function create_item(
  text, text, text, text, text, uuid, text, text,
  numeric, numeric, uuid, numeric, numeric, uuid,
  uuid, boolean, numeric, numeric, numeric, text, date, text
) to authenticated;

-- Protect weighted average from master-data edits while stock is on hand.
create or replace function update_item(
  p_id uuid,
  p_name text default null,
  p_name_np text default null,
  p_sku text default null,
  p_hsn_code text default null,
  p_brand text default null,
  p_category_id uuid default null,
  p_item_type text default null,
  p_unit text default null,
  p_sales_price numeric default null,
  p_sales_tax_rate numeric default null,
  p_sales_account_id uuid default null,
  p_purchase_price numeric default null,
  p_purchase_tax_rate numeric default null,
  p_purchase_account_id uuid default null,
  p_preferred_vendor_id uuid default null,
  p_track_inventory boolean default null,
  p_reorder_level numeric default null,
  p_description text default null,
  p_is_active boolean default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  i record;
  v_new_track boolean;
begin
  if uid is null then raise exception 'Not authenticated'; end if;

  select * into i from inventory_items where id = p_id and user_id = uid for update;
  if not found then raise exception 'Item not found.'; end if;

  v_new_track := coalesce(p_track_inventory, i.track_inventory);
  if abs(i.current_stock) > 0.0005 and not v_new_track then
    raise exception 'Tracked inventory cannot be disabled while stock is on hand.';
  end if;
  if abs(i.current_stock) > 0.0005
     and p_purchase_price is not null
     and abs(round(p_purchase_price, 2) - round(i.cost_price, 2)) > 0.005 then
    raise exception 'Average cost is database-managed while stock is on hand. Use an inventory adjustment instead.';
  end if;

  update inventory_items set
    name = coalesce(p_name, name),
    name_np = coalesce(p_name_np, name_np),
    sku = coalesce(p_sku, sku),
    hsn_code = coalesce(p_hsn_code, hsn_code),
    brand = coalesce(p_brand, brand),
    category_id = coalesce(p_category_id, category_id),
    category = coalesce((select name from item_categories where id = coalesce(p_category_id, category_id) and user_id = uid), category),
    item_type = coalesce(p_item_type, item_type),
    unit = coalesce(p_unit, unit),
    selling_price = coalesce(p_sales_price, selling_price),
    sales_tax_rate = coalesce(p_sales_tax_rate, sales_tax_rate),
    sales_account_id = coalesce(p_sales_account_id, sales_account_id),
    cost_price = case when abs(current_stock) <= 0.0005 then coalesce(p_purchase_price, cost_price) else cost_price end,
    average_cost = case when abs(current_stock) <= 0.0005 then coalesce(p_purchase_price, average_cost) else average_cost end,
    purchase_tax_rate = coalesce(p_purchase_tax_rate, purchase_tax_rate),
    purchase_account_id = coalesce(p_purchase_account_id, purchase_account_id),
    preferred_vendor_id = coalesce(p_preferred_vendor_id, preferred_vendor_id),
    track_inventory = v_new_track,
    reorder_level = coalesce(p_reorder_level, reorder_level),
    description = coalesce(p_description, description),
    is_active = coalesce(p_is_active, is_active),
    updated_at = now()
  where id = p_id and user_id = uid;

  perform write_audit_log('update', 'inventory_items', p_id::text, null,
    jsonb_build_object('name', p_name));
end;
$$;

grant execute on function update_item(
  uuid, text, text, text, text, text, uuid, text, text,
  numeric, numeric, uuid, numeric, numeric, uuid,
  uuid, boolean, numeric, text, boolean
) to authenticated;

-- ------------------------------------------------------------
-- 10. Inventory views for UI and verification.
-- ------------------------------------------------------------
create or replace view inventory_valuation as
select
  i.id as item_id,
  i.user_id,
  i.name,
  i.sku,
  i.unit,
  i.current_stock,
  i.average_cost,
  i.inventory_value,
  i.reorder_level,
  i.is_active,
  i.valuation_updated_at,
  i.valuation_start_date
from inventory_items i
where i.track_inventory = true and i.item_type = 'goods';

grant select on inventory_valuation to authenticated;

-- Recreate item_summary with the existing column order, appending valuation fields.
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
  i.selling_price as sales_price,
  i.sales_tax_rate,
  i.sales_account_id,
  i.cost_price as purchase_price,
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
  i.updated_at,
  i.average_cost,
  i.inventory_value,
  i.valuation_method,
  i.valuation_updated_at,
  i.valuation_start_date
from inventory_items i
left join item_categories c on c.id = i.category_id
left join parties pv on pv.id = i.preferred_vendor_id
left join accounts pv_a on pv_a.id = pv.account_id;

grant select on item_summary to authenticated;

-- Dashboard stock value now uses the maintained inventory value, not quantity x rounded display cost.
create or replace function get_dashboard_stats()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  result jsonb;
  v_cash numeric; v_receivables numeric; v_payables numeric;
  v_sales_this numeric; v_sales_last numeric;
  v_vat_payable numeric; v_stock_value numeric;
  v_low_stock integer; v_invoice_count integer; v_overdue_count integer;
  v_overdue_amount numeric; v_invoice_outstanding numeric; v_bill_outstanding numeric;
  this_month_start date; last_month_start date; last_month_end date;
begin
  if uid is null then raise exception 'Not authenticated'; end if;

  this_month_start := date_trunc('month', current_date)::date;
  last_month_start := (date_trunc('month', current_date) - interval '1 month')::date;
  last_month_end := (this_month_start - 1)::date;

  select coalesce(sum(
    case when a.opening_balance_type='debit' then a.opening_balance else -a.opening_balance end
    + coalesce((select sum(vl.debit-vl.credit) from voucher_lines vl
                join vouchers v on v.id=vl.voucher_id and v.is_void=false
                where vl.account_id=a.id),0)
  ),0)
  into v_cash
  from accounts a
  where a.user_id=uid and a.is_active=true
    and a.group_name in ('Cash-in-Hand','Bank Accounts');

  select coalesce(sum(
    case when a.opening_balance_type='debit' then a.opening_balance else -a.opening_balance end
    + coalesce((select sum(vl.debit-vl.credit) from voucher_lines vl
                join vouchers v on v.id=vl.voucher_id and v.is_void=false
                where vl.account_id=a.id),0)
  ),0)
  into v_receivables
  from accounts a
  where a.user_id=uid and a.is_active=true
    and a.group_name in ('Sundry Debtors') and a.account_type='asset';

  select coalesce(sum(-(
    case when a.opening_balance_type='debit' then a.opening_balance else -a.opening_balance end
    + coalesce((select sum(vl.debit-vl.credit) from voucher_lines vl
                join vouchers v on v.id=vl.voucher_id and v.is_void=false
                where vl.account_id=a.id),0)
  )),0)
  into v_payables
  from accounts a
  where a.user_id=uid and a.is_active=true
    and a.group_name in ('Sundry Creditors') and a.account_type='liability';

  select
    coalesce(sum(case when invoice_date >= this_month_start then subtotal else 0 end),0),
    coalesce(sum(case when invoice_date between last_month_start and last_month_end then subtotal else 0 end),0)
  into v_sales_this, v_sales_last
  from invoices where user_id=uid and status not in ('cancelled','credited');

  select coalesce(sum(case when i.invoice_date >= this_month_start then i.vat_amount else 0 end),0)
       - coalesce((select sum(b.vat_amount) from purchase_bills b
                   where b.user_id=uid and b.bill_date >= this_month_start
                     and b.status not in ('cancelled','credited')),0)
  into v_vat_payable
  from invoices i
  where i.user_id=uid and i.status not in ('cancelled','credited');

  select coalesce(sum(inventory_value),0),
         count(*) filter (where current_stock <= reorder_level)::integer
  into v_stock_value, v_low_stock
  from inventory_items
  where user_id=uid and is_active=true and item_type='goods' and track_inventory;

  select count(*)::integer,
         count(*) filter (
           where due_date < current_date
             and outstanding_amount > 0.005
             and status in ('open','partial','overdue')
         )::integer,
         coalesce(sum(outstanding_amount) filter (
           where due_date < current_date
             and outstanding_amount > 0.005
             and status in ('open','partial','overdue')
         ),0),
         coalesce(sum(outstanding_amount),0)
    into v_invoice_count, v_overdue_count, v_overdue_amount, v_invoice_outstanding
    from invoices
   where user_id=uid and status not in ('cancelled','credited');

  select coalesce(sum(outstanding_amount),0)
    into v_bill_outstanding
    from purchase_bills
   where user_id=uid and status not in ('cancelled','credited');

  result := jsonb_build_object(
    'cash', v_cash,
    'receivables', v_receivables,
    'payables', v_payables,
    'sales_this', v_sales_this,
    'sales_last', v_sales_last,
    'vat_payable', v_vat_payable,
    'stock_value', v_stock_value,
    'low_stock', v_low_stock,
    'invoice_count', v_invoice_count,
    'overdue_count', v_overdue_count,
    'overdue_amount', v_overdue_amount,
    'invoice_outstanding', v_invoice_outstanding,
    'bill_outstanding', v_bill_outstanding,
    'vat_deadline', to_char(date_trunc('month', current_date) + interval '1 month' + interval '14 days', 'YYYY-MM-DD')
  );

  return result;
end;
$$;

revoke all on function get_dashboard_stats() from public;
grant execute on function get_dashboard_stats() to authenticated;

commit;
