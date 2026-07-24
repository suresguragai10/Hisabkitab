import { supabase } from "../supabase";

export async function listStructuredAccounts({ includeInactive = true } = {}) {
  let query = supabase
    .from("accounts")
    .select("*")
    .order("account_code", { ascending: true });
  if (!includeInactive) query = query.eq("is_active", true);
  const { data, error } = await query;
  if (error) throw error;
  return data || [];
}

export async function createStructuredAccount(fields) {
  const { data, error } = await supabase.rpc("create_structured_account", {
    p_name: fields.name,
    p_account_code: fields.accountCode || null,
    p_account_type: fields.accountType,
    p_report_class: fields.reportClass,
    p_account_subtype: fields.accountSubtype || "general",
    p_normal_balance: fields.normalBalance,
    p_parent_account_id: fields.parentAccountId || null,
    p_cash_flow_category: fields.cashFlowCategory,
    p_allow_manual_posting: !!fields.allowManualPosting,
  });
  if (error) throw error;
  return data;
}

export async function updateStructuredAccount(id, fields) {
  const { error } = await supabase.rpc("update_structured_account", {
    p_id: id,
    p_name: fields.name,
    p_account_code: fields.accountCode,
    p_account_type: fields.accountType,
    p_report_class: fields.reportClass,
    p_account_subtype: fields.accountSubtype || "general",
    p_normal_balance: fields.normalBalance,
    p_parent_account_id: fields.parentAccountId || null,
    p_cash_flow_category: fields.cashFlowCategory,
    p_allow_manual_posting: !!fields.allowManualPosting,
  });
  if (error) throw error;
}

export async function deactivateStructuredAccount(id) {
  const { error } = await supabase.rpc("deactivate_structured_account", { p_id: id });
  if (error) throw error;
}

export async function deleteStructuredAccount(id) {
  const { error } = await supabase.rpc("delete_structured_account", { p_id: id });
  if (error) throw error;
}

export async function mergeAccount(sourceId, targetId) {
  const { error } = await supabase.rpc("merge_account", { p_source_id: sourceId, p_target_id: targetId });
  if (error) throw error;
}

export async function postOpeningJournal({ fiscalYear, date, notes, lines }) {
  const payload = lines
    .map((line) => ({
      account_id: line.accountId,
      debit: Number(line.debit || 0),
      credit: Number(line.credit || 0),
      description: line.description?.trim() || null,
    }))
    .filter((line) => line.account_id && (line.debit > 0 || line.credit > 0));

  const { data, error } = await supabase.rpc("post_opening_journal", {
    p_fiscal_year: fiscalYear,
    p_date: date,
    p_lines: payload,
    p_notes: notes || null,
  });
  if (error) throw error;
  return data;
}

export async function migrateLegacyOpeningBalances({ fiscalYear, date, offsetAccountId, notes }) {
  const { data, error } = await supabase.rpc("migrate_legacy_opening_balances", {
    p_fiscal_year: fiscalYear,
    p_date: date,
    p_offset_account_id: offsetAccountId || null,
    p_notes: notes || "Converted from legacy opening-balance fields",
  });
  if (error) throw error;
  return data;
}

export async function listOpeningJournals() {
  const { data, error } = await supabase
    .from("opening_journals")
    .select("*")
    .order("opening_date", { ascending: false });
  if (error) throw error;
  return data || [];
}
