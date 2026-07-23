-- ============================================================
-- HisabKitab P0.7 — Server-enforced fiscal period locking
-- Apply after phaseP0_6_trustworthy_reports.sql, and only after
-- phaseP0_7_period_locks_preflight.sql returns zero blocking rows.
--
-- What this adds:
--   * a fiscal_periods table an owner can generate and lock/unlock
--     (the Settings screen already calls the three RPCs below)
--   * a permanent lock/unlock history (who, when, reason, before/after)
--   * a database trigger on every ledger table that owns a
--     transaction date — insert, update AND delete are checked,
--     so the block cannot be skipped by calling a different
--     function, or by writing to the table directly
--   * direct client writes to those ledger tables are revoked,
--     mirroring the protection already applied to
--     document_payments/payment_allocations and
--     inventory_items/inventory_movements in earlier stages
--
-- Nothing here changes any existing balance, report, or row.
-- No period is locked by this migration — every business starts
-- with zero fiscal_periods rows until an owner clicks "Generate".
-- ============================================================

create extension if not exists btree_gist;

-- ------------------------------------------------------------
-- 1. Fiscal periods
-- ------------------------------------------------------------
create table if not exists fiscal_periods (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  fiscal_year text not null,
  period_label text not null,
  from_date date not null,
  to_date date not null,
  is_locked boolean not null default false,
  locked_at timestamptz,
  locked_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  constraint fiscal_periods_date_order check (from_date <= to_date)
);

-- A business can never have two periods whose date ranges overlap
-- (a duplicate period is just a 100%-overlapping range, so this
-- single rule also blocks duplicates). Enforced by the database
-- itself, not by application code.
alter table fiscal_periods drop constraint if exists fiscal_periods_no_overlap;
alter table fiscal_periods add constraint fiscal_periods_no_overlap
  exclude using gist (
    user_id with =,
    daterange(from_date, to_date, '[]') with &&
  );

create index if not exists idx_fiscal_periods_user on fiscal_periods(user_id);

alter table fiscal_periods enable row level security;

drop policy if exists "own fiscal periods" on fiscal_periods;
create policy "own fiscal periods" on fiscal_periods for select
  using (auth.uid() = user_id);

grant select on fiscal_periods to authenticated;
revoke insert, update, delete on fiscal_periods from authenticated;

