import { supabase } from "../supabase";

export async function listInventoryItems() {
  const { data, error } = await supabase
    .from("item_summary")
    .select("id,name,sku,category_name,unit,track_inventory,item_type,current_stock,reorder_level,average_cost,purchase_price,inventory_value,is_low_stock,is_active")
    .eq("track_inventory", true)
    .eq("item_type", "goods")
    .order("name");
  if (error) throw error;
  return data || [];
}

export async function listInventoryMovements(itemId, limit = 100) {
  const { data, error } = await supabase
    .from("inventory_movements")
    .select("id,item_id,movement_type,source_type,quantity,quantity_delta,unit_cost,total_cost,movement_date,reference,notes,stock_before,stock_after,value_before,value_after,average_cost_before,average_cost_after,voucher_id,is_legacy,created_at")
    .eq("item_id", itemId)
    .order("movement_date", { ascending: false })
    .order("created_at", { ascending: false })
    .limit(limit);
  if (error) throw error;
  return data || [];
}

export async function getInventoryReconciliation() {
  const { data, error } = await supabase.rpc("get_inventory_reconciliation");
  if (error) throw error;
  return data || null;
}

export async function recordInventoryAdjustment({
  itemId,
  reasonType,
  quantity,
  unitCost,
  date,
  fiscalYear,
  reference,
  notes,
}) {
  const { data, error } = await supabase.rpc("record_inventory_adjustment", {
    p_item_id: itemId,
    p_reason_type: reasonType,
    p_quantity: quantity,
    p_unit_cost: unitCost || null,
    p_date: date,
    p_fiscal_year: fiscalYear,
    p_reference: reference || null,
    p_notes: notes || null,
  });
  if (error) throw error;
  return data;
}

export async function reconcileInventoryLedger({ date, fiscalYear, reason }) {
  const { data, error } = await supabase.rpc("reconcile_inventory_ledger", {
    p_date: date,
    p_fiscal_year: fiscalYear,
    p_reason: reason,
  });
  if (error) throw error;
  return data;
}
