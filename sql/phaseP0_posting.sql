-- ============================================================
-- HisabKitab — Phase P0: Make the books real (document → ledger)
--
-- This is the integrity fix from the audit. It makes every invoice,
-- purchase bill, and payment post a balanced double-entry voucher
-- IN THE SAME DATABASE TRANSACTION, so the ledger can never drift
-- from the documents.
--
-- Run ONCE in Supabase → SQL Editor → New query. Safe to re-run:
-- every statement is idempotent (IF NOT EXISTS / OR REPLACE / guarded
-- backfills). It does not delete anything.
--
-- After running this, also run the one-time backfill at the very
-- bottom (select backfill_post_existing();) to post vouchers for any
-- invoices/bills you already created before this fix.
-- ============================================================


-- ------------------------------------------------------------
-- 0. Missing tables that the app already uses but were never in
--    a committed schema file (purchase_bills / inventory). Created
--    here so the database matches the code. If you already made
--    these by hand in Supabase, these IF NOT EXISTS statements are
--    no-ops.
-- ------------------------------------------------------------
create table if not exists purchase_bills (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  bill_number integer not null,
  fiscal_year text not null,
  bill_date date not null,
  due_date date,
  vendor_id uuid references parties(id),
  vendor_name text not null,
  vendor_address text,
  vendor_pan text,
  vendor_bill_ref text,
  subtotal numeric(14,2) not null default 0,
  vat_amount numeric(14,2) not null default 0,
  total numeric(14,2) not null default 0,
  status text not null default 'unpaid' check (status in ('unpaid','paid','cancelled')),
  notes text,
  created_at timestamptz not null default now()
);

create table if not exists purchase_bill_lines (
  id uuid primary key default gen_random_uuid(),
  bill_id uuid not null references purchase_bills(id) on delete cascade,
  description text not null,
  quantity numeric(10,3) not null default 1,
  unit text default 'pcs',
  rate numeric(14,2) not null default 0,
  amount numeric(14,2) not null default 0,
  vat_rate numeric(5,2) not null default 13,
  vat_amount numeric(14,2) not null default 0,
  line_total numeric(14,2) not null default 0
);

alter table purchase_bills enable row level security;
alter table purchase_bill_lines enable row level security;

drop policy if exists "own bills" on purchase_bills;
create policy "own bills" on purchase_bills for all
  using (auth.uid() = user_id) with check (auth.uid() = user_id);

drop policy if exists "own bill lines" on purchase_bill_lines;
create policy "own bill lines" on purchase_bill_lines for all
  using (exists (select 1 from purchase_bills b where b.id = purchase_bill_lines.bill_id and b.user_id = auth.uid()))
  with check (exists (select 1 from purchase_bills b where b.id = purchase_bill_lines.bill_id and b.user_id = auth.uid()));

create index if not exists idx_bills_user on purchase_bills(user_id);
create index if not exists idx_bill_lines_bill on purchase_bill_lines(bill_id);

create or replace function next_bill_number(p_fiscal_year text)
returns integer language sql security definer set search_path = public as $$
  select coalesce(max(bill_number), 0) + 1
  from purchase_bills
  where user_id = auth.uid() and fiscal_year = p_fiscal_year;
$$;
grant execute on function next_bill_number(text) to authenticated;


-- ------------------------------------------------------------
-- 1. Link columns: each document points at the voucher it posted.
--    NULL = not yet posted (used by the backfill).
-- ------------------------------------------------------------
alter table invoices        add column if not exists voucher_id uuid references vouchers(id);
alter table invoices        add column if not exists settlement_voucher_id uuid references vouchers(id);
alter table purchase_bills   add column if not exists voucher_id uuid references vouchers(id);
alter table purchase_bills   add column if not exists settlement_voucher_id uuid references vouchers(id);


-- ------------------------------------------------------------
-- 2. Stable system codes on accounts, so posting logic never has
--    to match on display names (which the user can rename).
-- ------------------------------------------------------------
alter table accounts add column if not exists system_code text;

-- One system account of each code per user.
create unique index if not exists uq_accounts_system_code
  on accounts(user_id, system_code) where system_code is not null;

