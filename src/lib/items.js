// ============================================================
// Phase P3 — Items + Item Categories (data access)
// ============================================================

import { supabase } from "../supabase";
import { currentFiscalYear } from "./fiscalYear";

// ── Categories ─────────────────────────────────────────────

export async function listCategories({ activeOnly = true } = {}) {
  let q = supabase.from("item_categories").select("*");
  if (activeOnly) q = q.eq("is_active", true);
  const { data, error } = await q.order("sort_order").order("name");
  if (error) throw error;
  return data;
}

export async function createCategory({ name, nameNp = null, parentId = null, notes = null }) {
  const { data, error } = await supabase.rpc("create_item_category", {
    p_name: name,
    p_name_np: nameNp,
    p_parent_id: parentId,
    p_notes: notes,
  });
  if (error) throw error;
  return data;
}

export async function updateCategory(id, patch) {
  const { error } = await supabase.rpc("update_item_category", {
    p_id: id,
    p_name: patch.name ?? null,
    p_name_np: patch.nameNp ?? null,
    p_parent_id: patch.parentId ?? null,
    p_sort_order: patch.sortOrder !== undefined ? Number(patch.sortOrder) : null,
    p_notes: patch.notes ?? null,
    p_is_active: patch.isActive ?? null,
  });
  if (error) throw error;
}

// ── Items ──────────────────────────────────────────────────

export async function listItems({
  search = "",
  categoryId = null,
  brand = null,
  itemType = null,
  activeOnly = true,
  lowStockOnly = false,
} = {}) {
  let q = supabase.from("item_summary").select("*");
  if (activeOnly)         q = q.eq("is_active", true);
  if (categoryId)         q = q.eq("category_id", categoryId);
  if (brand)              q = q.eq("brand", brand);
  if (itemType)           q = q.eq("item_type", itemType);
  if (lowStockOnly)       q = q.eq("is_low_stock", true);
  if (search && search.trim()) {
    const s = `%${search.trim()}%`;
    q = q.or(`name.ilike.${s},sku.ilike.${s},hsn_code.ilike.${s},brand.ilike.${s}`);
  }
  const { data, error } = await q.order("name");
  if (error) throw error;
  return data;
}

export async function getItem(id) {
  const { data, error } = await supabase
    .from("item_summary")
    .select("*")
    .eq("id", id)
    .single();
  if (error) throw error;
  return data;
}

export async function createItem(fields) {
  const { data, error } = await supabase.rpc("create_item", {
    p_name:                fields.name,
    p_name_np:             fields.nameNp || null,
    p_sku:                 fields.sku || null,
    p_hsn_code:            fields.hsnCode || null,
    p_brand:               fields.brand || null,
    p_category_id:         fields.categoryId || null,
    p_item_type:           fields.itemType || "goods",
    p_unit:                fields.unit || "pcs",
    p_sales_price:         Number(fields.salesPrice) || 0,
    p_sales_tax_rate:      Number(fields.salesTaxRate ?? 13),
    p_sales_account_id:    fields.salesAccountId || null,
    p_purchase_price:      Number(fields.purchasePrice) || 0,
    p_purchase_tax_rate:   Number(fields.purchaseTaxRate ?? 13),
    p_purchase_account_id: fields.purchaseAccountId || null,
    p_preferred_vendor_id: fields.preferredVendorId || null,
    p_track_inventory:     fields.trackInventory ?? true,
    p_opening_stock:       Number(fields.openingStock) || 0,
    p_opening_stock_value: Number(fields.openingStockValue) || 0,
    p_reorder_level:       Number(fields.reorderLevel) || 0,
    p_description:         fields.description || null,
    p_opening_date:        new Date().toISOString().slice(0, 10),
    p_fiscal_year:         currentFiscalYear(),
  });
  if (error) throw error;
  return data;
}

export async function updateItem(id, fields) {
  const { error } = await supabase.rpc("update_item", {
    p_id:                  id,
    p_name:                fields.name ?? null,
    p_name_np:             fields.nameNp ?? null,
    p_sku:                 fields.sku ?? null,
    p_hsn_code:            fields.hsnCode ?? null,
    p_brand:               fields.brand ?? null,
    p_category_id:         fields.categoryId ?? null,
    p_item_type:           fields.itemType ?? null,
    p_unit:                fields.unit ?? null,
    p_sales_price:         fields.salesPrice !== undefined ? Number(fields.salesPrice) : null,
    p_sales_tax_rate:      fields.salesTaxRate !== undefined ? Number(fields.salesTaxRate) : null,
    p_sales_account_id:    fields.salesAccountId ?? null,
    p_purchase_price:      fields.purchasePrice !== undefined ? Number(fields.purchasePrice) : null,
    p_purchase_tax_rate:   fields.purchaseTaxRate !== undefined ? Number(fields.purchaseTaxRate) : null,
    p_purchase_account_id: fields.purchaseAccountId ?? null,
    p_preferred_vendor_id: fields.preferredVendorId ?? null,
    p_track_inventory:     fields.trackInventory ?? null,
    p_reorder_level:       fields.reorderLevel !== undefined ? Number(fields.reorderLevel) : null,
    p_description:         fields.description ?? null,
    p_is_active:           fields.isActive ?? null,
  });
  if (error) throw error;
}

export async function deactivateItem(id) {
  return updateItem(id, { isActive: false });
}
