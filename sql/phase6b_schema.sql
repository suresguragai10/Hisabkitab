-- ============================================================
-- HisabKitab — Phase 6b: Accounting foundation
-- Run this ONCE in Supabase Dashboard → SQL Editor → New query.
-- Safe to re-run: every statement uses IF NOT EXISTS / OR REPLACE.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Chart of Accounts
-- Every ledger account a business needs — including customers
-- and vendors, which are just accounts with is_party_account=true.
-- ------------------------------------------------------------
create table if not exists accounts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  name text not null,
  account_type text not null check (account_type in ('asset','liability','equity','income','expense')),
  group_name text not null default 'General',
  is_party_account boolean not null default false,
  opening_balance numeric(14,2) not null default 0,
  opening_balance_type text not null default 'debit' check (opening_balance_type in ('debit','credit')),
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

-- ------------------------------------------------------------
-- 2. Parties — extra contact/tax info layered on a party account
-- ------------------------------------------------------------
create table if not exists parties (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  account_id uuid not null references accounts(id) on delete cascade,
  party_type text not null check (party_type in ('customer','vendor','both')),
  phone text,
  email text,
  address text,
  pan_vat_number text,
  created_at timestamptz not null default now()
);

-- ------------------------------------------------------------
-- 3. Vouchers — the header of every double-entry transaction
-- ------------------------------------------------------------
create table if not exists vouchers (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  voucher_type text not null check (voucher_type in ('journal','payment','receipt','contra','sales','purchase')),
  voucher_number integer not null,
  fiscal_year text not null,
  voucher_date date not null,
  narration text,
  is_void boolean not null default false,
  void_reason text,
  voided_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- ------------------------------------------------------------
-- 4. Voucher lines — the debit/credit legs (must balance)
-- ------------------------------------------------------------
create table if not exists voucher_lines (
  id uuid primary key default gen_random_uuid(),
  voucher_id uuid not null references vouchers(id) on delete cascade,
  account_id uuid not null references accounts(id),
  debit numeric(14,2) not null default 0,
  credit numeric(14,2) not null default 0,
  description text
);

-- ------------------------------------------------------------
-- Indexes
-- ------------------------------------------------------------
create index if not exists idx_accounts_user on accounts(user_id);
create index if not exists idx_parties_user on parties(user_id);
create index if not exists idx_vouchers_user on vouchers(user_id);
create index if not exists idx_voucher_lines_voucher on voucher_lines(voucher_id);
create index if not exists idx_voucher_lines_account on voucher_lines(account_id);

-- ------------------------------------------------------------
-- Row Level Security — every user only ever sees their own books
-- ------------------------------------------------------------
alter table accounts enable row level security;
alter table parties enable row level security;
alter table vouchers enable row level security;
alter table voucher_lines enable row level security;

drop policy if exists "own accounts" on accounts;
create policy "own accounts" on accounts for all
  using (auth.uid() = user_id) with check (auth.uid() = user_id);

drop policy if exists "own parties" on parties;
create policy "own parties" on parties for all
  using (auth.uid() = user_id) with check (auth.uid() = user_id);

drop policy if exists "own vouchers" on vouchers;
create policy "own vouchers" on vouchers for all
  using (auth.uid() = user_id) with check (auth.uid() = user_id);

drop policy if exists "own voucher lines" on voucher_lines;
create policy "own voucher lines" on voucher_lines for all
  using (exists (select 1 from vouchers v where v.id = voucher_lines.voucher_id and v.user_id = auth.uid()))
  with check (exists (select 1 from vouchers v where v.id = voucher_lines.voucher_id and v.user_id = auth.uid()));

-- ------------------------------------------------------------
-- Function: seed a sensible default chart of accounts for a
-- brand-new user. Called once from the app after first login.
--
-- Uses auth.uid() rather than a client-supplied id — a signed-in
-- user can only ever seed/query their own books, never someone
-- else's, even if the client-side call were tampered with.
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
  if uid is null then
    raise exception 'Not authenticated';
  end if;

  if exists (select 1 from accounts where user_id = uid) then
    return; -- already seeded, do nothing
  end if;

  insert into accounts (user_id, name, account_type, group_name, opening_balance_type) values
    (uid, 'Cash in Hand',       'asset',     'Cash-in-Hand',    'debit'),
    (uid, 'Bank Account',       'asset',     'Bank Accounts',   'debit'),
    (uid, 'Sales Account',      'income',    'Direct Income',   'credit'),
    (uid, 'Purchase Account',   'expense',   'Direct Expense',  'debit'),
    (uid, 'VAT Payable',        'liability', 'Duties & Taxes',  'credit'),
    (uid, 'VAT Receivable',     'asset',     'Duties & Taxes',  'debit'),
    (uid, 'Capital Account',    'equity',    'Capital',         'credit'),
    (uid, 'Drawings',           'equity',    'Capital',         'debit'),
    (uid, 'Salary Expense',     'expense',   'Indirect Expense','debit'),
    (uid, 'Rent Expense',       'expense',   'Indirect Expense','debit'),
    (uid, 'Discount Allowed',   'expense',   'Indirect Expense','debit'),
    (uid, 'Discount Received',  'income',    'Indirect Income', 'credit');
end;
$$;

grant execute on function seed_default_accounts() to authenticated;

-- ------------------------------------------------------------
-- Function: next voucher number for a given type + fiscal year
-- (keeps numbering sequential per type, per Nepali fiscal year,
-- as expected by standard invoice/voucher numbering practice).
-- Scoped to auth.uid() for the same reason as above.
-- ------------------------------------------------------------
create or replace function next_voucher_number(p_voucher_type text, p_fiscal_year text)
returns integer
language sql
security definer
set search_path = public
as $$
  select coalesce(max(voucher_number), 0) + 1
  from vouchers
  where user_id = auth.uid() and voucher_type = p_voucher_type and fiscal_year = p_fiscal_year;
$$;

grant execute on function next_voucher_number(text, text) to authenticated;
