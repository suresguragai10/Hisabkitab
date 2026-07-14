-- ============================================================
-- HisabKitab Stage 3 verification (read-only)
-- Run after phaseP0_3_inventory_cogs.sql.
-- ============================================================

-- 1. Required columns.
select table_name, column_name, data_type
from information_schema.columns
where table_schema = 'public'
  and (
    (table_name = 'inventory_items' and column_name in (
      'valuation_method','average_cost','inventory_value','valuation_start_date','valuation_updated_at'
    ))
    or
    (table_name = 'inventory_movements' and column_name in (
      'source_type','source_line_id','voucher_id','quantity_delta','unit_cost','total_cost',
      'stock_before','stock_after','value_before','value_after','average_cost_before','average_cost_after'
    ))
    or
    (table_name = 'invoice_lines' and column_name in ('inventory_unit_cost','inventory_cost_amount'))
    or
    (table_name = 'purchase_bill_lines' and column_name in ('inventory_unit_cost','inventory_cost_amount'))
    or
    (table_name = 'invoices' and column_name = 'cogs_amount')
    or
    (table_name = 'purchase_bills' and column_name in ('inventory_amount','expense_amount'))
  )
order by table_name, column_name;

-- 2. Required functions.
select proname as function_name,
       pg_get_function_identity_arguments(oid) as arguments
from pg_proc
where proname in (
  'apply_inventory_movement',
  'record_inventory_adjustment',
  'get_inventory_reconciliation',
  'reconcile_inventory_ledger',
  'create_invoice_with_posting',
  'create_bill_with_posting'
)
order by proname;

-- 3. Required system accounts by owner.
select user_id, system_code, name, account_type, group_name
from accounts
where system_code in (
  'inventory_asset','cogs','stock_adjustment','purchase_return','inventory_opening'
)
order by user_id, system_code;

-- 4. Invalid item valuation states. Expected: zero rows.
select id, name, current_stock, average_cost, inventory_value
from inventory_items
where track_inventory = true
  and item_type = 'goods'
  and (
    current_stock < -0.0005
    or inventory_value < -0.005
    or (current_stock <= 0.0005 and abs(inventory_value) > 0.005)
    or (current_stock > 0.0005 and abs(inventory_value - round(current_stock * average_cost, 2)) > 0.02)
  );

-- 5. Movement snapshots that do not roll forward. Expected: zero rows
--    for non-legacy Stage 3 movements.
select id, item_id, source_type,
       stock_before, quantity_delta, stock_after,
       value_before, total_cost, value_after
from inventory_movements
where is_legacy = false
  and (
    abs((stock_before + quantity_delta) - stock_after) > 0.0005
    or (
      quantity_delta > 0
      and abs((value_before + total_cost) - value_after) > 0.01
    )
    or (
      quantity_delta < 0
      and stock_after > 0.0005
      and abs((value_before - total_cost) - value_after) > 0.01
    )
  );

-- 6. New document stock movements missing a voucher. Expected: zero rows.
select id, source_type, reference, reference_id, source_line_id
from inventory_movements
where source_type in ('sale','purchase')
  and is_legacy = false
  and voucher_id is null;

-- 7. New tracked sale lines missing cost snapshots. Expected: zero rows.
select il.id, il.invoice_id, il.item_id
from invoice_lines il
join inventory_items item on item.id = il.item_id
where item.item_type = 'goods'
  and item.track_inventory
  and exists (
    select 1 from inventory_movements m
    where m.source_type = 'sale' and m.source_line_id = il.id and m.is_legacy = false
  )
  and (il.inventory_unit_cost is null or il.inventory_cost_amount is null);

-- 8. New tracked purchase lines missing valuation snapshots. Expected: zero rows.
select bl.id, bl.bill_id, bl.item_id
from purchase_bill_lines bl
join inventory_items item on item.id = bl.item_id
where item.item_type = 'goods'
  and item.track_inventory
  and exists (
    select 1 from inventory_movements m
    where m.source_type = 'purchase' and m.source_line_id = bl.id and m.is_legacy = false
  )
  and (bl.inventory_unit_cost is null or bl.inventory_cost_amount is null);

-- 9. Non-legacy movement dates must be chronological and on/after cutover.
--    Expected: zero rows.
with ordered as (
  select m.id, m.item_id, m.movement_date, m.created_at,
         i.valuation_start_date,
         lag(m.movement_date) over (
           partition by m.item_id order by m.created_at, m.id
         ) as previous_movement_date
    from inventory_movements m
    join inventory_items i on i.id = m.item_id
   where m.is_legacy = false
)
select *
from ordered
where movement_date < valuation_start_date
   or (previous_movement_date is not null and movement_date < previous_movement_date);

-- 10. Current signed-in user's reconciliation result.
--     Expected after reviewed reconciliation: difference = 0.00.
select get_inventory_reconciliation();
