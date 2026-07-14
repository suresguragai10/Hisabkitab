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
    .order("group_name", { ascending: true })
    .order("name", { ascending: true });
  if (error) throw error;
  return data;
}

export async function createAccount(userId, account) {
  const { data, error } = await supabase
    .from("accounts")
    .insert({ user_id: userId, ...account })
    .select()
    .single();
  if (error) throw error;
  return data;
}

export async function deactivateAccount(id) {
  const { error } = await supabase.from("accounts").update({ is_active: false }).eq("id", id);
  if (error) throw error;
}

// ============================================================
// Parties (customers / vendors) — each party owns one account
// ============================================================

export async function listParties() {
  const { data, error } = await supabase
    .from("parties")
    .select("*, accounts(id, name, opening_balance, opening_balance_type)")
    .order("created_at", { ascending: false });
  if (error) throw error;
  return data;
}

export async function createParty(userId, { name, partyType, phone, email, address, panVat, openingBalance, openingBalanceType }) {
  // A party is backed by its own ledger account under Sundry Debtors/Creditors.
  const groupName = partyType === "vendor" ? "Sundry Creditors" : "Sundry Debtors";
  const accountType = partyType === "vendor" ? "liability" : "asset";

  const account = await createAccount(userId, {
    name,
    account_type: accountType,
    group_name: groupName,
    is_party_account: true,
    opening_balance: openingBalance || 0,
    opening_balance_type: openingBalanceType || "debit",
  });

  const { data, error } = await supabase
    .from("parties")
    .insert({
      user_id: userId,
      account_id: account.id,
      party_type: partyType,
      phone: phone || null,
      email: email || null,
      address: address || null,
      pan_vat_number: panVat || null,
    })
    .select("*, accounts(id, name, opening_balance, opening_balance_type)")
    .single();
  if (error) throw error;
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
