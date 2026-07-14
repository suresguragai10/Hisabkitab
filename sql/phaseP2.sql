-- ============================================================
-- HisabKitab — Phase P2: Inventory ↔ Documents + Dashboard
-- Run ONCE in Supabase → SQL Editor → New query. Safe to re-run.
-- ============================================================


-- ------------------------------------------------------------
-- 1. Inventory tables (these were used by the app but never
--    had a committed SQL file — created here for completeness)
-- ------------------------------------------------------------
create table if not exists inventory_items (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null references auth.users(id) on delete cascade,
  name            text not null,
  category        text not null default 'General',
  unit            text not null default 'pcs',
  cost_price      numeric(14,2) not null default 0,
  selling_price   numeric(14,2) not null default 0,
  current_stock   numeric(14,3) not null default 0,
  reorder_level   numeric(14,3) not null default 0,
  description     text,
  is_active       boolean not null default true,
  created_at      timestamptz not null default now()
);

create table if not exists inventory_movements (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null references auth.users(id) on delete cascade,
  item_id         uuid not null references inventory_items(id) on delete cascade,
  movement_type   text not null check (movement_type in ('in','out','adjustment')),
  quantity        numeric(14,3) not null,
  rate            numeric(14,2) not null default 0,
  movement_date   date not null default current_date,
  reference       text,  -- links to invoice/bill number
  reference_id    uuid,  -- links to invoice/bill id
  notes           text,
  created_at      timestamptz not null default now()
);

alter table inventory_items      enable row level security;
alter table inventory_movements  enable row level security;

drop policy if exists "own items"     on inventory_items;
drop policy if exists "own movements" on inventory_movements;
create policy "own items"     on inventory_items     for all using (auth.uid()=user_id) with check (auth.uid()=user_id);
create policy "own movements" on inventory_movements for all using (auth.uid()=user_id) with check (auth.uid()=user_id);

create index if not exists idx_inv_items_user   on inventory_items(user_id);
create index if not exists idx_inv_movs_user    on inventory_movements(user_id);
create index if not exists idx_inv_movs_item    on inventory_movements(item_id);

-- update_stock — called by the manual stock-movement form in Inventory.jsx
create or replace function update_stock(p_item_id uuid, p_delta numeric)
returns void language plpgsql security definer set search_path = public as $$
begin
  update inventory_items
     set current_stock = current_stock + p_delta
   where id = p_item_id and user_id = auth.uid();
end; $$;
grant execute on function update_stock(uuid, numeric) to authenticated;


-- ------------------------------------------------------------
-- 2. Add item_id to invoice_lines and purchase_bill_lines
--    so each line can reference an inventory item
-- ------------------------------------------------------------
alter table invoice_lines       add column if not exists item_id uuid references inventory_items(id);
alter table purchase_bill_lines add column if not exists item_id uuid references inventory_items(id);


-- ------------------------------------------------------------
-- 3. Atomic inventory movement — called by posting functions
-- ------------------------------------------------------------
create or replace function record_stock_movement(
  p_item_id      uuid,
  p_type         text,
  p_qty          numeric,
  p_rate         numeric,
  p_date         date,
  p_reference    text,
  p_reference_id uuid
)
returns void language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid();
begin
  -- Check sufficient stock for out movements
  if p_type = 'out' then
    if (select current_stock from inventory_items where id = p_item_id and user_id = uid) < p_qty then
      raise exception 'Insufficient stock for item. Please check inventory.';
    end if;
  end if;

  insert into inventory_movements (user_id, item_id, movement_type, quantity, rate, movement_date, reference, reference_id)
  values (uid, p_item_id, p_type, p_qty, p_rate, p_date, p_reference, p_reference_id);

  update inventory_items
     set current_stock = current_stock + (case when p_type='in' then p_qty when p_type='out' then -p_qty else 0 end)
   where id = p_item_id and user_id = uid;
end; $$;
grant execute on function record_stock_movement(uuid,text,numeric,numeric,date,text,uuid) to authenticated;


-- ------------------------------------------------------------
-- 4. Updated create_invoice_with_posting — decrements stock
-- ------------------------------------------------------------
create or replace function create_invoice_with_posting(p_header jsonb, p_lines jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  inv_id uuid; v_subtotal numeric(14,2); v_vat numeric(14,2); v_total numeric(14,2);
  debtor_acct uuid; v_id uuid; v_inv_num integer; v_fy text;
  line_rec jsonb; v_item_id uuid; v_qty numeric; v_rate numeric;
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
    coalesce(p_header->>'invoice_date_bs',''), coalesce(p_header->>'due_date_bs','')
  ) returning id into inv_id;

  -- Insert lines + decrement stock for each item
  for line_rec in select * from jsonb_array_elements(p_lines)
  loop
    insert into invoice_lines (invoice_id, description, quantity, unit, rate, amount, vat_rate, vat_amount, line_total, item_id)
    values (inv_id,
      line_rec->>'description',
      coalesce((line_rec->>'quantity')::numeric,1),
      coalesce(line_rec->>'unit','pcs'),
      coalesce((line_rec->>'rate')::numeric,0),
      coalesce((line_rec->>'amount')::numeric,0),
      coalesce((line_rec->>'vat_rate')::numeric,13),
      coalesce((line_rec->>'vat_amount')::numeric,0),
      coalesce((line_rec->>'line_total')::numeric,0),
      nullif(line_rec->>'item_id','')::uuid
    );

    -- Decrement inventory stock if item is linked
    if nullif(line_rec->>'item_id','') is not null then
      v_item_id := (line_rec->>'item_id')::uuid;
      v_qty     := coalesce((line_rec->>'quantity')::numeric,1);
      v_rate    := coalesce((line_rec->>'rate')::numeric,0);
      perform record_stock_movement(
        v_item_id, 'out', v_qty, v_rate,
        (p_header->>'invoice_date')::date,
        'Invoice #' || v_inv_num, inv_id
      );
    end if;
  end loop;

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
    jsonb_build_object('invoice_number', v_inv_num, 'total', v_total));
  return inv_id;
