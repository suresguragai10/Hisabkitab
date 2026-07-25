-- ============================================================
-- HisabKitab P2.12 -- Workspace-scoping fix, batch 5: Inventory.
--
-- Part of the larger workspace-scoping remediation (see memory:
-- workspace_scoping_gap.md). Fetched live and fixed with the minimal,
-- mechanical change: the uid variable's source only (auth.uid() ->
-- get_workspace_owner()). No other logic touched.
-- ============================================================

create or replace function apply_inventory_movement(
  p_item_id uuid, p_quantity_delta numeric, p_inbound_unit_cost numeric, p_date date,
  p_source_type text, p_reference text, p_reference_id uuid, p_source_line_id uuid, p_notes text default null::text
)
returns table(movement_id uuid, applied_unit_cost numeric, applied_total_cost numeric, resulting_stock numeric, resulting_value numeric, resulting_average_cost numeric)
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := get_workspace_owner();
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

create or replace function create_item(
  p_name text, p_name_np text default null::text, p_sku text default null::text, p_hsn_code text default null::text,
  p_brand text default null::text, p_category_id uuid default null::uuid, p_item_type text default 'goods'::text,
  p_unit text default 'pcs'::text, p_sales_price numeric default 0, p_sales_tax_rate numeric default 13,
  p_sales_account_id uuid default null::uuid, p_purchase_price numeric default 0, p_purchase_tax_rate numeric default 13,
  p_purchase_account_id uuid default null::uuid, p_preferred_vendor_id uuid default null::uuid,
  p_track_inventory boolean default true, p_opening_stock numeric default 0, p_opening_stock_value numeric default 0,
  p_reorder_level numeric default 0, p_description text default null::text, p_opening_date date default current_date,
  p_fiscal_year text default null::text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := get_workspace_owner();
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

create or replace function update_item(
  p_id uuid, p_name text default null::text, p_name_np text default null::text, p_sku text default null::text,
  p_hsn_code text default null::text, p_brand text default null::text, p_category_id uuid default null::uuid,
  p_item_type text default null::text, p_unit text default null::text, p_sales_price numeric default null::numeric,
  p_sales_tax_rate numeric default null::numeric, p_sales_account_id uuid default null::uuid,
  p_purchase_price numeric default null::numeric, p_purchase_tax_rate numeric default null::numeric,
  p_purchase_account_id uuid default null::uuid, p_preferred_vendor_id uuid default null::uuid,
  p_track_inventory boolean default null::boolean, p_reorder_level numeric default null::numeric,
  p_description text default null::text, p_is_active boolean default null::boolean
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := get_workspace_owner();
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

create or replace function create_item_category(p_name text, p_name_np text default null::text, p_parent_id uuid default null::uuid, p_notes text default null::text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := get_workspace_owner();
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

create or replace function update_item_category(p_id uuid, p_name text default null::text, p_name_np text default null::text, p_parent_id uuid default null::uuid, p_sort_order integer default null::integer, p_notes text default null::text, p_is_active boolean default null::boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := get_workspace_owner();
begin
  if uid is null then raise exception 'Not authenticated'; end if;

  if not exists (select 1 from item_categories where id = p_id and user_id = uid) then
    raise exception 'Item category not found.';
  end if;

  update item_categories
     set name       = coalesce(p_name, name),
         name_np    = coalesce(p_name_np, name_np),
         parent_id  = coalesce(p_parent_id, parent_id),
         sort_order = coalesce(p_sort_order, sort_order),
         notes      = coalesce(p_notes, notes),
         is_active  = coalesce(p_is_active, is_active),
         updated_at = now()
   where id = p_id and user_id = uid;
end;
$$;

create or replace function record_inventory_adjustment(p_item_id uuid, p_reason_type text, p_quantity numeric, p_unit_cost numeric, p_date date, p_fiscal_year text, p_reference text default null::text, p_notes text default null::text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := get_workspace_owner();
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

create or replace function reconcile_inventory_ledger(p_date date, p_fiscal_year text, p_reason text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := get_workspace_owner();
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
