-- ============================================================
-- HisabKitab Stage 2 - payment allocations and partial payments
-- Apply after:
--   1. phaseP0_posting.sql
--   2. phaseP0_1_manual_vouchers.sql
--
-- This migration:
--   * stores each receipt/payment separately
--   * allocates payments to invoices or purchase bills
--   * derives paid/outstanding amounts from active allocations
--   * supports open, partial, paid, overdue, cancelled, credited
--   * prevents over-allocation under concurrent requests
--   * provides payment history and controlled allocation reversal
-- ============================================================

begin;

-- ------------------------------------------------------------
-- 1. Payment summary fields on documents.
--    These are maintained only by trusted database functions.
-- ------------------------------------------------------------
alter table invoices
  add column if not exists amount_paid numeric(14,2) not null default 0,
  add column if not exists outstanding_amount numeric(14,2) not null default 0,
  add column if not exists payment_status_updated_at timestamptz;

alter table purchase_bills
  add column if not exists amount_paid numeric(14,2) not null default 0,
  add column if not exists outstanding_amount numeric(14,2) not null default 0,
  add column if not exists payment_status_updated_at timestamptz;

-- Existing checks were created inline in earlier migrations.
alter table invoices drop constraint if exists invoices_status_check;
alter table purchase_bills drop constraint if exists purchase_bills_status_check;

-- Normalize earlier status names to the Stage 2 vocabulary.
update invoices set status = 'open' where status = 'sent';
update purchase_bills set status = 'open' where status = 'unpaid';

-- Keep older clients/functions compatible while storing only Stage 2 names.
create or replace function normalize_stage2_document_status()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if tg_table_name = 'invoices' and new.status = 'sent' then
    new.status := 'open';
  elsif tg_table_name = 'purchase_bills' and new.status = 'unpaid' then
    new.status := 'open';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_normalize_invoice_stage2_status on invoices;
create trigger trg_normalize_invoice_stage2_status
before insert or update of status on invoices
for each row execute function normalize_stage2_document_status();

drop trigger if exists trg_normalize_bill_stage2_status on purchase_bills;
create trigger trg_normalize_bill_stage2_status
before insert or update of status on purchase_bills
for each row execute function normalize_stage2_document_status();

alter table invoices
  add constraint invoices_status_check
  check (status in ('draft','open','partial','paid','overdue','cancelled','credited'));

alter table purchase_bills
  add constraint purchase_bills_status_check
  check (status in ('draft','open','partial','paid','overdue','cancelled','credited'));

-- Paid/outstanding columns are derived. Block direct browser-role edits;
-- security-definer payment functions run as their owner and may update them.
create or replace function protect_document_payment_summary()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if current_user in ('anon', 'authenticated') and (
       new.amount_paid is distinct from old.amount_paid
    or new.outstanding_amount is distinct from old.outstanding_amount
    or new.payment_status_updated_at is distinct from old.payment_status_updated_at
    or (new.status is distinct from old.status and (
         new.status in ('partial', 'paid', 'overdue')
      or old.status in ('partial', 'paid', 'overdue')
    ))
  ) then
    raise exception 'Payment summaries and payment-derived statuses are database-managed.';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_protect_invoice_payment_summary on invoices;
create trigger trg_protect_invoice_payment_summary
before update on invoices
for each row execute function protect_document_payment_summary();

drop trigger if exists trg_protect_bill_payment_summary on purchase_bills;
create trigger trg_protect_bill_payment_summary
before update on purchase_bills
for each row execute function protect_document_payment_summary();

-- ------------------------------------------------------------
-- 2. Payment and allocation tables.
-- ------------------------------------------------------------
create table if not exists document_payments (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  payment_kind text not null check (payment_kind in ('receipt','payment')),
  payment_date date not null,
  deposit_code text not null check (deposit_code in ('cash','bank')),
  amount numeric(14,2) not null check (amount > 0),
  voucher_id uuid references vouchers(id),
  reference text,
  notes text,
  status text not null default 'posted'
    check (status in ('posted','partially_reversed','reversed')),
  is_legacy boolean not null default false,
  created_at timestamptz not null default now()
);

