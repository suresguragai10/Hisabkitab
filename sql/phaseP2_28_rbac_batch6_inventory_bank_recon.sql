-- ============================================================
-- HisabKitab P2.28 -- RBAC batch 6: inventory adjustments and bank
-- reconciliation (owner + accountant).
-- ============================================================

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
  perform assert_role(array['owner','accountant']);
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
  perform assert_role(array['owner','accountant']);
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

create or replace function match_statement_line(p_line_id uuid, p_voucher_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform assert_role(array['owner','accountant']);
  update bank_statement_lines set matched_voucher_id = p_voucher_id, is_matched = true where id = p_line_id and user_id = get_workspace_owner();
end;
$$;

create or replace function reconcile_statement(p_statement_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform assert_role(array['owner','accountant']);
  update bank_statements set status = 'reconciled' where id = p_statement_id and user_id = get_workspace_owner();
end;
$$;

create or replace function unmatch_statement_line(p_line_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform assert_role(array['owner','accountant']);
  update bank_statement_lines set matched_voucher_id = null, is_matched = false where id = p_line_id and user_id = get_workspace_owner();
end;
$$;