-- ------------------------------------------------------------
-- 2. Lock/unlock history — who, when, reason, before -> after.
--    Only ever written by set_period_lock() below, never by a
--    direct client insert.
-- ------------------------------------------------------------
create table if not exists fiscal_period_lock_history (
  id bigserial primary key,
  period_id uuid not null references fiscal_periods(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  changed_by uuid not null references auth.users(id),
  action text not null check (action in ('lock','unlock')),
  previous_status boolean not null,
  new_status boolean not null,
  reason text,
  changed_at timestamptz not null default now()
);

create index if not exists idx_fiscal_period_lock_history_period on fiscal_period_lock_history(period_id);
create index if not exists idx_fiscal_period_lock_history_user on fiscal_period_lock_history(user_id);

alter table fiscal_period_lock_history enable row level security;

drop policy if exists "own fiscal period lock history" on fiscal_period_lock_history;
create policy "own fiscal period lock history" on fiscal_period_lock_history for select
  using (auth.uid() = user_id);

grant select on fiscal_period_lock_history to authenticated;
revoke insert, update, delete on fiscal_period_lock_history from authenticated;

-- ------------------------------------------------------------
-- 3. Internal guard. Not grantable to clients — called only from
--    the trigger functions below, which run with this function's
--    owner privileges.
-- ------------------------------------------------------------
create or replace function assert_period_not_locked(p_user_id uuid, p_check_date date)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_period record;
begin
  if p_user_id is null or p_check_date is null then
    return;
  end if;

  select id, period_label, from_date, to_date
    into v_period
    from fiscal_periods
   where user_id = p_user_id
     and is_locked = true
     and daterange(from_date, to_date, '[]') @> p_check_date
   limit 1;

  if found then
    raise exception
      'This date (%) falls in a locked accounting period: % (% to %). Ask the business owner to unlock this period in Settings before making this change.',
      p_check_date, v_period.period_label, v_period.from_date, v_period.to_date;
  end if;
end;
$$;

revoke all on function assert_period_not_locked(uuid, date) from public, authenticated;

-- ------------------------------------------------------------
-- 4. Trigger functions — one per ledger table. Each fires on
--    insert, update AND delete, and is attached directly to the
--    table itself, so it runs no matter which function (existing
--    or future) tries to write, and no matter whether the write
--    came through a function at all.
--
--    Rule applied on update: the OLD date is checked (you cannot
--    touch a row already sitting in a locked period) and the NEW
--    date is checked (you cannot move a row into a locked period).
-- ------------------------------------------------------------

-- vouchers ------------------------------------------------------
create or replace function trg_check_period_lock_vouchers()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'DELETE' then
    perform assert_period_not_locked(old.user_id, old.voucher_date);
    return old;
  elsif tg_op = 'UPDATE' then
    perform assert_period_not_locked(old.user_id, old.voucher_date);
    perform assert_period_not_locked(new.user_id, new.voucher_date);
    return new;
  else
    perform assert_period_not_locked(new.user_id, new.voucher_date);
    return new;
  end if;
end;
$$;

drop trigger if exists trg_period_lock_vouchers on vouchers;
create trigger trg_period_lock_vouchers
  before insert or update or delete on vouchers
  for each row execute function trg_check_period_lock_vouchers();

-- voucher_lines (date lives on the parent voucher) ---------------
create or replace function trg_check_period_lock_voucher_lines()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid; v_date date;
begin
  if tg_op in ('DELETE','UPDATE') then
    select user_id, voucher_date into v_user_id, v_date from vouchers where id = old.voucher_id;
    perform assert_period_not_locked(v_user_id, v_date);
  end if;
  if tg_op in ('INSERT','UPDATE') then
    select user_id, voucher_date into v_user_id, v_date from vouchers where id = new.voucher_id;
    perform assert_period_not_locked(v_user_id, v_date);
  end if;
  return coalesce(new, old);
end;
$$;

drop trigger if exists trg_period_lock_voucher_lines on voucher_lines;
create trigger trg_period_lock_voucher_lines
  before insert or update or delete on voucher_lines
  for each row execute function trg_check_period_lock_voucher_lines();

-- invoices --------------------------------------------------------
-- A locked invoice's own accounting details — amounts, accounts,
-- parties, tax, line items, its own date, cancellation, everything —
-- must never change. The one legitimate exception is a LATER payment
-- being applied against it (dated in its own open period, and
-- already checked independently by the document_payments /
-- payment_allocations triggers): refresh_document_payment_status()
-- needs to update this invoice's own running payment summary
-- (amount_paid, outstanding_amount, status, payment_status_updated_at)
-- even though the invoice's original date is locked. This is a
-- strict, explicit allow-list of exactly those four system-maintained
-- columns — not "allow the update if the date happens to be
-- unchanged" — so any other column changing (including the date
-- itself) still falls straight back to the normal lock check.
create or replace function trg_check_period_lock_invoices()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_only_payment_summary_changed boolean;
begin
  if tg_op = 'DELETE' then
    perform assert_period_not_locked(old.user_id, old.invoice_date);
    return old;
  elsif tg_op = 'UPDATE' then
    v_only_payment_summary_changed :=
      (to_jsonb(old) - array['amount_paid','outstanding_amount','status','payment_status_updated_at'])
      =
      (to_jsonb(new) - array['amount_paid','outstanding_amount','status','payment_status_updated_at']);

    if not v_only_payment_summary_changed then
      perform assert_period_not_locked(old.user_id, old.invoice_date);
      perform assert_period_not_locked(new.user_id, new.invoice_date);
    end if;
    return new;
  else
    perform assert_period_not_locked(new.user_id, new.invoice_date);
    return new;
  end if;
end;
$$;

drop trigger if exists trg_period_lock_invoices on invoices;
create trigger trg_period_lock_invoices
  before insert or update or delete on invoices
  for each row execute function trg_check_period_lock_invoices();

-- invoice_lines -----------------------------------------------------
create or replace function trg_check_period_lock_invoice_lines()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid; v_date date;
begin
  if tg_op in ('DELETE','UPDATE') then
    select user_id, invoice_date into v_user_id, v_date from invoices where id = old.invoice_id;
    perform assert_period_not_locked(v_user_id, v_date);
  end if;
  if tg_op in ('INSERT','UPDATE') then
    select user_id, invoice_date into v_user_id, v_date from invoices where id = new.invoice_id;
    perform assert_period_not_locked(v_user_id, v_date);
  end if;
  return coalesce(new, old);