create table if not exists payment_allocations (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  payment_id uuid not null references document_payments(id) on delete restrict,
  invoice_id uuid references invoices(id) on delete restrict,
  bill_id uuid references purchase_bills(id) on delete restrict,
  allocated_amount numeric(14,2) not null check (allocated_amount > 0),
  reversed_at timestamptz,
  reversal_reason text,
  reversal_voucher_id uuid references vouchers(id),
  created_at timestamptz not null default now(),
  constraint payment_allocations_one_document_check check (
    (invoice_id is not null and bill_id is null)
    or (invoice_id is null and bill_id is not null)
  )
);

create index if not exists idx_document_payments_user_date
  on document_payments(user_id, payment_date desc);
create index if not exists idx_payment_allocations_payment
  on payment_allocations(payment_id);
create index if not exists idx_payment_allocations_invoice_active
  on payment_allocations(invoice_id) where reversed_at is null;
create index if not exists idx_payment_allocations_bill_active
  on payment_allocations(bill_id) where reversed_at is null;

alter table document_payments enable row level security;
alter table payment_allocations enable row level security;

-- Enforce ownership and prevent allocations from exceeding their payment.
create or replace function validate_payment_allocation()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_payment_user uuid;
  v_payment_amount numeric(14,2);
  v_document_user uuid;
  v_document_total numeric(14,2);
  v_other_allocated numeric(14,2);
begin
  select user_id, amount
    into v_payment_user, v_payment_amount
    from document_payments
   where id = new.payment_id;
  if not found then raise exception 'Payment not found.'; end if;
  if new.user_id <> v_payment_user then
    raise exception 'Allocation owner does not match payment owner.';
  end if;

  if new.invoice_id is not null then
    select user_id, total into v_document_user, v_document_total
      from invoices where id = new.invoice_id;
  else
    select user_id, total into v_document_user, v_document_total
      from purchase_bills where id = new.bill_id;
  end if;
  if not found then raise exception 'Allocated document not found.'; end if;
  if new.user_id <> v_document_user then
    raise exception 'Allocation owner does not match document owner.';
  end if;
  if new.allocated_amount > v_document_total + 0.005 then
    raise exception 'Allocation exceeds document total.';
  end if;

  select coalesce(sum(allocated_amount), 0)
    into v_other_allocated
    from payment_allocations
   where payment_id = new.payment_id
     and reversed_at is null
     and id <> coalesce(new.id, gen_random_uuid());

  if v_other_allocated + new.allocated_amount > v_payment_amount + 0.005 then
    raise exception 'Allocations exceed the payment amount.';
  end if;

  return new;
end;
$$;

drop trigger if exists trg_validate_payment_allocation on payment_allocations;
create trigger trg_validate_payment_allocation
before insert or update of payment_id, invoice_id, bill_id, allocated_amount
on payment_allocations
for each row execute function validate_payment_allocation();

drop policy if exists "own document payments" on document_payments;
create policy "own document payments" on document_payments for select
  using (auth.uid() = user_id);

drop policy if exists "own payment allocations" on payment_allocations;
create policy "own payment allocations" on payment_allocations for select
  using (auth.uid() = user_id);

-- Clients may read payment history, but all writes must go through RPCs.
grant select on document_payments, payment_allocations to authenticated;
revoke insert, update, delete on document_payments, payment_allocations from authenticated;

