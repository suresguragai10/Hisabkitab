import { supabase } from "../supabase";

// ============================================================
// Rate limiting (Phase 7c)
// ============================================================

export async function checkRateLimit(identifier, action) {
  const { data, error } = await supabase.rpc("check_rate_limit", {
    p_identifier: identifier,
    p_action: action,
  });
  if (error) return true; // fail open — don't block if check fails
  return data;
}

export async function logRateLimit(identifier, action, success) {
  await supabase.rpc("log_rate_limit", {
    p_identifier: identifier,
    p_action: action,
    p_success: success,
  });
}

// ============================================================
// Audit log (Phase 7b)
// ============================================================

export async function writeAuditLog(action, tableName, recordId, oldData, newData) {
  await supabase.rpc("write_audit_log", {
    p_action: action,
    p_table_name: tableName,
    p_record_id: recordId || null,
    p_old_data: oldData ? JSON.stringify(oldData) : null,
    p_new_data: newData ? JSON.stringify(newData) : null,
  });
}

export async function listAuditLog(limit = 100) {
  const { data, error } = await supabase
    .from("audit_log")
    .select("*")
    .order("created_at", { ascending: false })
    .limit(limit);
  if (error) throw error;
  return data;
}

// ============================================================
// Accounts (chart of accounts)
// ============================================================

export async function seedDefaultAccountsIfNeeded() {
  const { error } = await supabase.rpc("seed_default_accounts");
  if (error) throw error;
}

export async function listAccounts() {
  const { data, error } = await supabase
    .from("accounts")
    .select("*")
    .eq("is_active", true)
    .order("account_code", { ascending: true })
    .order("name", { ascending: true });
  if (error) throw error;
  return data;
}

export async function createAccount(_userId, account) {
  if (Math.abs(Number(account.opening_balance || 0)) > 0.005) {
    throw new Error("Create the account first, then use the balanced Opening Journal.");
  }
  const reportClass = account.report_class || (
    account.account_type === "asset" ? "current_asset" :
    account.account_type === "liability" ? "current_liability" :
    account.account_type === "equity" ? "equity" :
    account.account_type === "income" ? "other_income" : "operating_expense"
  );
  const { data, error } = await supabase.rpc("create_structured_account", {
    p_name: account.name,
    p_account_code: account.account_code || null,
    p_account_type: account.account_type,
    p_report_class: reportClass,
    p_account_subtype: account.account_subtype || "general",
    p_normal_balance: account.normal_balance || account.opening_balance_type || null,
    p_parent_account_id: account.parent_account_id || null,
    p_cash_flow_category: account.cash_flow_category || "operating",
    p_allow_manual_posting: account.allow_manual_posting !== false,
  });
  if (error) throw error;
  const { data: created, error: readError } = await supabase.from("accounts").select("*").eq("id", data).single();
  if (readError) throw readError;
  return created;
}

export async function deactivateAccount(id) {
  const { error } = await supabase.rpc("deactivate_structured_account", { p_id: id });
  if (error) throw error;
}

// ============================================================
// Parties (customers / vendors) — each party owns one account
// ============================================================

export async function listParties() {
  const { data, error } = await supabase
    .from("parties")
    .select("*, accounts!account_id(id, name, opening_balance, opening_balance_type)")
    .order("created_at", { ascending: false });
  if (error) throw error;
  return data;
}

export async function createParty(_userId, { name, partyType, phone, email, address, panVat, openingBalance }) {
  if (Math.abs(Number(openingBalance || 0)) > 0.005) {
    throw new Error("Create the party first, then use Chart of Accounts > Opening Journal.");
  }
  const { data: partyId, error } = await supabase.rpc("create_contact", {
    p_name: name,
    p_name_np: null,
    p_is_customer: partyType === "customer" || partyType === "both",
    p_is_vendor: partyType === "vendor" || partyType === "both",
    p_contact_person: null,
    p_phone: phone || null,
    p_email: email || null,
    p_billing_address: address || null,
    p_shipping_address: null,
    p_pan_number: panVat || null,
    p_vat_number: null,
    p_payment_terms_days: null,
    p_tds_applicable: false,
    p_tds_rate: null,
    p_notes: null,
    p_opening_balance: 0,
    p_opening_balance_type: "debit",
  });
  if (error) throw error;
  const { data, error: readError } = await supabase
    .from("parties")
    .select("*, accounts!account_id(id, name, account_code, opening_balance, opening_balance_type)")
    .eq("id", partyId)
    .single();
  if (readError) throw readError;
  return data;
}