end;
$$;

drop trigger if exists trg_period_lock_invoice_lines on invoice_lines;
create trigger trg_period_lock_invoice_lines
  before insert or update or delete on invoice_lines
  for each row execute function trg_check_period_lock_invoice_lines();

-- purchase_bills ------------------------------------------------------
-- Same reasoning as trg_check_period_lock_invoices() above: a locked
-- bill's own accounting details must never change, except the four
-- system-maintained payment-summary columns that
-- refresh_document_payment_status() updates when a later payment is
-- recorded against it. Strict allow-list, not a date-unchanged rule.
create or replace function trg_check_period_lock_purchase_bills()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_only_payment_summary_changed boolean;
begin
  if tg_op = 'DELETE' then
    perform assert_period_not_locked(old.user_id, old.bill_date);
    return old;
  elsif tg_op = 'UPDATE' then
    v_only_payment_summary_changed :=
      (to_jsonb(old) - array['amount_paid','outstanding_amount','status','payment_status_updated_at'])
      =
      (to_jsonb(new) - array['amount_paid','outstanding_amount','status','payment_status_updated_at']);

    if not v_only_payment_summary_changed then
      perform assert_period_not_locked(old.user_id, old.bill_date);
      perform assert_period_not_locked(new.user_id, new.bill_date);
    end if;
    return new;
  else
    perform assert_period_not_locked(new.user_id, new.bill_date);
    return new;
  end if;
end;
$$;

drop trigger if exists trg_period_lock_purchase_bills on purchase_bills;
create trigger trg_period_lock_purchase_bills
  before insert or update or delete on purchase_bills
  for each row execute function trg_check_period_lock_purchase_bills();

-- purchase_bill_lines -----------------------------------------------
create or replace function trg_check_period_lock_purchase_bill_lines()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid; v_date date;
begin
  if tg_op in ('DELETE','UPDATE') then
    select user_id, bill_date into v_user_id, v_date from purchase_bills where id = old.bill_id;
    perform assert_period_not_locked(v_user_id, v_date);
  end if;
  if tg_op in ('INSERT','UPDATE') then
    select user_id, bill_date into v_user_id, v_date from purchase_bills where id = new.bill_id;
    perform assert_period_not_locked(v_user_id, v_date);
  end if;
  return coalesce(new, old);
end;
$$;

drop trigger if exists trg_period_lock_purchase_bill_lines on purchase_bill_lines;
create trigger trg_period_lock_purchase_bill_lines
  before insert or update or delete on purchase_bill_lines
  for each row execute function trg_check_period_lock_purchase_bill_lines();

-- credit_notes --------------------------------------------------------
create or replace function trg_check_period_lock_credit_notes()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'DELETE' then
    perform assert_period_not_locked(old.user_id, old.cn_date);
    return old;
  elsif tg_op = 'UPDATE' then
    perform assert_period_not_locked(old.user_id, old.cn_date);
    perform assert_period_not_locked(new.user_id, new.cn_date);
    return new;
  else
    perform assert_period_not_locked(new.user_id, new.cn_date);
    return new;
  end if;
end;
$$;

drop trigger if exists trg_period_lock_credit_notes on credit_notes;
create trigger trg_period_lock_credit_notes
  before insert or update or delete on credit_notes
  for each row execute function trg_check_period_lock_credit_notes();

-- credit_note_lines -----------------------------------------------
create or replace function trg_check_period_lock_credit_note_lines()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid; v_date date;
begin
  if tg_op in ('DELETE','UPDATE') then
    select user_id, cn_date into v_user_id, v_date from credit_notes where id = old.credit_note_id;
    perform assert_period_not_locked(v_user_id, v_date);
  end if;
  if tg_op in ('INSERT','UPDATE') then
    select user_id, cn_date into v_user_id, v_date from credit_notes where id = new.credit_note_id;
    perform assert_period_not_locked(v_user_id, v_date);
  end if;
  return coalesce(new, old);
end;
$$;

