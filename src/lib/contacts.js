// ============================================================
// Phase P3 — Contacts (data access)
// Reads from the `contact_summary` view and writes via the
// `create_contact` / `update_contact` RPCs, which handle the
// backing ledger account atomically.
// ============================================================

import { supabase } from "../supabase";

// List contacts. Optionally filter by role.
//   role = 'all' | 'customer' | 'vendor' | 'both' | 'inactive'
export async function listContacts({ role = "all", search = "" } = {}) {
  let q = supabase.from("contact_summary").select("*");

  if (role === "customer")      q = q.eq("is_customer", true).eq("is_active", true);
  else if (role === "vendor")   q = q.eq("is_vendor",   true).eq("is_active", true);
  else if (role === "both")     q = q.eq("is_customer", true).eq("is_vendor", true).eq("is_active", true);
  else if (role === "inactive") q = q.eq("is_active",   false);
  else                          q = q.eq("is_active",   true);

  if (search && search.trim()) {
    const s = `%${search.trim()}%`;
    q = q.or(`name.ilike.${s},phone.ilike.${s},email.ilike.${s},pan_number.ilike.${s}`);
  }

  const { data, error } = await q.order("name", { ascending: true });
  if (error) throw error;
  return data;
}

export async function getContact(id) {
  const { data, error } = await supabase
    .from("contact_summary")
    .select("*")
    .eq("id", id)
    .single();
  if (error) throw error;
  return data;
}

// Create a contact atomically (creates the backing account too).
// Contact must be at least a customer or a vendor.
export async function createContact(fields) {
  const { data, error } = await supabase.rpc("create_contact", {
    p_name:                 fields.name,
    p_name_np:              fields.nameNp || null,
    p_is_customer:          !!fields.isCustomer,
    p_is_vendor:            !!fields.isVendor,
    p_contact_person:       fields.contactPerson || null,
    p_phone:                fields.phone || null,
    p_email:                fields.email || null,
    p_billing_address:      fields.billingAddress || null,
    p_shipping_address:     fields.shippingAddress || null,
    p_pan_number:           fields.panNumber || null,
    p_vat_number:           fields.vatNumber || null,
    p_payment_terms_days:   fields.paymentTermsDays ?? null,
    p_tds_applicable:       !!fields.tdsApplicable,
    p_tds_rate:             fields.tdsRate ?? null,
    p_notes:                fields.notes || null,
    p_opening_balance:      Number(fields.openingBalance) || 0,
    p_opening_balance_type: fields.openingBalanceType || "debit",
  });
  if (error) throw error;
  return data; // new contact id
}

export async function updateContact(id, fields) {
  const { error } = await supabase.rpc("update_contact", {
    p_id:                 id,
    p_name:               fields.name,
    p_name_np:            fields.nameNp ?? null,
    p_is_customer:        fields.isCustomer ?? null,
    p_is_vendor:          fields.isVendor ?? null,
    p_contact_person:     fields.contactPerson ?? null,
    p_phone:              fields.phone ?? null,
    p_email:              fields.email ?? null,
    p_billing_address:    fields.billingAddress ?? null,
    p_shipping_address:   fields.shippingAddress ?? null,
    p_pan_number:         fields.panNumber ?? null,
    p_vat_number:         fields.vatNumber ?? null,
    p_payment_terms_days: fields.paymentTermsDays ?? null,
    p_tds_applicable:     fields.tdsApplicable ?? null,
    p_tds_rate:           fields.tdsRate ?? null,
    p_notes:              fields.notes ?? null,
    p_is_active:          fields.isActive ?? null,
  });
  if (error) throw error;
}

// Deactivate = soft delete. Reactivate by passing isActive: true to update.
export async function deactivateContact(id) {
  return updateContact(id, { name: null, isActive: false });
}
