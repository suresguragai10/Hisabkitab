import { supabase } from "../supabase";

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

export async function createVoucher(userId, header, lines) {
  const totalDebit = lines.reduce((s, l) => s + Number(l.debit || 0), 0);
  const totalCredit = lines.reduce((s, l) => s + Number(l.credit || 0), 0);
  if (Math.abs(totalDebit - totalCredit) > 0.005) {
    throw new Error(`Debit (${totalDebit}) and credit (${totalCredit}) must be equal.`);
  }
  if (totalDebit === 0) {
    throw new Error("Voucher amount cannot be zero.");
  }

  const { data: voucher, error: vErr } = await supabase
    .from("vouchers")
    .insert({ user_id: userId, ...header })
    .select()
    .single();
  if (vErr) throw vErr;

  const rows = lines
    .filter((l) => Number(l.debit || 0) !== 0 || Number(l.credit || 0) !== 0)
    .map((l) => ({
      voucher_id: voucher.id,
      account_id: l.accountId,
      debit: Number(l.debit || 0),
      credit: Number(l.credit || 0),
      description: l.description || null,
    }));

  const { error: lErr } = await supabase.from("voucher_lines").insert(rows);
  if (lErr) {
    // Roll back the header if the lines fail, so we never leave an unbalanced voucher.
    await supabase.from("vouchers").delete().eq("id", voucher.id);
    throw lErr;
  }

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
  const { error } = await supabase
    .from("vouchers")
    .update({ is_void: true, void_reason: reason, voided_at: new Date().toISOString() })
    .eq("id", id);
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