-- ------------------------------------------------------------
-- 3. Recompute one document from active allocations.
-- ------------------------------------------------------------
create or replace function refresh_document_payment_status(
  p_doc_type text,
  p_doc_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  v_total numeric(14,2);
  v_paid numeric(14,2);
  v_outstanding numeric(14,2);
  v_due_date date;
  v_current_status text;
  v_new_status text;
begin
  if uid is null then raise exception 'Not authenticated'; end if;

  if p_doc_type = 'invoice' then
    select total, due_date, status
      into v_total, v_due_date, v_current_status
      from invoices
     where id = p_doc_id and user_id = uid
     for update;
    if not found then raise exception 'Invoice not found.'; end if;

    select coalesce(sum(a.allocated_amount), 0)
      into v_paid
      from payment_allocations a
      join document_payments p on p.id = a.payment_id
     where a.user_id = uid
       and a.invoice_id = p_doc_id
       and a.reversed_at is null
       and p.status <> 'reversed';

  elsif p_doc_type = 'bill' then
    select total, due_date, status
      into v_total, v_due_date, v_current_status
      from purchase_bills
     where id = p_doc_id and user_id = uid
     for update;
    if not found then raise exception 'Bill not found.'; end if;

    select coalesce(sum(a.allocated_amount), 0)
      into v_paid
      from payment_allocations a
      join document_payments p on p.id = a.payment_id
     where a.user_id = uid
       and a.bill_id = p_doc_id
       and a.reversed_at is null
       and p.status <> 'reversed';
  else
    raise exception 'Unknown document type: %', p_doc_type;
  end if;

  v_paid := least(round(coalesce(v_paid, 0), 2), round(v_total, 2));
  v_outstanding := greatest(round(v_total - v_paid, 2), 0);

  if v_current_status in ('cancelled', 'credited') then
    v_new_status := v_current_status;
  elsif v_current_status = 'draft' and v_paid <= 0.005 then
    v_new_status := 'draft';
  elsif v_outstanding <= 0.005 then
    v_new_status := 'paid';
  elsif v_due_date is not null and v_due_date < current_date then
    v_new_status := 'overdue';
  elsif v_paid > 0.005 then
    v_new_status := 'partial';
  else
    v_new_status := 'open';
  end if;

  if p_doc_type = 'invoice' then
    update invoices
       set amount_paid = v_paid,
           outstanding_amount = v_outstanding,
           status = v_new_status,
           payment_status_updated_at = now()
     where id = p_doc_id and user_id = uid;
  else
    update purchase_bills
       set amount_paid = v_paid,
           outstanding_amount = v_outstanding,
           status = v_new_status,
           payment_status_updated_at = now()
     where id = p_doc_id and user_id = uid;
  end if;
end;
$$;

revoke all on function refresh_document_payment_status(text, uuid) from public;
grant execute on function refresh_document_payment_status(text, uuid) to authenticated;

-- Refresh all statuses for the signed-in owner. The UI calls this before
-- listing documents so due-date transitions become visible without a cron job.
create or replace function refresh_document_payment_statuses()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  r record;
  v_count integer := 0;
begin
  if uid is null then raise exception 'Not authenticated'; end if;

  for r in select id from invoices where user_id = uid
  loop
    perform refresh_document_payment_status('invoice', r.id);
    v_count := v_count + 1;
  end loop;

  for r in select id from purchase_bills where user_id = uid
  loop
    perform refresh_document_payment_status('bill', r.id);
    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

revoke all on function refresh_document_payment_statuses() from public;
grant execute on function refresh_document_payment_statuses() to authenticated;

-- ------------------------------------------------------------
-- 4. Record one receipt/payment and allocate it atomically.
-- ------------------------------------------------------------
create or replace function record_document_payment(
  p_doc_type text,
  p_doc_id uuid,
  p_amount numeric,
  p_deposit_code text,
  p_date date,
  p_reference text default null,
  p_notes text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  v_amount numeric(14,2) := round(coalesce(p_amount, 0), 2);
  v_deposit_code text := lower(coalesce(p_deposit_code, ''));
  v_cashbank uuid;
  v_party_acct uuid;
  v_fiscal_year text;
  v_voucher_id uuid;
  v_payment_id uuid;
  v_paid numeric(14,2);
  v_outstanding numeric(14,2);
  h record;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  if v_amount <= 0 then raise exception 'Amount must be positive.'; end if;
  if p_date is null then raise exception 'Payment date is required.'; end if;
  if v_deposit_code not in ('cash', 'bank') then
    raise exception 'Payment mode must be cash or bank.';
  end if;

  v_cashbank := resolve_system_account(v_deposit_code);

  if p_doc_type = 'invoice' then
    select * into h
      from invoices
     where id = p_doc_id and user_id = uid
     for update;
    if not found then raise exception 'Invoice not found.'; end if;
    if h.status in ('draft', 'cancelled', 'credited') then
      raise exception 'Payments cannot be recorded against an invoice with status %.', h.status;
    end if;

    select coalesce(sum(a.allocated_amount), 0)
      into v_paid
      from payment_allocations a
      join document_payments p on p.id = a.payment_id
     where a.user_id = uid
       and a.invoice_id = p_doc_id
       and a.reversed_at is null
       and p.status <> 'reversed';

    v_outstanding := greatest(round(h.total - v_paid, 2), 0);
    if v_outstanding <= 0.005 then raise exception 'Invoice is already fully paid.'; end if;
    if v_amount > v_outstanding + 0.005 then
      raise exception 'Amount % exceeds outstanding balance %.', v_amount, v_outstanding;
    end if;

    if h.party_id is not null then
      select account_id into v_party_acct
        from parties
       where id = h.party_id and user_id = uid;
    end if;
    if v_party_acct is null then v_party_acct := resolve_system_account('ar_control'); end if;
    v_fiscal_year := h.fiscal_year;

    v_voucher_id := post_voucher(
      'receipt', v_fiscal_year, p_date,
      'Receipt against Invoice #' || h.invoice_number,
      jsonb_build_array(
        jsonb_build_object('account_id', v_cashbank, 'debit', v_amount, 'credit', 0, 'description', 'Received'),
        jsonb_build_object('account_id', v_party_acct, 'debit', 0, 'credit', v_amount, 'description', h.party_name)
      )
    );

    insert into document_payments (
      user_id, payment_kind, payment_date, deposit_code, amount,
      voucher_id, reference, notes
    ) values (
      uid, 'receipt', p_date, v_deposit_code, v_amount,
      v_voucher_id, nullif(trim(p_reference), ''), nullif(trim(p_notes), '')
    ) returning id into v_payment_id;

    insert into payment_allocations (
      user_id, payment_id, invoice_id, allocated_amount
    ) values (
      uid, v_payment_id, p_doc_id, v_amount
    );

    update invoices
       set settlement_voucher_id = v_voucher_id
     where id = p_doc_id and user_id = uid;

  elsif p_doc_type = 'bill' then
    select * into h
      from purchase_bills
     where id = p_doc_id and user_id = uid
     for update;
    if not found then raise exception 'Bill not found.'; end if;
    if h.status in ('draft', 'cancelled', 'credited') then
      raise exception 'Payments cannot be recorded against a bill with status %.', h.status;
    end if;

    select coalesce(sum(a.allocated_amount), 0)
      into v_paid
      from payment_allocations a
      join document_payments p on p.id = a.payment_id
     where a.user_id = uid
       and a.bill_id = p_doc_id
       and a.reversed_at is null
       and p.status <> 'reversed';

    v_outstanding := greatest(round(h.total - v_paid, 2), 0);
    if v_outstanding <= 0.005 then raise exception 'Bill is already fully paid.'; end if;
    if v_amount > v_outstanding + 0.005 then
      raise exception 'Amount % exceeds outstanding balance %.', v_amount, v_outstanding;
    end if;

    if h.vendor_id is not null then
      select account_id into v_party_acct
        from parties
       where id = h.vendor_id and user_id = uid;
    end if;
    if v_party_acct is null then v_party_acct := resolve_system_account('ap_control'); end if;
    v_fiscal_year := h.fiscal_year;

    v_voucher_id := post_voucher(
      'payment', v_fiscal_year, p_date,
      'Payment against Bill #' || h.bill_number,
      jsonb_build_array(
        jsonb_build_object('account_id', v_party_acct, 'debit', v_amount, 'credit', 0, 'description', h.vendor_name),
        jsonb_build_object('account_id', v_cashbank, 'debit', 0, 'credit', v_amount, 'description', 'Paid')
      )
    );

    insert into document_payments (
      user_id, payment_kind, payment_date, deposit_code, amount,
      voucher_id, reference, notes
    ) values (
      uid, 'payment', p_date, v_deposit_code, v_amount,
      v_voucher_id, nullif(trim(p_reference), ''), nullif(trim(p_notes), '')
    ) returning id into v_payment_id;

    insert into payment_allocations (
      user_id, payment_id, bill_id, allocated_amount
    ) values (
      uid, v_payment_id, p_doc_id, v_amount
    );

    update purchase_bills
       set settlement_voucher_id = v_voucher_id
     where id = p_doc_id and user_id = uid;
  else
    raise exception 'Unknown document type: %', p_doc_type;
  end if;

  perform refresh_document_payment_status(p_doc_type, p_doc_id);

  perform write_audit_log(
    'create', 'document_payments', v_payment_id::text, null,
    jsonb_build_object(
      'document_type', p_doc_type,
      'document_id', p_doc_id,
      'amount', v_amount,
      'deposit_code', v_deposit_code,
      'voucher_id', v_voucher_id
    )
  );

  return v_payment_id;
end;
$$;

revoke all on function record_document_payment(text, uuid, numeric, text, date, text, text) from public;
grant execute on function record_document_payment(text, uuid, numeric, text, date, text, text) to authenticated;

-- Compatibility wrapper for the existing frontend/API name.
create or replace function settle_document(
  p_doc_type text,
  p_doc_id uuid,
  p_amount numeric,
  p_deposit_code text,
  p_date date
)
returns uuid
language sql
security definer
set search_path = public
as $$
  select record_document_payment(
    p_doc_type, p_doc_id, p_amount, p_deposit_code, p_date, null, null
  );
$$;

revoke all on function settle_document(text, uuid, numeric, text, date) from public;
grant execute on function settle_document(text, uuid, numeric, text, date) to authenticated;

-- ------------------------------------------------------------
-- 5. Payment history for one document.
-- ------------------------------------------------------------
create or replace function get_payment_history(
  p_doc_type text,
  p_doc_id uuid
)
returns table (
  id uuid,
  payment_id uuid,
  payment_date date,
  amount numeric,
  deposit_code text,
  payment_kind text,
  payment_status text,
  is_legacy boolean,
  reference text,
  notes text,
  voucher_id uuid,
  reversed_at timestamptz,
  reversal_reason text,
  reversal_voucher_id uuid,
  created_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
begin
  if uid is null then raise exception 'Not authenticated'; end if;

  if p_doc_type = 'invoice' then
    if not exists (select 1 from invoices where id = p_doc_id and user_id = uid) then
      raise exception 'Invoice not found.';
    end if;

    return query
      select a.id, p.id, p.payment_date, a.allocated_amount,
             p.deposit_code, p.payment_kind, p.status, p.is_legacy,
             p.reference, p.notes, p.voucher_id,
             a.reversed_at, a.reversal_reason, a.reversal_voucher_id,
             a.created_at
        from payment_allocations a
        join document_payments p on p.id = a.payment_id
       where a.user_id = uid and a.invoice_id = p_doc_id
       order by p.payment_date desc, a.created_at desc;

  elsif p_doc_type = 'bill' then
    if not exists (select 1 from purchase_bills where id = p_doc_id and user_id = uid) then
      raise exception 'Bill not found.';
    end if;

    return query
      select a.id, p.id, p.payment_date, a.allocated_amount,
             p.deposit_code, p.payment_kind, p.status, p.is_legacy,
             p.reference, p.notes, p.voucher_id,
             a.reversed_at, a.reversal_reason, a.reversal_voucher_id,
             a.created_at
        from payment_allocations a
        join document_payments p on p.id = a.payment_id
       where a.user_id = uid and a.bill_id = p_doc_id
       order by p.payment_date desc, a.created_at desc;
  else
    raise exception 'Unknown document type: %', p_doc_type;
  end if;
end;
$$;

revoke all on function get_payment_history(text, uuid) from public;
grant execute on function get_payment_history(text, uuid) to authenticated;

-- ------------------------------------------------------------
-- 6. Reverse one allocation with an equal and opposite voucher.
-- ------------------------------------------------------------
create or replace function reverse_payment_allocation(
  p_allocation_id uuid,
  p_reason text,
  p_date date default current_date
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  a record;
  h record;
  v_cashbank uuid;
  v_party_acct uuid;
  v_fiscal_year text;
  v_reversal_voucher_id uuid;
  v_active_count integer;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  if p_reason is null or length(trim(p_reason)) < 3 then
    raise exception 'A reversal reason of at least 3 characters is required.';
  end if;
  if p_date is null then raise exception 'Reversal date is required.'; end if;

  select pa.*, dp.payment_date, dp.deposit_code, dp.payment_kind,
         dp.status as payment_status, dp.voucher_id as original_voucher_id, dp.is_legacy
    into a
    from payment_allocations pa
    join document_payments dp on dp.id = pa.payment_id
   where pa.id = p_allocation_id and pa.user_id = uid
   for update of pa;

  if not found then raise exception 'Payment allocation not found.'; end if;
  if a.reversed_at is not null then raise exception 'Payment allocation is already reversed.'; end if;
  if a.original_voucher_id is null then
    raise exception 'This legacy payment has no posting voucher. Verify it and correct it through a reviewed journal instead of automatic reversal.';
  end if;
  if p_date < a.payment_date then
    raise exception 'Reversal date cannot be before the original payment date.';
  end if;

  v_cashbank := resolve_system_account(a.deposit_code);

  if a.invoice_id is not null then
    select * into h
      from invoices
     where id = a.invoice_id and user_id = uid
     for update;
    if not found then raise exception 'Invoice not found.'; end if;

    if h.party_id is not null then
      select account_id into v_party_acct
        from parties
       where id = h.party_id and user_id = uid;
    end if;
    if v_party_acct is null then v_party_acct := resolve_system_account('ar_control'); end if;
    v_fiscal_year := h.fiscal_year;

    v_reversal_voucher_id := post_voucher(
      'receipt', v_fiscal_year, p_date,
      'Reversal of receipt against Invoice #' || h.invoice_number || ': ' || trim(p_reason),
      jsonb_build_array(
        jsonb_build_object('account_id', v_party_acct, 'debit', a.allocated_amount, 'credit', 0, 'description', h.party_name),
        jsonb_build_object('account_id', v_cashbank, 'debit', 0, 'credit', a.allocated_amount, 'description', 'Receipt reversal')
      )
    );

  elsif a.bill_id is not null then
    select * into h
      from purchase_bills
     where id = a.bill_id and user_id = uid
     for update;
    if not found then raise exception 'Bill not found.'; end if;

    if h.vendor_id is not null then
      select account_id into v_party_acct
        from parties
       where id = h.vendor_id and user_id = uid;
    end if;
    if v_party_acct is null then v_party_acct := resolve_system_account('ap_control'); end if;
    v_fiscal_year := h.fiscal_year;

    v_reversal_voucher_id := post_voucher(
      'payment', v_fiscal_year, p_date,
      'Reversal of payment against Bill #' || h.bill_number || ': ' || trim(p_reason),
      jsonb_build_array(
        jsonb_build_object('account_id', v_cashbank, 'debit', a.allocated_amount, 'credit', 0, 'description', 'Payment reversal'),
        jsonb_build_object('account_id', v_party_acct, 'debit', 0, 'credit', a.allocated_amount, 'description', h.vendor_name)
      )
    );
  else
    raise exception 'Allocation has no linked document.';
  end if;

  update payment_allocations
     set reversed_at = now(),
         reversal_reason = trim(p_reason),
         reversal_voucher_id = v_reversal_voucher_id
   where id = p_allocation_id and user_id = uid;

  select count(*)::integer
    into v_active_count
    from payment_allocations
   where payment_id = a.payment_id and reversed_at is null;

  update document_payments
     set status = case when v_active_count = 0 then 'reversed' else 'partially_reversed' end
   where id = a.payment_id and user_id = uid;

  if a.invoice_id is not null then
    perform refresh_document_payment_status('invoice', a.invoice_id);
  else
    perform refresh_document_payment_status('bill', a.bill_id);
  end if;

  perform write_audit_log(
    'reverse', 'payment_allocations', p_allocation_id::text, null,
    jsonb_build_object(
      'reason', trim(p_reason),
      'amount', a.allocated_amount,
      'reversal_voucher_id', v_reversal_voucher_id
    )
  );

  return v_reversal_voucher_id;
end;
$$;

revoke all on function reverse_payment_allocation(uuid, text, date) from public;
grant execute on function reverse_payment_allocation(uuid, text, date) to authenticated;

-- ------------------------------------------------------------
-- 7. Preserve legacy paid/partial data as explicit allocations.
--    These rows are marked for later review because older releases
--    stored only one settlement voucher reference.
-- ------------------------------------------------------------
do $$
declare
  r record;
  v_payment_id uuid;
  v_amount numeric(14,2);
  v_payment_date date;
  v_deposit_code text;
begin
  for r in
    select i.*
      from invoices i
     where (i.status = 'paid' or i.amount_paid > 0)
       and not exists (
         select 1 from payment_allocations a where a.invoice_id = i.id
       )
  loop
    v_amount := least(
      r.total,
      case when r.amount_paid > 0 then r.amount_paid else r.total end
    );
    if v_amount > 0 then
      select coalesce(v.voucher_date, r.invoice_date, current_date),
             coalesce((
               select a.system_code
                 from voucher_lines vl
                 join accounts a on a.id = vl.account_id
                where vl.voucher_id = r.settlement_voucher_id
                  and a.user_id = r.user_id
                  and a.system_code in ('cash', 'bank')
                order by vl.debit desc, vl.credit asc
                limit 1
             ), 'cash')
        into v_payment_date, v_deposit_code
        from (select 1) seed
        left join vouchers v on v.id = r.settlement_voucher_id;

      insert into document_payments (
        user_id, payment_kind, payment_date, deposit_code, amount,
        voucher_id, notes, is_legacy
      ) values (
        r.user_id, 'receipt', v_payment_date, v_deposit_code, v_amount,
        r.settlement_voucher_id,
        'Migrated from legacy invoice payment status; verify against cash/bank evidence.',
        true
      ) returning id into v_payment_id;

      insert into payment_allocations (
        user_id, payment_id, invoice_id, allocated_amount
      ) values (
        r.user_id, v_payment_id, r.id, v_amount
      );
    end if;
  end loop;

  for r in
    select b.*
      from purchase_bills b
     where (b.status = 'paid' or b.amount_paid > 0)
       and not exists (
         select 1 from payment_allocations a where a.bill_id = b.id
       )
  loop
    v_amount := least(
      r.total,
      case when r.amount_paid > 0 then r.amount_paid else r.total end
    );
    if v_amount > 0 then
      select coalesce(v.voucher_date, r.bill_date, current_date),
             coalesce((
               select a.system_code
                 from voucher_lines vl
                 join accounts a on a.id = vl.account_id
                where vl.voucher_id = r.settlement_voucher_id
                  and a.user_id = r.user_id
                  and a.system_code in ('cash', 'bank')
                order by vl.credit desc, vl.debit asc
                limit 1
             ), 'cash')
        into v_payment_date, v_deposit_code
        from (select 1) seed
        left join vouchers v on v.id = r.settlement_voucher_id;

      insert into document_payments (
        user_id, payment_kind, payment_date, deposit_code, amount,
        voucher_id, notes, is_legacy
      ) values (
        r.user_id, 'payment', v_payment_date, v_deposit_code, v_amount,
        r.settlement_voucher_id,
        'Migrated from legacy bill payment status; verify against cash/bank evidence.',
        true
      ) returning id into v_payment_id;

      insert into payment_allocations (
        user_id, payment_id, bill_id, allocated_amount
      ) values (
        r.user_id, v_payment_id, r.id, v_amount
      );
    end if;
  end loop;
end;
$$;

-- Set payment summaries for all existing documents without requiring auth.uid().
with paid as (
  select i.id,
         least(i.total, coalesce(sum(a.allocated_amount) filter (where a.reversed_at is null), 0)) as amount_paid
    from invoices i
    left join payment_allocations a on a.invoice_id = i.id
   group by i.id, i.total
)
update invoices i
   set amount_paid = p.amount_paid,
       outstanding_amount = greatest(i.total - p.amount_paid, 0),
       status = case
         when i.status in ('cancelled','credited','draft') then i.status
         when i.total - p.amount_paid <= 0.005 then 'paid'
         when i.due_date is not null and i.due_date < current_date then 'overdue'
         when p.amount_paid > 0.005 then 'partial'
         else 'open'
       end,
       payment_status_updated_at = now()
  from paid p
 where p.id = i.id;

with paid as (
  select b.id,
         least(b.total, coalesce(sum(a.allocated_amount) filter (where a.reversed_at is null), 0)) as amount_paid
    from purchase_bills b
    left join payment_allocations a on a.bill_id = b.id
   group by b.id, b.total
)
update purchase_bills b
   set amount_paid = p.amount_paid,
       outstanding_amount = greatest(b.total - p.amount_paid, 0),
       status = case
         when b.status in ('cancelled','credited','draft') then b.status
         when b.total - p.amount_paid <= 0.005 then 'paid'
         when b.due_date is not null and b.due_date < current_date then 'overdue'
         when p.amount_paid > 0.005 then 'partial'
         else 'open'
       end,
       payment_status_updated_at = now()
  from paid p
 where p.id = b.id;

-- Prevent invalid cached summaries.
alter table invoices drop constraint if exists invoices_amount_paid_check;
alter table invoices add constraint invoices_amount_paid_check
  check (amount_paid >= 0 and outstanding_amount >= 0);

alter table purchase_bills drop constraint if exists purchase_bills_amount_paid_check;
alter table purchase_bills add constraint purchase_bills_amount_paid_check
  check (amount_paid >= 0 and outstanding_amount >= 0);

-- ------------------------------------------------------------
-- 8. Dashboard overdue count updated for Stage 2 statuses.
-- ------------------------------------------------------------
create or replace function get_dashboard_stats()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  result jsonb;
  v_cash numeric; v_receivables numeric; v_payables numeric;
  v_sales_this numeric; v_sales_last numeric;
  v_vat_payable numeric; v_stock_value numeric;
  v_low_stock integer; v_invoice_count integer; v_overdue_count integer;
  v_overdue_amount numeric; v_invoice_outstanding numeric; v_bill_outstanding numeric;
  this_month_start date; last_month_start date; last_month_end date;
begin
  if uid is null then raise exception 'Not authenticated'; end if;

  this_month_start := date_trunc('month', current_date)::date;
  last_month_start := (date_trunc('month', current_date) - interval '1 month')::date;
  last_month_end   := (this_month_start - 1)::date;

  select coalesce(sum(
    case when a.opening_balance_type='debit' then a.opening_balance else -a.opening_balance end
    + coalesce((select sum(vl.debit-vl.credit) from voucher_lines vl
                join vouchers v on v.id=vl.voucher_id and v.is_void=false
                where vl.account_id=a.id),0)
  ),0)
  into v_cash
  from accounts a
  where a.user_id=uid and a.is_active=true
    and a.group_name in ('Cash-in-Hand','Bank Accounts');

  select coalesce(sum(
    case when a.opening_balance_type='debit' then a.opening_balance else -a.opening_balance end
    + coalesce((select sum(vl.debit-vl.credit) from voucher_lines vl
                join vouchers v on v.id=vl.voucher_id and v.is_void=false
                where vl.account_id=a.id),0)
  ),0)
  into v_receivables
  from accounts a
  where a.user_id=uid and a.is_active=true
    and a.group_name in ('Sundry Debtors') and a.account_type='asset';

  select coalesce(sum(-(
    case when a.opening_balance_type='debit' then a.opening_balance else -a.opening_balance end
    + coalesce((select sum(vl.debit-vl.credit) from voucher_lines vl
                join vouchers v on v.id=vl.voucher_id and v.is_void=false
                where vl.account_id=a.id),0)
  )),0)
  into v_payables
  from accounts a
  where a.user_id=uid and a.is_active=true
    and a.group_name in ('Sundry Creditors') and a.account_type='liability';

  select
    coalesce(sum(case when invoice_date >= this_month_start then subtotal else 0 end),0),
    coalesce(sum(case when invoice_date between last_month_start and last_month_end then subtotal else 0 end),0)
  into v_sales_this, v_sales_last
  from invoices where user_id=uid and status not in ('cancelled','credited');

  select coalesce(sum(case when i.invoice_date >= this_month_start then i.vat_amount else 0 end),0)
       - coalesce((select sum(b.vat_amount) from purchase_bills b
                   where b.user_id=uid and b.bill_date >= this_month_start
                     and b.status not in ('cancelled','credited')),0)
  into v_vat_payable
  from invoices i
  where i.user_id=uid and i.status not in ('cancelled','credited');

  select coalesce(sum(current_stock * cost_price),0),
         count(case when current_stock <= reorder_level then 1 end)::integer
  into v_stock_value, v_low_stock
  from inventory_items where user_id=uid and is_active=true;

  select count(*)::integer,
         count(*) filter (
           where due_date < current_date
             and outstanding_amount > 0.005
             and status in ('open','partial','overdue')
         )::integer,
         coalesce(sum(outstanding_amount) filter (
           where due_date < current_date
             and outstanding_amount > 0.005
             and status in ('open','partial','overdue')
         ),0),
         coalesce(sum(outstanding_amount),0)
    into v_invoice_count, v_overdue_count, v_overdue_amount, v_invoice_outstanding
    from invoices
   where user_id=uid and status not in ('cancelled','credited');

  select coalesce(sum(outstanding_amount),0)
    into v_bill_outstanding
    from purchase_bills
   where user_id=uid and status not in ('cancelled','credited');

  result := jsonb_build_object(
    'cash',                v_cash,
    'receivables',         v_receivables,
    'payables',            v_payables,
    'sales_this',          v_sales_this,
    'sales_last',          v_sales_last,
    'vat_payable',         v_vat_payable,
    'stock_value',         v_stock_value,
    'low_stock',           v_low_stock,
    'invoice_count',       v_invoice_count,
    'overdue_count',       v_overdue_count,
    'overdue_amount',      v_overdue_amount,
    'invoice_outstanding', v_invoice_outstanding,
    'bill_outstanding',    v_bill_outstanding,
    'vat_deadline',        to_char(date_trunc('month', current_date) + interval '1 month' + interval '14 days', 'YYYY-MM-DD')
  );

  return result;
end;
$$;

revoke all on function get_dashboard_stats() from public;
grant execute on function get_dashboard_stats() to authenticated;

commit;