-- Backfill codes for existing users by matching the seeded names.
update accounts set system_code = 'sales'          where system_code is null and name = 'Sales Account';
update accounts set system_code = 'purchase'       where system_code is null and name = 'Purchase Account';
update accounts set system_code = 'vat_payable'    where system_code is null and name = 'VAT Payable';
update accounts set system_code = 'vat_receivable' where system_code is null and name = 'VAT Receivable';
update accounts set system_code = 'cash'           where system_code is null and name = 'Cash in Hand';
update accounts set system_code = 'bank'           where system_code is null and name = 'Bank Account';


-- ------------------------------------------------------------
-- 3. Resolve-or-create a system account for the current user.
--    Guarantees the posting engine always has the account it needs,
--    even for older books seeded before this migration.
-- ------------------------------------------------------------
create or replace function resolve_system_account(p_code text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  acc_id uuid;
begin
  if uid is null then raise exception 'Not authenticated'; end if;

  select id into acc_id from accounts
   where user_id = uid and system_code = p_code limit 1;
  if acc_id is not null then return acc_id; end if;

  -- Not found (older book or control account): create it.
  insert into accounts (user_id, name, account_type, group_name, is_party_account, opening_balance_type, system_code)
  values (
    uid,
    case p_code
      when 'sales'          then 'Sales Account'
      when 'purchase'       then 'Purchase Account'
      when 'vat_payable'    then 'VAT Payable'
      when 'vat_receivable' then 'VAT Receivable'
      when 'cash'           then 'Cash in Hand'
      when 'bank'           then 'Bank Account'
      when 'ar_control'     then 'Sundry Debtors (Control)'
      when 'ap_control'     then 'Sundry Creditors (Control)'
      else p_code
    end,
    case p_code
      when 'sales'          then 'income'
      when 'purchase'       then 'expense'
      when 'vat_payable'    then 'liability'
      when 'vat_receivable' then 'asset'
      when 'ap_control'     then 'liability'
      else 'asset'
    end,
    case p_code
      when 'sales'          then 'Direct Income'
      when 'purchase'       then 'Direct Expense'
      when 'vat_payable'    then 'Duties & Taxes'
      when 'vat_receivable' then 'Duties & Taxes'
      when 'cash'           then 'Cash-in-Hand'
      when 'bank'           then 'Bank Accounts'
      when 'ar_control'     then 'Sundry Debtors'
      when 'ap_control'     then 'Sundry Creditors'
      else 'General'
    end,
    false,
    case p_code
      when 'sales' then 'credit'
      when 'vat_payable' then 'credit'
      when 'ap_control' then 'credit'
      else 'debit'
    end,
    p_code
  )
  returning id into acc_id;

  return acc_id;
end;
$$;
grant execute on function resolve_system_account(text) to authenticated;


-- ------------------------------------------------------------
-- 4. Internal helper: post one balanced voucher and return its id.
--    p_lines is a jsonb array of {account_id, debit, credit, description}.
--    Enforces debit = credit before committing.
-- ------------------------------------------------------------
create or replace function post_voucher(
  p_type text,
  p_fiscal_year text,
  p_date date,
  p_narration text,
  p_lines jsonb
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  v_id uuid;
  v_num integer;
  tot_debit numeric(14,2);
  tot_credit numeric(14,2);
begin
  if uid is null then raise exception 'Not authenticated'; end if;

  select coalesce(sum((l->>'debit')::numeric),0),
         coalesce(sum((l->>'credit')::numeric),0)
    into tot_debit, tot_credit
    from jsonb_array_elements(p_lines) l;

  if abs(tot_debit - tot_credit) > 0.005 then
    raise exception 'Voucher not balanced: debit % vs credit %', tot_debit, tot_credit;
  end if;
  if tot_debit = 0 then
    raise exception 'Voucher amount cannot be zero.';
  end if;

  select next_voucher_number(p_type, p_fiscal_year) into v_num;

  insert into vouchers (user_id, voucher_type, voucher_number, fiscal_year, voucher_date, narration)
  values (uid, p_type, v_num, p_fiscal_year, p_date, p_narration)
  returning id into v_id;

  insert into voucher_lines (voucher_id, account_id, debit, credit, description)
  select v_id,
         (l->>'account_id')::uuid,
         coalesce((l->>'debit')::numeric,0),
         coalesce((l->>'credit')::numeric,0),
         l->>'description'
    from jsonb_array_elements(p_lines) l
   where coalesce((l->>'debit')::numeric,0) <> 0
      or coalesce((l->>'credit')::numeric,0) <> 0;

  return v_id;
end;
$$;
grant execute on function post_voucher(text, text, date, text, jsonb) to authenticated;


-- ------------------------------------------------------------
-- 5. Create an invoice AND its sales voucher, atomically.
--    Replaces the two-step client insert. If anything fails the
--    whole thing rolls back — you never get an invoice without a
--    matching ledger entry, or vice-versa.
--
--    p_header: { invoice_number, fiscal_year, invoice_date, due_date,
--                party_id, party_name, party_address, party_pan,
--                notes, status }
--    p_lines : [ { description, quantity, unit, rate, amount,
--                  vat_rate, vat_amount, line_total } ]
-- ------------------------------------------------------------
create or replace function create_invoice_with_posting(p_header jsonb, p_lines jsonb)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  inv_id uuid;
  v_subtotal numeric(14,2);
  v_vat numeric(14,2);
  v_total numeric(14,2);
  debtor_acct uuid;
  v_id uuid;
begin
  if uid is null then raise exception 'Not authenticated'; end if;

  select coalesce(sum((l->>'amount')::numeric),0),
         coalesce(sum((l->>'vat_amount')::numeric),0)
    into v_subtotal, v_vat
    from jsonb_array_elements(p_lines) l;
  v_total := v_subtotal + v_vat;

  insert into invoices (
    user_id, invoice_number, fiscal_year, invoice_date, due_date,
    party_id, party_name, party_address, party_pan,
    subtotal, vat_amount, total, status, notes
  ) values (
    uid,
    (p_header->>'invoice_number')::integer,
    p_header->>'fiscal_year',
    (p_header->>'invoice_date')::date,
    nullif(p_header->>'due_date','')::date,
    nullif(p_header->>'party_id','')::uuid,
    p_header->>'party_name',
    p_header->>'party_address',
    p_header->>'party_pan',
    v_subtotal, v_vat, v_total,
    coalesce(p_header->>'status','draft'),
    p_header->>'notes'
  ) returning id into inv_id;

  insert into invoice_lines (invoice_id, description, quantity, unit, rate, amount, vat_rate, vat_amount, line_total)
  select inv_id, l->>'description',
         coalesce((l->>'quantity')::numeric,1), coalesce(l->>'unit','pcs'),
         coalesce((l->>'rate')::numeric,0), coalesce((l->>'amount')::numeric,0),
         coalesce((l->>'vat_rate')::numeric,13), coalesce((l->>'vat_amount')::numeric,0),
         coalesce((l->>'line_total')::numeric,0)
    from jsonb_array_elements(p_lines) l;

  -- Debit the customer: their own ledger account if we have one,
  -- otherwise the Sundry Debtors control account.
  if nullif(p_header->>'party_id','') is not null then
    select account_id into debtor_acct from parties
     where id = (p_header->>'party_id')::uuid and user_id = uid;
  end if;
  if debtor_acct is null then
    debtor_acct := resolve_system_account('ar_control');
  end if;

  -- Sales voucher:  Dr Customer (total) / Cr Sales (subtotal) / Cr VAT Payable (vat)
  v_id := post_voucher(
    'sales',
    p_header->>'fiscal_year',
    (p_header->>'invoice_date')::date,
    'Sales Invoice #' || (p_header->>'invoice_number'),
    jsonb_build_array(
      jsonb_build_object('account_id', debtor_acct, 'debit', v_total, 'credit', 0, 'description', p_header->>'party_name'),
      jsonb_build_object('account_id', resolve_system_account('sales'), 'debit', 0, 'credit', v_subtotal, 'description', 'Sales'),
      jsonb_build_object('account_id', resolve_system_account('vat_payable'), 'debit', 0, 'credit', v_vat, 'description', 'Output VAT 13%')
    )
  );

  update invoices set voucher_id = v_id where id = inv_id;

  perform write_audit_log('create', 'invoices', inv_id::text, null,
    jsonb_build_object('invoice_number', p_header->>'invoice_number', 'total', v_total));

  return inv_id;
end;
$$;
grant execute on function create_invoice_with_posting(jsonb, jsonb) to authenticated;


-- ------------------------------------------------------------
-- 6. Create a purchase bill AND its purchase voucher, atomically.
--    Purchase voucher: Dr Purchase (subtotal) / Dr VAT Receivable (vat)
--                      / Cr Vendor (total)
-- ------------------------------------------------------------
create or replace function create_bill_with_posting(p_header jsonb, p_lines jsonb)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  bill_id uuid;
  v_subtotal numeric(14,2);
  v_vat numeric(14,2);
  v_total numeric(14,2);
  creditor_acct uuid;
  v_id uuid;
begin
  if uid is null then raise exception 'Not authenticated'; end if;

  select coalesce(sum((l->>'amount')::numeric),0),
         coalesce(sum((l->>'vat_amount')::numeric),0)
    into v_subtotal, v_vat
    from jsonb_array_elements(p_lines) l;
  v_total := v_subtotal + v_vat;

  insert into purchase_bills (
    user_id, bill_number, fiscal_year, bill_date, due_date,
    vendor_id, vendor_name, vendor_address, vendor_pan, vendor_bill_ref,
    subtotal, vat_amount, total, status, notes
  ) values (
    uid,
    (p_header->>'bill_number')::integer,
    p_header->>'fiscal_year',
    (p_header->>'bill_date')::date,
    nullif(p_header->>'due_date','')::date,
    nullif(p_header->>'vendor_id','')::uuid,
    p_header->>'vendor_name',
    p_header->>'vendor_address',
    p_header->>'vendor_pan',
    p_header->>'vendor_bill_ref',
    v_subtotal, v_vat, v_total,
    coalesce(p_header->>'status','unpaid'),
    p_header->>'notes'
  ) returning id into bill_id;

  insert into purchase_bill_lines (bill_id, description, quantity, unit, rate, amount, vat_rate, vat_amount, line_total)
  select bill_id, l->>'description',
         coalesce((l->>'quantity')::numeric,1), coalesce(l->>'unit','pcs'),
         coalesce((l->>'rate')::numeric,0), coalesce((l->>'amount')::numeric,0),
         coalesce((l->>'vat_rate')::numeric,13), coalesce((l->>'vat_amount')::numeric,0),
         coalesce((l->>'line_total')::numeric,0)
    from jsonb_array_elements(p_lines) l;

  if nullif(p_header->>'vendor_id','') is not null then
    select account_id into creditor_acct from parties
     where id = (p_header->>'vendor_id')::uuid and user_id = uid;
  end if;
  if creditor_acct is null then
    creditor_acct := resolve_system_account('ap_control');
  end if;

  v_id := post_voucher(
    'purchase',
    p_header->>'fiscal_year',
    (p_header->>'bill_date')::date,
    'Purchase Bill #' || (p_header->>'bill_number'),
    jsonb_build_array(
      jsonb_build_object('account_id', resolve_system_account('purchase'), 'debit', v_subtotal, 'credit', 0, 'description', 'Purchase'),
      jsonb_build_object('account_id', resolve_system_account('vat_receivable'), 'debit', v_vat, 'credit', 0, 'description', 'Input VAT 13%'),
      jsonb_build_object('account_id', creditor_acct, 'debit', 0, 'credit', v_total, 'description', p_header->>'vendor_name')
    )
  );

  update purchase_bills set voucher_id = v_id where id = bill_id;

  perform write_audit_log('create', 'purchase_bills', bill_id::text, null,
    jsonb_build_object('bill_number', p_header->>'bill_number', 'total', v_total));

  return bill_id;
end;
$$;
grant execute on function create_bill_with_posting(jsonb, jsonb) to authenticated;


-- ------------------------------------------------------------
-- 7. Record a payment/receipt against a document, atomically.
--    p_doc_type: 'invoice' | 'bill'
--    p_deposit_code: 'cash' | 'bank'  (where the money went / came from)
--    For an invoice (receipt): Dr Cash/Bank / Cr Customer, status→paid.
--    For a bill (payment):     Dr Vendor  / Cr Cash/Bank, status→paid.
-- ------------------------------------------------------------
create or replace function settle_document(
  p_doc_type text,
  p_doc_id uuid,
  p_amount numeric,
  p_deposit_code text,
  p_date date
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  cashbank uuid;
  party_acct uuid;
  fy text;
  v_id uuid;
  h record;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  if p_amount <= 0 then raise exception 'Amount must be positive.'; end if;
  cashbank := resolve_system_account(coalesce(p_deposit_code,'cash'));

  if p_doc_type = 'invoice' then
    select * into h from invoices where id = p_doc_id and user_id = uid;
    if not found then raise exception 'Invoice not found.'; end if;
    fy := h.fiscal_year;
    if h.party_id is not null then
      select account_id into party_acct from parties where id = h.party_id and user_id = uid;
    end if;
    if party_acct is null then party_acct := resolve_system_account('ar_control'); end if;

    v_id := post_voucher('receipt', fy, p_date,
      'Receipt against Invoice #' || h.invoice_number,
      jsonb_build_array(
        jsonb_build_object('account_id', cashbank,   'debit', p_amount, 'credit', 0, 'description', 'Received'),
        jsonb_build_object('account_id', party_acct, 'debit', 0, 'credit', p_amount, 'description', h.party_name)
      ));
    update invoices set status = 'paid', settlement_voucher_id = v_id where id = p_doc_id;

  elsif p_doc_type = 'bill' then
    select * into h from purchase_bills where id = p_doc_id and user_id = uid;
    if not found then raise exception 'Bill not found.'; end if;
    fy := h.fiscal_year;
    if h.vendor_id is not null then
      select account_id into party_acct from parties where id = h.vendor_id and user_id = uid;
    end if;
    if party_acct is null then party_acct := resolve_system_account('ap_control'); end if;

    v_id := post_voucher('payment', fy, p_date,
      'Payment against Bill #' || h.bill_number,
      jsonb_build_array(
        jsonb_build_object('account_id', party_acct, 'debit', p_amount, 'credit', 0, 'description', h.vendor_name),
        jsonb_build_object('account_id', cashbank,   'debit', 0, 'credit', p_amount, 'description', 'Paid')
      ));
    update purchase_bills set status = 'paid', settlement_voucher_id = v_id where id = p_doc_id;

  else
    raise exception 'Unknown document type: %', p_doc_type;
  end if;

  return v_id;
end;
$$;
grant execute on function settle_document(text, uuid, numeric, text, date) to authenticated;


-- ------------------------------------------------------------
-- 8. Trial Balance view — the integrity check. Sum of all debits
--    must equal sum of all credits. If it ever doesn't, something
--    posted wrong. Opening balances are folded in.
-- ------------------------------------------------------------
create or replace view trial_balance as
with movements as (
  select a.id as account_id, a.user_id, a.name, a.account_type, a.group_name,
         (case when a.opening_balance_type = 'debit' then a.opening_balance else -a.opening_balance end)
         + coalesce(sum(vl.debit - vl.credit), 0) as balance
    from accounts a
    left join voucher_lines vl on vl.account_id = a.id
    left join vouchers v on v.id = vl.voucher_id and v.is_void = false
   where a.is_active = true
   group by a.id
)
select account_id, user_id, name, account_type, group_name,
       case when balance >= 0 then balance else 0 end as debit,
       case when balance < 0 then -balance else 0 end as credit
  from movements
 where abs(balance) > 0.005;

-- RLS: the view runs as the querying user, so it only ever shows
-- their own accounts (accounts already has RLS). No extra policy needed.


-- ------------------------------------------------------------
-- 9. One-time backfill: post vouchers for documents created BEFORE
--    this fix (voucher_id is null). Idempotent — running it twice
--    does nothing the second time. Call it once after migrating:
--        select backfill_post_existing();
-- ------------------------------------------------------------
create or replace function backfill_post_existing()
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  r record;
  debtor_acct uuid;
  creditor_acct uuid;
  v_id uuid;
  n_inv integer := 0;
  n_bill integer := 0;
begin
  if uid is null then raise exception 'Not authenticated'; end if;

  for r in select * from invoices
            where user_id = uid and voucher_id is null and status <> 'cancelled'
  loop
    debtor_acct := null;
    if r.party_id is not null then
      select account_id into debtor_acct from parties where id = r.party_id and user_id = uid;
    end if;
    if debtor_acct is null then debtor_acct := resolve_system_account('ar_control'); end if;

    v_id := post_voucher('sales', r.fiscal_year, r.invoice_date,
      'Sales Invoice #' || r.invoice_number,
      jsonb_build_array(
        jsonb_build_object('account_id', debtor_acct, 'debit', r.total, 'credit', 0, 'description', r.party_name),
        jsonb_build_object('account_id', resolve_system_account('sales'), 'debit', 0, 'credit', r.subtotal, 'description', 'Sales'),
        jsonb_build_object('account_id', resolve_system_account('vat_payable'), 'debit', 0, 'credit', r.vat_amount, 'description', 'Output VAT 13%')
      ));
    update invoices set voucher_id = v_id where id = r.id;
    n_inv := n_inv + 1;
  end loop;

  for r in select * from purchase_bills
            where user_id = uid and voucher_id is null and status <> 'cancelled'
  loop
    creditor_acct := null;
    if r.vendor_id is not null then
      select account_id into creditor_acct from parties where id = r.vendor_id and user_id = uid;
    end if;
    if creditor_acct is null then creditor_acct := resolve_system_account('ap_control'); end if;

    v_id := post_voucher('purchase', r.fiscal_year, r.bill_date,
      'Purchase Bill #' || r.bill_number,
      jsonb_build_array(
        jsonb_build_object('account_id', resolve_system_account('purchase'), 'debit', r.subtotal, 'credit', 0, 'description', 'Purchase'),
        jsonb_build_object('account_id', resolve_system_account('vat_receivable'), 'debit', r.vat_amount, 'credit', 0, 'description', 'Input VAT 13%'),
        jsonb_build_object('account_id', creditor_acct, 'debit', 0, 'credit', r.total, 'description', r.vendor_name)
      ));
    update purchase_bills set voucher_id = v_id where id = r.id;
    n_bill := n_bill + 1;
  end loop;

  return format('Backfilled %s invoice(s) and %s bill(s).', n_inv, n_bill);
end;
$$;
grant execute on function backfill_post_existing() to authenticated;


-- ------------------------------------------------------------
-- 10. Update the seed so NEW users get system_code stamped and the
--     two control accounts from day one.
-- ------------------------------------------------------------
create or replace function seed_default_accounts()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  if exists (select 1 from accounts where user_id = uid) then return; end if;

  insert into accounts (user_id, name, account_type, group_name, opening_balance_type, system_code) values
    (uid, 'Cash in Hand',              'asset',     'Cash-in-Hand',     'debit',  'cash'),
    (uid, 'Bank Account',              'asset',     'Bank Accounts',    'debit',  'bank'),
    (uid, 'Sales Account',             'income',    'Direct Income',    'credit', 'sales'),
    (uid, 'Purchase Account',          'expense',   'Direct Expense',   'debit',  'purchase'),
    (uid, 'VAT Payable',               'liability', 'Duties & Taxes',   'credit', 'vat_payable'),
    (uid, 'VAT Receivable',            'asset',     'Duties & Taxes',   'debit',  'vat_receivable'),
    (uid, 'Sundry Debtors (Control)',  'asset',     'Sundry Debtors',   'debit',  'ar_control'),
    (uid, 'Sundry Creditors (Control)','liability', 'Sundry Creditors', 'credit', 'ap_control'),
    (uid, 'Capital Account',           'equity',    'Capital',          'credit', null),
    (uid, 'Drawings',                  'equity',    'Capital',          'debit',  null),
    (uid, 'Salary Expense',            'expense',   'Indirect Expense', 'debit',  null),
    (uid, 'Rent Expense',              'expense',   'Indirect Expense', 'debit',  null),
    (uid, 'Discount Allowed',          'expense',   'Indirect Expense', 'debit',  null),
    (uid, 'Discount Received',         'income',    'Indirect Income',  'credit', null);
end;
$$;
grant execute on function seed_default_accounts() to authenticated;

-- ============================================================
-- After running everything above, run this once:
--   select backfill_post_existing();
-- ============================================================