end; $$;
grant execute on function create_invoice_with_posting(jsonb,jsonb) to authenticated;


-- ------------------------------------------------------------
-- 5. Updated create_bill_with_posting — increments stock
-- ------------------------------------------------------------
create or replace function create_bill_with_posting(p_header jsonb, p_lines jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  bill_id uuid; v_subtotal numeric(14,2); v_vat numeric(14,2); v_total numeric(14,2);
  creditor_acct uuid; v_id uuid; v_bill_num integer; v_fy text;
  line_rec jsonb; v_item_id uuid; v_qty numeric; v_rate numeric;
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

  -- Insert lines + increment stock for each item
  for line_rec in select * from jsonb_array_elements(p_lines)
  loop
    insert into purchase_bill_lines (bill_id, description, quantity, unit, rate, amount, vat_rate, vat_amount, line_total, item_id)
    values (bill_id,
      line_rec->>'description',
      coalesce((line_rec->>'quantity')::numeric,1),
      coalesce(line_rec->>'unit','pcs'),
      coalesce((line_rec->>'rate')::numeric,0),
      coalesce((line_rec->>'amount')::numeric,0),
      coalesce((line_rec->>'vat_rate')::numeric,13),
      coalesce((line_rec->>'vat_amount')::numeric,0),
      coalesce((line_rec->>'line_total')::numeric,0),
      nullif(line_rec->>'item_id','')::uuid
    );

    -- Increment inventory stock if item is linked
    if nullif(line_rec->>'item_id','') is not null then
      v_item_id := (line_rec->>'item_id')::uuid;
      v_qty     := coalesce((line_rec->>'quantity')::numeric,1);
      v_rate    := coalesce((line_rec->>'rate')::numeric,0);
      perform record_stock_movement(
        v_item_id, 'in', v_qty, v_rate,
        (p_header->>'bill_date')::date,
        'Bill #' || v_bill_num, bill_id
      );
    end if;
  end loop;

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
    jsonb_build_object('bill_number', v_bill_num, 'total', v_total));
  return bill_id;
end; $$;
grant execute on function create_bill_with_posting(jsonb,jsonb) to authenticated;


-- ------------------------------------------------------------
-- 6. Dashboard stats RPC — one call, all the data
-- ------------------------------------------------------------
create or replace function get_dashboard_stats()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  result jsonb;
  v_cash numeric; v_receivables numeric; v_payables numeric;
  v_sales_this numeric; v_sales_last numeric;
  v_vat_payable numeric; v_stock_value numeric;
  v_low_stock integer; v_invoice_count integer; v_overdue_count integer;
  this_month_start date; last_month_start date; last_month_end date;
begin
  if uid is null then raise exception 'Not authenticated'; end if;

  this_month_start := date_trunc('month', current_date)::date;
  last_month_start := (date_trunc('month', current_date) - interval '1 month')::date;
  last_month_end   := (this_month_start - 1)::date;

  -- Cash & Bank position (from trial balance / account balances)
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

  -- Total receivables (Sundry Debtors net balance)
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

  -- Total payables (Sundry Creditors net balance — shown as positive)
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

  -- Sales this month and last month
  select
    coalesce(sum(case when invoice_date >= this_month_start then subtotal else 0 end),0),
    coalesce(sum(case when invoice_date between last_month_start and last_month_end then subtotal else 0 end),0)
  into v_sales_this, v_sales_last
  from invoices where user_id=uid and status != 'cancelled';

  -- VAT payable this month (output - input)
  select coalesce(sum(case when i.invoice_date >= this_month_start then i.vat_amount else 0 end),0)
       - coalesce((select sum(b.vat_amount) from purchase_bills b
                   where b.user_id=uid and b.bill_date >= this_month_start and b.status!='cancelled'),0)
  into v_vat_payable
  from invoices i where i.user_id=uid and i.status!='cancelled';

  -- Inventory stats
  select coalesce(sum(current_stock * cost_price),0),
         count(case when current_stock <= reorder_level then 1 end)::integer
  into v_stock_value, v_low_stock
  from inventory_items where user_id=uid and is_active=true;

  -- Invoice counts
  select count(*)::integer, count(case when due_date < current_date and status in ('sent','open','partial','overdue') then 1 end)::integer
  into v_invoice_count, v_overdue_count
  from invoices where user_id=uid and status != 'cancelled';

  result := jsonb_build_object(
    'cash',          v_cash,
    'receivables',   v_receivables,
    'payables',      v_payables,
    'sales_this',    v_sales_this,
    'sales_last',    v_sales_last,
    'vat_payable',   v_vat_payable,
    'stock_value',   v_stock_value,
    'low_stock',     v_low_stock,
    'invoice_count', v_invoice_count,
    'overdue_count', v_overdue_count,
    'vat_deadline',  to_char(date_trunc('month', current_date) + interval '1 month' + interval '14 days', 'YYYY-MM-DD')
  );

  return result;
end; $$;
grant execute on function get_dashboard_stats() to authenticated;