drop trigger if exists trg_period_lock_credit_note_lines on credit_note_lines;
create trigger trg_period_lock_credit_note_lines
  before insert or update or delete on credit_note_lines
  for each row execute function trg_check_period_lock_credit_note_lines();

-- debit_notes ---------------------------------------------------------
create or replace function trg_check_period_lock_debit_notes()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'DELETE' then
    perform assert_period_not_locked(old.user_id, old.dn_date);
    return old;
  elsif tg_op = 'UPDATE' then
    perform assert_period_not_locked(old.user_id, old.dn_date);
    perform assert_period_not_locked(new.user_id, new.dn_date);
    return new;
  else
    perform assert_period_not_locked(new.user_id, new.dn_date);
    return new;
  end if;
end;
$$;

drop trigger if exists trg_period_lock_debit_notes on debit_notes;
create trigger trg_period_lock_debit_notes
  before insert or update or delete on debit_notes
  for each row execute function trg_check_period_lock_debit_notes();

-- debit_note_lines -----------------------------------------------
create or replace function trg_check_period_lock_debit_note_lines()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid; v_date date;
begin
  if tg_op in ('DELETE','UPDATE') then
    select user_id, dn_date into v_user_id, v_date from debit_notes where id = old.debit_note_id;
    perform assert_period_not_locked(v_user_id, v_date);
  end if;
  if tg_op in ('INSERT','UPDATE') then
    select user_id, dn_date into v_user_id, v_date from debit_notes where id = new.debit_note_id;
    perform assert_period_not_locked(v_user_id, v_date);
  end if;
  return coalesce(new, old);
end;
$$;

drop trigger if exists trg_period_lock_debit_note_lines on debit_note_lines;
create trigger trg_period_lock_debit_note_lines
  before insert or update or delete on debit_note_lines
  for each row execute function trg_check_period_lock_debit_note_lines();

-- document_payments -----------------------------------------------
create or replace function trg_check_period_lock_document_payments()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'DELETE' then
    perform assert_period_not_locked(old.user_id, old.payment_date);
    return old;
  elsif tg_op = 'UPDATE' then
    perform assert_period_not_locked(old.user_id, old.payment_date);
    perform assert_period_not_locked(new.user_id, new.payment_date);
    return new;
  else
    perform assert_period_not_locked(new.user_id, new.payment_date);
    return new;
  end if;
end;
$$;

drop trigger if exists trg_period_lock_document_payments on document_payments;
create trigger trg_period_lock_document_payments
  before insert or update or delete on document_payments
  for each row execute function trg_check_period_lock_document_payments();

-- payment_allocations (date lives on the parent payment) -----------
create or replace function trg_check_period_lock_payment_allocations()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid; v_date date;
begin
  if tg_op in ('DELETE','UPDATE') then
    select user_id, payment_date into v_user_id, v_date from document_payments where id = old.payment_id;
    perform assert_period_not_locked(v_user_id, v_date);
  end if;
  if tg_op in ('INSERT','UPDATE') then
    select user_id, payment_date into v_user_id, v_date from document_payments where id = new.payment_id;
    perform assert_period_not_locked(v_user_id, v_date);
  end if;
  return coalesce(new, old);
end;
$$;

drop trigger if exists trg_period_lock_payment_allocations on payment_allocations;
create trigger trg_period_lock_payment_allocations
  before insert or update or delete on payment_allocations
  for each row execute function trg_check_period_lock_payment_allocations();

-- inventory_movements -----------------------------------------------
create or replace function trg_check_period_lock_inventory_movements()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'DELETE' then
    perform assert_period_not_locked(old.user_id, old.movement_date);
    return old;
  elsif tg_op = 'UPDATE' then
    perform assert_period_not_locked(old.user_id, old.movement_date);
    perform assert_period_not_locked(new.user_id, new.movement_date);
    return new;
  else
    perform assert_period_not_locked(new.user_id, new.movement_date);
    return new;
  end if;
end;
$$;

drop trigger if exists trg_period_lock_inventory_movements on inventory_movements;
create trigger trg_period_lock_inventory_movements
  before insert or update or delete on inventory_movements
  for each row execute function trg_check_period_lock_inventory_movements();