// ============================================================
// Vouchers
// ============================================================

export async function nextVoucherNumber(voucherType, fiscalYear) {
  const { data, error } = await supabase.rpc("next_voucher_number", {
    p_voucher_type: voucherType,
    p_fiscal_year: fiscalYear,
  });
  if (error) throw error;
  return data;
}

export async function createVoucher(_userId, header, lines) {
  const totalDebit = lines.reduce((sum, line) => sum + Number(line.debit || 0), 0);
  const totalCredit = lines.reduce((sum, line) => sum + Number(line.credit || 0), 0);

  if (lines.length < 2) throw new Error("A voucher needs at least two lines.");
  if (Math.abs(totalDebit - totalCredit) > 0.005) {
    throw new Error(`Debit (${totalDebit}) and credit (${totalCredit}) must be equal.`);
  }
  if (totalDebit <= 0) throw new Error("Voucher amount must be greater than zero.");

  const rpcLines = lines.map((line) => ({
    account_id: line.accountId,
    debit: Number(line.debit || 0),
    credit: Number(line.credit || 0),
    description: line.description?.trim() || null,
  }));

  // The database function creates the header and lines in one transaction.
  // This prevents an incomplete or unbalanced voucher when one insert fails.
  const { data: voucherId, error } = await supabase.rpc("post_voucher", {
    p_type: header.voucher_type,
    p_fiscal_year: header.fiscal_year,
    p_date: header.voucher_date,
    p_narration: header.narration || null,
    p_lines: rpcLines,
  });
  if (error) throw error;

  const { data: voucher, error: readError } = await supabase
    .from("vouchers")
    .select("id, voucher_type, voucher_number, fiscal_year, voucher_date, narration")
    .eq("id", voucherId)
    .single();
  if (readError) throw readError;
  return voucher;
}

export async function listVouchers(limit = 50) {
  const { data, error } = await supabase
    .from("vouchers")
    .select("*, voucher_lines(id, account_id, debit, credit, description, accounts(name))")
    .order("voucher_date", { ascending: false })
    .order("created_at", { ascending: false })
    .limit(limit);
  if (error) throw error;
  return data;
}

export async function voidVoucher(id, reason) {
  const { error } = await supabase.rpc("void_manual_voucher", {
    p_voucher_id: id,
    p_reason: reason,
  });
  if (error) throw error;
}

// ============================================================
// Ledger — running balance for a single account
// ============================================================

export async function getLedger(accountId) {
  const { data: account, error: aErr } = await supabase
    .from("accounts")
    .select("*")
    .eq("id", accountId)
    .single();
  if (aErr) throw aErr;

  const { data: lines, error: lErr } = await supabase
    .from("voucher_lines")
    .select("id, debit, credit, description, vouchers(id, voucher_date, voucher_type, voucher_number, narration, is_void)")
    .eq("account_id", accountId);
  if (lErr) throw lErr;

  const activeLines = lines
    .filter((l) => l.vouchers && !l.vouchers.is_void)
    .sort((a, b) => new Date(a.vouchers.voucher_date) - new Date(b.vouchers.voucher_date));

  // Running balance starts from the account's opening balance.
  let balance = account.opening_balance_type === "debit" ? account.opening_balance : -account.opening_balance;
  const entries = activeLines.map((l) => {
    balance += Number(l.debit) - Number(l.credit);
    return { ...l, runningBalance: balance };
  });

  return { account, entries, closingBalance: balance };
}