-- ------------------------------------------------------------
-- 5. Close the direct-write gap: from here on, the only way to
--    write to these ledger tables is through an approved
--    security-definer function (matching the protection already
--    applied to document_payments/payment_allocations and
--    inventory_items/inventory_movements in earlier stages).
--    Reading them directly is unaffected.
-- ------------------------------------------------------------
grant select on vouchers, voucher_lines to authenticated;
revoke insert, update, delete on vouchers, voucher_lines from authenticated;

grant select on invoices, invoice_lines to authenticated;
revoke insert, update, delete on invoices, invoice_lines from authenticated;

grant select on purchase_bills, purchase_bill_lines to authenticated;
revoke insert, update, delete on purchase_bills, purchase_bill_lines from authenticated;

grant select on credit_notes, credit_note_lines to authenticated;
revoke insert, update, delete on credit_notes, credit_note_lines from authenticated;

grant select on debit_notes, debit_note_lines to authenticated;
revoke insert, update, delete on debit_notes, debit_note_lines from authenticated;

-- ------------------------------------------------------------
-- 6. The three functions the Settings screen is already calling.
-- ------------------------------------------------------------
create or replace function list_fiscal_periods(p_fiscal_year text)
returns table (
  id uuid,
  fiscal_year text,
  period_label text,
  from_date date,
  to_date date,
  is_locked boolean,
  locked_at timestamptz
)
language sql
security definer
set search_path = public
as $$
  select id, fiscal_year, period_label, from_date, to_date, is_locked, locked_at
    from fiscal_periods
   where user_id = auth.uid()
     and (p_fiscal_year is null or fiscal_year = p_fiscal_year)
   order by from_date;
$$;

revoke all on function list_fiscal_periods(text) from public;
grant execute on function list_fiscal_periods(text) to authenticated;

create or replace function create_fiscal_periods(p_fiscal_year text, p_periods jsonb)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  v_inserted integer := 0;
begin
  if uid is null then
    raise exception 'Not authenticated';
  end if;

  if p_fiscal_year is null or btrim(p_fiscal_year) = '' then
    raise exception 'Fiscal year is required';
  end if;

  if p_periods is null or jsonb_typeof(p_periods) <> 'array' or jsonb_array_length(p_periods) = 0 then
    raise exception 'At least one period is required';
  end if;

  if exists (select 1 from fiscal_periods where user_id = uid and fiscal_year = p_fiscal_year) then
    raise exception 'Periods already exist for fiscal year %.', p_fiscal_year;
  end if;

  begin
    insert into fiscal_periods (user_id, fiscal_year, period_label, from_date, to_date)
    select uid, p_fiscal_year, elem->>'label', (elem->>'from_date')::date, (elem->>'to_date')::date
      from jsonb_array_elements(p_periods) elem;
  exception when exclusion_violation then
    raise exception 'One or more of these periods overlaps a period that already exists for this business. No periods were created.';
  end;

  get diagnostics v_inserted = row_count;
  return v_inserted;
end;
$$;

revoke all on function create_fiscal_periods(text, jsonb) from public;
grant execute on function create_fiscal_periods(text, jsonb) to authenticated;

create or replace function set_period_lock(p_period_id uuid, p_locked boolean, p_reason text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  v_period record;
  v_reason text;
begin
  if uid is null then
    raise exception 'Not authenticated';
  end if;

  select * into v_period from fiscal_periods where id = p_period_id and user_id = uid;
  if not found then
    raise exception 'Period not found, or does not belong to this business.';
  end if;

  if v_period.is_locked = p_locked then
    raise exception 'Period "%" is already %.', v_period.period_label, (case when p_locked then 'locked' else 'open' end);
  end if;

  v_reason := nullif(btrim(coalesce(p_reason, '')), '');

  if p_locked = false and v_reason is null then
    raise exception 'A reason is required to reopen a locked period.';
  end if;

  update fiscal_periods
     set is_locked = p_locked,
         locked_at = case when p_locked then now() else null end,
         locked_by = case when p_locked then uid else null end
   where id = p_period_id;

  insert into fiscal_period_lock_history
    (period_id, user_id, changed_by, action, previous_status, new_status, reason)
  values
    (p_period_id, uid, uid, (case when p_locked then 'lock' else 'unlock' end),
     v_period.is_locked, p_locked, v_reason);
end;
$$;

revoke all on function set_period_lock(uuid, boolean, text) from public;
grant execute on function set_period_lock(uuid, boolean, text) to authenticated;
