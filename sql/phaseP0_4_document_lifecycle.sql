-- ============================================================
-- HisabKitab Stage 4 - controlled document lifecycle
-- Apply after phaseP0_3_inventory_cogs.sql.
--
-- Implements:
--   * explicit draft / posted / cancelled / credited lifecycle
--   * editable drafts and immutable posted documents
--   * source-linked vouchers and controlled reversal vouchers
--   * immutable document numbering per fiscal year
--   * sales credit notes and purchase debit notes
--   * complete VAT, party, inventory, and COGS return posting
--   * internal notes and private document attachments
-- ============================================================

begin;

-- Stage 4 introduces lifecycle-specific audit actions. Earlier security
-- migrations allowed only a small fixed action list.
alter table audit_log drop constraint if exists audit_log_action_check;
alter table audit_log add constraint audit_log_action_check check (
  action in (
    'create','update','void','deactivate','login','logout','reverse',
    'create_draft','update_draft','delete_draft','post','cancel'
  )
);

-- ------------------------------------------------------------
-- 1. Lifecycle fields on invoices and purchase bills.
--    `status` remains the Stage 2 payment status for compatibility.
-- ------------------------------------------------------------
alter table invoices
  add column if not exists document_status text not null default 'posted',
  add column if not exists posted_at timestamptz,
  add column if not exists cancelled_at timestamptz,
  add column if not exists cancellation_reason text,
  add column if not exists cancellation_voucher_id uuid references vouchers(id),
  add column if not exists credited_amount numeric(14,2) not null default 0,
  add column if not exists net_total numeric(14,2) not null default 0;

alter table purchase_bills
  add column if not exists document_status text not null default 'posted',
  add column if not exists posted_at timestamptz,
  add column if not exists cancelled_at timestamptz,
  add column if not exists cancellation_reason text,
  add column if not exists cancellation_voucher_id uuid references vouchers(id),
  add column if not exists credited_amount numeric(14,2) not null default 0,
  add column if not exists net_total numeric(14,2) not null default 0;

update invoices
   set document_status = case
         when status = 'draft' then 'draft'
         when status = 'cancelled' then 'cancelled'
         when status = 'credited' then 'credited'
         else 'posted'
       end,
       posted_at = case when status <> 'draft' then coalesce(posted_at, created_at) else posted_at end,
       credited_amount = greatest(coalesce(credited_amount, 0), 0),
       net_total = greatest(round(total - coalesce(credited_amount, 0), 2), 0);

update purchase_bills
   set document_status = case
         when status = 'draft' then 'draft'
         when status = 'cancelled' then 'cancelled'
         when status = 'credited' then 'credited'
         else 'posted'
       end,
       posted_at = case when status <> 'draft' then coalesce(posted_at, created_at) else posted_at end,
       credited_amount = greatest(coalesce(credited_amount, 0), 0),
       net_total = greatest(round(total - coalesce(credited_amount, 0), 2), 0);

alter table invoices drop constraint if exists invoices_document_status_check;
alter table invoices add constraint invoices_document_status_check
  check (document_status in ('draft','posted','cancelled','credited'));

alter table purchase_bills drop constraint if exists purchase_bills_document_status_check;
alter table purchase_bills add constraint purchase_bills_document_status_check
  check (document_status in ('draft','posted','cancelled','credited'));

alter table invoices drop constraint if exists invoices_lifecycle_amounts_check;
alter table invoices add constraint invoices_lifecycle_amounts_check
  check (
    credited_amount >= 0
    and credited_amount <= total + 0.01
    and net_total >= 0
    and net_total <= total + 0.01
    and abs(net_total - greatest(total - credited_amount, 0)) <= 0.01
  );

alter table purchase_bills drop constraint if exists purchase_bills_lifecycle_amounts_check;
alter table purchase_bills add constraint purchase_bills_lifecycle_amounts_check
  check (
    credited_amount >= 0
    and credited_amount <= total + 0.01
    and net_total >= 0
    and net_total <= total + 0.01
    and abs(net_total - greatest(total - credited_amount, 0)) <= 0.01
  );

-- ------------------------------------------------------------
-- 2. Source links on vouchers.
-- ------------------------------------------------------------
alter table vouchers
  add column if not exists source_document_type text,
  add column if not exists source_document_id uuid,
  add column if not exists reversal_of_voucher_id uuid references vouchers(id),
  add column if not exists reversal_reason text;

create index if not exists idx_vouchers_source_document
  on vouchers(user_id, source_document_type, source_document_id);
create index if not exists idx_vouchers_reversal
  on vouchers(reversal_of_voucher_id);

update vouchers v
   set source_document_type = 'invoice',
       source_document_id = i.id
  from invoices i
 where i.voucher_id = v.id
   and v.source_document_id is null;

update vouchers v
   set source_document_type = 'purchase_bill',
       source_document_id = b.id
  from purchase_bills b
 where b.voucher_id = v.id
   and v.source_document_id is null;

-- Existing and future payment, reversal, and inventory vouchers receive a
-- stable source link without overwriting a document link already assigned by
-- the invoice/bill/note posting function.
update vouchers v
   set source_document_type = 'document_payment',
       source_document_id = p.id
  from document_payments p
 where p.voucher_id = v.id
   and v.source_document_id is null;

update vouchers v
   set source_document_type = 'payment_allocation_reversal',
       source_document_id = a.id,
       reversal_of_voucher_id = p.voucher_id,
       reversal_reason = a.reversal_reason
  from payment_allocations a
  join document_payments p on p.id = a.payment_id
 where a.reversal_voucher_id = v.id
   and v.source_document_id is null;

with movement_source as (
  select distinct on (voucher_id) voucher_id, id
  from inventory_movements
  where voucher_id is not null
  order by voucher_id, created_at, id
)
update vouchers v
   set source_document_type = 'inventory_movement',
       source_document_id = m.id
  from movement_source m
 where m.voucher_id = v.id
   and v.source_document_id is null;

create or replace function link_document_payment_voucher()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.voucher_id is not null then
    update vouchers
       set source_document_type = coalesce(source_document_type, 'document_payment'),
           source_document_id = coalesce(source_document_id, new.id)
     where id = new.voucher_id and user_id = new.user_id;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_link_document_payment_voucher on document_payments;
create trigger trg_link_document_payment_voucher
after insert or update of voucher_id on document_payments
for each row execute function link_document_payment_voucher();

create or replace function link_payment_reversal_voucher()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_original_voucher uuid;
begin
  if new.reversal_voucher_id is not null
     and new.reversal_voucher_id is distinct from old.reversal_voucher_id then
    select voucher_id into v_original_voucher
      from document_payments
     where id = new.payment_id and user_id = new.user_id;
    update vouchers
       set source_document_type = 'payment_allocation_reversal',
           source_document_id = new.id,
           reversal_of_voucher_id = v_original_voucher,
           reversal_reason = new.reversal_reason
     where id = new.reversal_voucher_id and user_id = new.user_id;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_link_payment_reversal_voucher on payment_allocations;
create trigger trg_link_payment_reversal_voucher
after update of reversal_voucher_id on payment_allocations
for each row execute function link_payment_reversal_voucher();

create or replace function link_inventory_movement_voucher()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.voucher_id is not null then
    if tg_op = 'INSERT' then
      update vouchers
         set source_document_type = coalesce(source_document_type, 'inventory_movement'),
             source_document_id = coalesce(source_document_id, new.id)
       where id = new.voucher_id and user_id = new.user_id;
    elsif new.voucher_id is distinct from old.voucher_id then
      update vouchers
         set source_document_type = coalesce(source_document_type, 'inventory_movement'),
             source_document_id = coalesce(source_document_id, new.id)
       where id = new.voucher_id and user_id = new.user_id;
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_link_inventory_movement_voucher on inventory_movements;
create trigger trg_link_inventory_movement_voucher
after insert or update of voucher_id on inventory_movements
for each row execute function link_inventory_movement_voucher();

-- ------------------------------------------------------------
-- 3. Credit/debit note tables.
-- ------------------------------------------------------------
create table if not exists credit_notes (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  cn_number integer not null,
  fiscal_year text not null,
  cn_date date not null,
  invoice_id uuid references invoices(id) on delete restrict,
  invoice_number integer,
  party_id uuid references parties(id),
  party_name text not null,
  party_address text,
  party_pan text,
  subtotal numeric(14,2) not null default 0,
  vat_amount numeric(14,2) not null default 0,
  total numeric(14,2) not null default 0,
  inventory_cost_amount numeric(18,2) not null default 0,
  reason text not null,
  notes text,
  voucher_id uuid references vouchers(id),
  document_status text not null default 'posted',
  posted_at timestamptz,
  cancelled_at timestamptz,
  cancellation_reason text,
  cancellation_voucher_id uuid references vouchers(id),
  created_at timestamptz not null default now()
);

create table if not exists credit_note_lines (
  id uuid primary key default gen_random_uuid(),
  credit_note_id uuid not null references credit_notes(id) on delete cascade,
  source_line_id uuid references invoice_lines(id) on delete restrict,
  item_id uuid references inventory_items(id),
  description text not null,
  quantity numeric(14,3) not null,
  unit text,
  rate numeric(14,2) not null,
  amount numeric(14,2) not null,
  vat_rate numeric(5,2) not null,
  vat_amount numeric(14,2) not null,
  line_total numeric(14,2) not null,
  inventory_unit_cost numeric(18,6),
  inventory_cost_amount numeric(18,2)
);

create table if not exists debit_notes (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  dn_number integer not null,
  fiscal_year text not null,
  dn_date date not null,
  bill_id uuid references purchase_bills(id) on delete restrict,
  bill_number integer,
  vendor_id uuid references parties(id),
  vendor_name text not null,
  vendor_address text,
  vendor_pan text,
  subtotal numeric(14,2) not null default 0,
  vat_amount numeric(14,2) not null default 0,
  total numeric(14,2) not null default 0,
  inventory_cost_amount numeric(18,2) not null default 0,
  expense_reversal_amount numeric(18,2) not null default 0,
  valuation_difference numeric(18,2) not null default 0,
  reason text not null,
  notes text,
  voucher_id uuid references vouchers(id),
  document_status text not null default 'posted',
  posted_at timestamptz,
  cancelled_at timestamptz,
  cancellation_reason text,
  cancellation_voucher_id uuid references vouchers(id),
  created_at timestamptz not null default now()
);

create table if not exists debit_note_lines (
  id uuid primary key default gen_random_uuid(),
  debit_note_id uuid not null references debit_notes(id) on delete cascade,
  source_line_id uuid references purchase_bill_lines(id) on delete restrict,
  item_id uuid references inventory_items(id),
  description text not null,
  quantity numeric(14,3) not null,
  unit text,
  rate numeric(14,2) not null,
  amount numeric(14,2) not null,
  vat_rate numeric(5,2) not null,
  vat_amount numeric(14,2) not null,
  line_total numeric(14,2) not null,
  inventory_unit_cost numeric(18,6),
  inventory_cost_amount numeric(18,2)
);

-- Add columns when a hand-created earlier table already exists.
alter table credit_notes add column if not exists invoice_id uuid references invoices(id) on delete restrict;
alter table credit_notes add column if not exists invoice_number integer;
alter table credit_notes add column if not exists inventory_cost_amount numeric(18,2) not null default 0;
alter table credit_notes add column if not exists voucher_id uuid references vouchers(id);
alter table credit_notes add column if not exists document_status text not null default 'posted';
alter table credit_notes add column if not exists posted_at timestamptz;
alter table credit_notes add column if not exists cancelled_at timestamptz;
alter table credit_notes add column if not exists cancellation_reason text;
alter table credit_notes add column if not exists cancellation_voucher_id uuid references vouchers(id);

alter table credit_note_lines add column if not exists source_line_id uuid references invoice_lines(id) on delete restrict;
alter table credit_note_lines add column if not exists item_id uuid references inventory_items(id);
alter table credit_note_lines add column if not exists inventory_unit_cost numeric(18,6);
alter table credit_note_lines add column if not exists inventory_cost_amount numeric(18,2);

alter table debit_notes add column if not exists bill_id uuid references purchase_bills(id) on delete restrict;
alter table debit_notes add column if not exists bill_number integer;
alter table debit_notes add column if not exists inventory_cost_amount numeric(18,2) not null default 0;
alter table debit_notes add column if not exists expense_reversal_amount numeric(18,2) not null default 0;
alter table debit_notes add column if not exists valuation_difference numeric(18,2) not null default 0;
alter table debit_notes add column if not exists voucher_id uuid references vouchers(id);
alter table debit_notes add column if not exists document_status text not null default 'posted';
alter table debit_notes add column if not exists posted_at timestamptz;
alter table debit_notes add column if not exists cancelled_at timestamptz;
alter table debit_notes add column if not exists cancellation_reason text;
alter table debit_notes add column if not exists cancellation_voucher_id uuid references vouchers(id);

alter table debit_note_lines add column if not exists source_line_id uuid references purchase_bill_lines(id) on delete restrict;
alter table debit_note_lines add column if not exists item_id uuid references inventory_items(id);
alter table debit_note_lines add column if not exists inventory_unit_cost numeric(18,6);
alter table debit_note_lines add column if not exists inventory_cost_amount numeric(18,2);

alter table credit_notes drop constraint if exists credit_notes_document_status_check;
alter table credit_notes add constraint credit_notes_document_status_check
  check (document_status in ('posted','cancelled'));
alter table debit_notes drop constraint if exists debit_notes_document_status_check;
alter table debit_notes add constraint debit_notes_document_status_check
  check (document_status in ('posted','cancelled'));

alter table credit_note_lines drop constraint if exists credit_note_lines_quantity_check;
alter table credit_note_lines add constraint credit_note_lines_quantity_check check (quantity > 0);
alter table debit_note_lines drop constraint if exists debit_note_lines_quantity_check;
alter table debit_note_lines add constraint debit_note_lines_quantity_check check (quantity > 0);

alter table credit_notes enable row level security;
alter table credit_note_lines enable row level security;
alter table debit_notes enable row level security;
alter table debit_note_lines enable row level security;

drop policy if exists "own credit notes" on credit_notes;
create policy "own credit notes" on credit_notes for select
  using (auth.uid() = user_id);
drop policy if exists "own credit note lines" on credit_note_lines;
create policy "own credit note lines" on credit_note_lines for select
  using (exists (
    select 1 from credit_notes n
    where n.id = credit_note_lines.credit_note_id and n.user_id = auth.uid()
  ));
drop policy if exists "own debit notes" on debit_notes;
create policy "own debit notes" on debit_notes for select
  using (auth.uid() = user_id);
drop policy if exists "own debit note lines" on debit_note_lines;
create policy "own debit note lines" on debit_note_lines for select
  using (exists (
    select 1 from debit_notes n
    where n.id = debit_note_lines.debit_note_id and n.user_id = auth.uid()
  ));

create index if not exists idx_credit_notes_user_date on credit_notes(user_id, cn_date desc);
create index if not exists idx_credit_notes_invoice on credit_notes(invoice_id);
create index if not exists idx_credit_note_lines_note on credit_note_lines(credit_note_id);
create index if not exists idx_debit_notes_user_date on debit_notes(user_id, dn_date desc);
create index if not exists idx_debit_notes_bill on debit_notes(bill_id);
create index if not exists idx_debit_note_lines_note on debit_note_lines(debit_note_id);

update vouchers v
   set source_document_type='credit_note', source_document_id=n.id
  from credit_notes n
 where n.voucher_id=v.id and v.source_document_id is null;
update vouchers v
   set source_document_type='debit_note', source_document_id=n.id
  from debit_notes n
 where n.voucher_id=v.id and v.source_document_id is null;
update vouchers v
   set source_document_type='credit_note_cancellation', source_document_id=n.id,
       reversal_of_voucher_id=n.voucher_id, reversal_reason=n.cancellation_reason
  from credit_notes n
 where n.cancellation_voucher_id=v.id and v.source_document_id is null;
update vouchers v
   set source_document_type='debit_note_cancellation', source_document_id=n.id,
       reversal_of_voucher_id=n.voucher_id, reversal_reason=n.cancellation_reason
  from debit_notes n
 where n.cancellation_voucher_id=v.id and v.source_document_id is null;

-- Seed note number sequences from any existing rows.
insert into doc_sequences(user_id, doc_type, fiscal_year, last_num)
select user_id, 'credit_note', fiscal_year, max(cn_number)
from credit_notes group by user_id, fiscal_year
on conflict (user_id, doc_type, fiscal_year) do update
set last_num = greatest(doc_sequences.last_num, excluded.last_num);

insert into doc_sequences(user_id, doc_type, fiscal_year, last_num)
select user_id, 'debit_note', fiscal_year, max(dn_number)
from debit_notes group by user_id, fiscal_year
on conflict (user_id, doc_type, fiscal_year) do update
set last_num = greatest(doc_sequences.last_num, excluded.last_num);

-- Immutable, owner-scoped fiscal-year document numbers.
create unique index if not exists uq_invoice_number_fy
  on invoices(user_id, fiscal_year, invoice_number);
create unique index if not exists uq_bill_number_fy
  on purchase_bills(user_id, fiscal_year, bill_number);
create unique index if not exists uq_credit_note_number_fy
  on credit_notes(user_id, fiscal_year, cn_number);
create unique index if not exists uq_debit_note_number_fy
  on debit_notes(user_id, fiscal_year, dn_number);

create or replace function protect_document_identity()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.user_id is distinct from old.user_id
     or new.fiscal_year is distinct from old.fiscal_year then
    raise exception 'Document owner and fiscal year are immutable.';
  end if;

  if tg_table_name = 'invoices' and new.invoice_number is distinct from old.invoice_number then
    raise exception 'Invoice number is immutable.';
  elsif tg_table_name = 'purchase_bills' and new.bill_number is distinct from old.bill_number then
    raise exception 'Bill number is immutable.';
  elsif tg_table_name = 'credit_notes' and new.cn_number is distinct from old.cn_number then
    raise exception 'Credit note number is immutable.';
  elsif tg_table_name = 'debit_notes' and new.dn_number is distinct from old.dn_number then
    raise exception 'Debit note number is immutable.';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_invoice_identity on invoices;
create trigger trg_invoice_identity before update on invoices
for each row execute function protect_document_identity();
drop trigger if exists trg_bill_identity on purchase_bills;
create trigger trg_bill_identity before update on purchase_bills
for each row execute function protect_document_identity();
drop trigger if exists trg_credit_note_identity on credit_notes;
create trigger trg_credit_note_identity before update on credit_notes
for each row execute function protect_document_identity();
drop trigger if exists trg_debit_note_identity on debit_notes;
create trigger trg_debit_note_identity before update on debit_notes
for each row execute function protect_document_identity();

-- ------------------------------------------------------------
-- 4. Internal notes and private attachment metadata.
-- ------------------------------------------------------------
create table if not exists document_internal_notes (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  document_type text not null check (document_type in ('invoice','bill','credit_note','debit_note')),
  document_id uuid not null,
  note_text text not null,
  created_at timestamptz not null default now()
);

create table if not exists document_attachments (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  document_type text not null check (document_type in ('invoice','bill','credit_note','debit_note')),
  document_id uuid not null,
  storage_bucket text not null default 'document-attachments',
  storage_path text not null,
  file_name text not null,
  mime_type text,
  size_bytes bigint,
  created_at timestamptz not null default now(),
  unique(storage_bucket, storage_path)
);

create index if not exists idx_document_internal_notes_doc
  on document_internal_notes(user_id, document_type, document_id, created_at desc);
create index if not exists idx_document_attachments_doc
  on document_attachments(user_id, document_type, document_id, created_at desc);

alter table document_internal_notes enable row level security;
alter table document_attachments enable row level security;
drop policy if exists "own document internal notes" on document_internal_notes;
create policy "own document internal notes" on document_internal_notes for select
  using (auth.uid() = user_id);
drop policy if exists "own document attachments" on document_attachments;
create policy "own document attachments" on document_attachments for select
  using (auth.uid() = user_id);

-- Supabase Storage bucket and owner-folder policies.
insert into storage.buckets(id, name, public)
values ('document-attachments', 'document-attachments', false)
on conflict (id) do update set public = false;

drop policy if exists "document attachment owner read" on storage.objects;
create policy "document attachment owner read" on storage.objects for select to authenticated
using (
  bucket_id = 'document-attachments'
  and (storage.foldername(name))[1] = auth.uid()::text
);

drop policy if exists "document attachment owner upload" on storage.objects;
create policy "document attachment owner upload" on storage.objects for insert to authenticated
with check (
  bucket_id = 'document-attachments'
  and (storage.foldername(name))[1] = auth.uid()::text
);

drop policy if exists "document attachment owner delete" on storage.objects;
create policy "document attachment owner delete" on storage.objects for delete to authenticated
using (
  bucket_id = 'document-attachments'
  and (storage.foldername(name))[1] = auth.uid()::text
);

create or replace function assert_owned_document(p_document_type text, p_document_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  v_exists boolean := false;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  case p_document_type
    when 'invoice' then select exists(select 1 from invoices where id=p_document_id and user_id=uid) into v_exists;
    when 'bill' then select exists(select 1 from purchase_bills where id=p_document_id and user_id=uid) into v_exists;
    when 'credit_note' then select exists(select 1 from credit_notes where id=p_document_id and user_id=uid) into v_exists;
    when 'debit_note' then select exists(select 1 from debit_notes where id=p_document_id and user_id=uid) into v_exists;
    else raise exception 'Unsupported document type: %', p_document_type;
  end case;
  if not v_exists then raise exception 'Document not found.'; end if;
end;
$$;

create or replace function add_document_internal_note(
  p_document_type text,
  p_document_id uuid,
  p_note_text text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  v_id uuid;
begin
  if nullif(trim(coalesce(p_note_text,'')), '') is null then
    raise exception 'Internal note cannot be blank.';
  end if;
  perform assert_owned_document(p_document_type, p_document_id);
  insert into document_internal_notes(user_id, document_type, document_id, note_text)
  values(uid, p_document_type, p_document_id, left(trim(p_note_text), 4000))
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function register_document_attachment(
  p_document_type text,
  p_document_id uuid,
  p_storage_path text,
  p_file_name text,
  p_mime_type text default null,
  p_size_bytes bigint default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  v_id uuid;
begin
  perform assert_owned_document(p_document_type, p_document_id);
  if p_storage_path is null or split_part(p_storage_path, '/', 1) <> uid::text then
    raise exception 'Attachment path must be inside the signed-in owner folder.';
  end if;
  if p_size_bytes is not null and (p_size_bytes < 0 or p_size_bytes > 20971520) then
    raise exception 'Attachment size must not exceed 20 MB.';
  end if;
  insert into document_attachments(
    user_id, document_type, document_id, storage_path,
    file_name, mime_type, size_bytes
  ) values (
    uid, p_document_type, p_document_id, p_storage_path,
    left(coalesce(nullif(trim(p_file_name),''),'attachment'), 255),
    nullif(trim(p_mime_type),''), p_size_bytes
  ) returning id into v_id;
  return v_id;
end;
$$;

create or replace function delete_document_attachment(p_attachment_id uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  v_path text;
begin
  delete from document_attachments
   where id = p_attachment_id and user_id = uid
   returning storage_path into v_path;
  if v_path is null then raise exception 'Attachment not found.'; end if;
  return v_path;
end;
$$;

-- ------------------------------------------------------------
-- 5. Draft save/update/delete functions.
-- ------------------------------------------------------------
create or replace function save_invoice_draft(
  p_header jsonb,
  p_lines jsonb,
  p_invoice_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  v_id uuid := p_invoice_id;
  v_num integer;
  v_fy text;
  v_subtotal numeric(14,2);
  v_vat numeric(14,2);
  v_total numeric(14,2);
  v_existing record;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'At least one invoice line is required.';
  end if;
  v_fy := nullif(trim(p_header->>'fiscal_year'), '');
  if v_fy is null then raise exception 'Fiscal year is required.'; end if;
  if nullif(p_header->>'invoice_date','') is null then raise exception 'Invoice date is required.'; end if;
  if nullif(p_header->>'due_date','') is not null
     and (p_header->>'due_date')::date < (p_header->>'invoice_date')::date then
    raise exception 'Invoice due date cannot precede invoice date.';
  end if;
  if nullif(trim(p_header->>'party_name'), '') is null then raise exception 'Customer name is required.'; end if;
  if nullif(p_header->>'party_id','') is not null and not exists (
    select 1 from parties where id=(p_header->>'party_id')::uuid and user_id=uid
  ) then raise exception 'Customer does not belong to this business.'; end if;
  if exists (
    select 1 from jsonb_array_elements(p_lines) l
    where nullif(trim(l->>'description'),'') is null
       or coalesce((l->>'quantity')::numeric,0) <= 0
       or coalesce((l->>'rate')::numeric,0) < 0
       or coalesce((l->>'vat_rate')::numeric,0) < 0
       or coalesce((l->>'vat_rate')::numeric,0) > 100
  ) then raise exception 'Invoice lines require a description, positive quantity, non-negative rate, and VAT from 0 to 100.'; end if;
  if exists (
    select 1 from jsonb_array_elements(p_lines) l
    left join inventory_items i on i.id=nullif(l->>'item_id','')::uuid and i.user_id=uid and i.is_active=true
    where nullif(l->>'item_id','') is not null and i.id is null
  ) then raise exception 'One or more invoice items do not belong to this business.'; end if;

  select
         coalesce(sum(round(coalesce((l->>'quantity')::numeric,1) * coalesce((l->>'rate')::numeric,0),2)),0),
         coalesce(sum(round(
           round(coalesce((l->>'quantity')::numeric,1) * coalesce((l->>'rate')::numeric,0),2)
           * coalesce((l->>'vat_rate')::numeric,0) / 100, 2
         )),0)
    into v_subtotal, v_vat from jsonb_array_elements(p_lines) l;
  v_total := round(v_subtotal + v_vat, 2);
  if v_total <= 0 then raise exception 'Invoice total must be positive.'; end if;

  if v_id is null then
    select next_doc_number('invoice', v_fy) into v_num;
    insert into invoices(
      user_id, invoice_number, fiscal_year, invoice_date, due_date,
      party_id, party_name, party_address, party_pan,
      subtotal, vat_amount, total, status, document_status, notes,
      invoice_date_bs, due_date_bs,
      amount_paid, outstanding_amount, credited_amount, net_total,
      payment_status_updated_at
    ) values (
      uid, v_num, v_fy, (p_header->>'invoice_date')::date,
      nullif(p_header->>'due_date','')::date,
      nullif(p_header->>'party_id','')::uuid,
      trim(p_header->>'party_name'), nullif(trim(p_header->>'party_address'),''),
      nullif(trim(p_header->>'party_pan'),''),
      v_subtotal, v_vat, v_total, 'draft', 'draft', nullif(trim(p_header->>'notes'),''),
      coalesce(p_header->>'invoice_date_bs',''), coalesce(p_header->>'due_date_bs',''),
      0, v_total, 0, v_total, now()
    ) returning id into v_id;
  else
    select * into v_existing from invoices
     where id=v_id and user_id=uid for update;
    if not found then raise exception 'Invoice draft not found.'; end if;
    if v_existing.document_status <> 'draft' then raise exception 'Only a draft invoice can be edited.'; end if;
    if v_existing.fiscal_year <> v_fy then raise exception 'Fiscal year cannot change after a document number is assigned.'; end if;

    update invoices set
      invoice_date=(p_header->>'invoice_date')::date,
      due_date=nullif(p_header->>'due_date','')::date,
      party_id=nullif(p_header->>'party_id','')::uuid,
      party_name=trim(p_header->>'party_name'),
      party_address=nullif(trim(p_header->>'party_address'),''),
      party_pan=nullif(trim(p_header->>'party_pan'),''),
      subtotal=v_subtotal, vat_amount=v_vat, total=v_total,
      net_total=v_total, outstanding_amount=v_total,
      notes=nullif(trim(p_header->>'notes'),''),
      invoice_date_bs=coalesce(p_header->>'invoice_date_bs',''),
      due_date_bs=coalesce(p_header->>'due_date_bs',''),
      payment_status_updated_at=now()
    where id=v_id and user_id=uid;
    delete from invoice_lines where invoice_id=v_id;
  end if;

  insert into invoice_lines(
    invoice_id, description, quantity, unit, rate, amount,
    vat_rate, vat_amount, line_total, item_id, hsn_code
  )
  select v_id, trim(l->>'description'),
         round(coalesce((l->>'quantity')::numeric,1),3),
         coalesce(nullif(l->>'unit',''),'pcs'),
         round(coalesce((l->>'rate')::numeric,0),2),
         round(coalesce((l->>'quantity')::numeric,1) * coalesce((l->>'rate')::numeric,0),2),
         round(coalesce((l->>'vat_rate')::numeric,0),2),
         round(
           round(coalesce((l->>'quantity')::numeric,1) * coalesce((l->>'rate')::numeric,0),2)
           * coalesce((l->>'vat_rate')::numeric,0) / 100, 2
         ),
         round(coalesce((l->>'quantity')::numeric,1) * coalesce((l->>'rate')::numeric,0),2)
           + round(
               round(coalesce((l->>'quantity')::numeric,1) * coalesce((l->>'rate')::numeric,0),2)
               * coalesce((l->>'vat_rate')::numeric,0) / 100, 2
             ),
         nullif(l->>'item_id','')::uuid,
         nullif(l->>'hsn_code','')
  from jsonb_array_elements(p_lines) l;

  perform write_audit_log(
    case when p_invoice_id is null then 'create_draft' else 'update_draft' end,
    'invoices', v_id::text, null,
    jsonb_build_object('total',v_total,'document_status','draft')
  );
  return v_id;
end;
$$;

create or replace function save_bill_draft(
  p_header jsonb,
  p_lines jsonb,
  p_bill_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  v_id uuid := p_bill_id;
  v_num integer;
  v_fy text;
  v_subtotal numeric(14,2);
  v_vat numeric(14,2);
  v_total numeric(14,2);
  v_existing record;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'At least one bill line is required.';
  end if;
  v_fy := nullif(trim(p_header->>'fiscal_year'), '');
  if v_fy is null then raise exception 'Fiscal year is required.'; end if;
  if nullif(p_header->>'bill_date','') is null then raise exception 'Bill date is required.'; end if;
  if nullif(p_header->>'due_date','') is not null
     and (p_header->>'due_date')::date < (p_header->>'bill_date')::date then
    raise exception 'Bill due date cannot precede bill date.';
  end if;
  if nullif(trim(p_header->>'vendor_name'), '') is null then raise exception 'Vendor name is required.'; end if;
  if nullif(p_header->>'vendor_id','') is not null and not exists (
    select 1 from parties where id=(p_header->>'vendor_id')::uuid and user_id=uid
  ) then raise exception 'Vendor does not belong to this business.'; end if;
  if exists (
    select 1 from jsonb_array_elements(p_lines) l
    where nullif(trim(l->>'description'),'') is null
       or coalesce((l->>'quantity')::numeric,0) <= 0
       or coalesce((l->>'rate')::numeric,0) < 0
       or coalesce((l->>'vat_rate')::numeric,0) < 0
       or coalesce((l->>'vat_rate')::numeric,0) > 100
  ) then raise exception 'Bill lines require a description, positive quantity, non-negative rate, and VAT from 0 to 100.'; end if;
  if exists (
    select 1 from jsonb_array_elements(p_lines) l
    left join inventory_items i on i.id=nullif(l->>'item_id','')::uuid and i.user_id=uid and i.is_active=true
    where nullif(l->>'item_id','') is not null and i.id is null
  ) then raise exception 'One or more bill items do not belong to this business.'; end if;

  select
         coalesce(sum(round(coalesce((l->>'quantity')::numeric,1) * coalesce((l->>'rate')::numeric,0),2)),0),
         coalesce(sum(round(
           round(coalesce((l->>'quantity')::numeric,1) * coalesce((l->>'rate')::numeric,0),2)
           * coalesce((l->>'vat_rate')::numeric,0) / 100, 2
         )),0)
    into v_subtotal, v_vat from jsonb_array_elements(p_lines) l;
  v_total := round(v_subtotal + v_vat, 2);
  if v_total <= 0 then raise exception 'Bill total must be positive.'; end if;

  if v_id is null then
    select next_doc_number('bill', v_fy) into v_num;
    insert into purchase_bills(
      user_id, bill_number, fiscal_year, bill_date, due_date,
      vendor_id, vendor_name, vendor_address, vendor_pan, vendor_bill_ref,
      subtotal, vat_amount, total, status, document_status, notes,
      amount_paid, outstanding_amount, credited_amount, net_total,
      payment_status_updated_at
    ) values (
      uid, v_num, v_fy, (p_header->>'bill_date')::date,
      nullif(p_header->>'due_date','')::date,
      nullif(p_header->>'vendor_id','')::uuid,
      trim(p_header->>'vendor_name'), nullif(trim(p_header->>'vendor_address'),''),
      nullif(trim(p_header->>'vendor_pan'),''), nullif(trim(p_header->>'vendor_bill_ref'),''),
      v_subtotal, v_vat, v_total, 'draft', 'draft', nullif(trim(p_header->>'notes'),''),
      0, v_total, 0, v_total, now()
    ) returning id into v_id;
  else
    select * into v_existing from purchase_bills
     where id=v_id and user_id=uid for update;
    if not found then raise exception 'Bill draft not found.'; end if;
    if v_existing.document_status <> 'draft' then raise exception 'Only a draft bill can be edited.'; end if;
    if v_existing.fiscal_year <> v_fy then raise exception 'Fiscal year cannot change after a document number is assigned.'; end if;

    update purchase_bills set
      bill_date=(p_header->>'bill_date')::date,
      due_date=nullif(p_header->>'due_date','')::date,
      vendor_id=nullif(p_header->>'vendor_id','')::uuid,
      vendor_name=trim(p_header->>'vendor_name'),
      vendor_address=nullif(trim(p_header->>'vendor_address'),''),
      vendor_pan=nullif(trim(p_header->>'vendor_pan'),''),
      vendor_bill_ref=nullif(trim(p_header->>'vendor_bill_ref'),''),
      subtotal=v_subtotal, vat_amount=v_vat, total=v_total,
      net_total=v_total, outstanding_amount=v_total,
      notes=nullif(trim(p_header->>'notes'),''),
      payment_status_updated_at=now()
    where id=v_id and user_id=uid;
    delete from purchase_bill_lines where bill_id=v_id;
  end if;

  insert into purchase_bill_lines(
    bill_id, description, quantity, unit, rate, amount,
    vat_rate, vat_amount, line_total, item_id, hsn_code
  )
  select v_id, trim(l->>'description'),
         round(coalesce((l->>'quantity')::numeric,1),3),
         coalesce(nullif(l->>'unit',''),'pcs'),
         round(coalesce((l->>'rate')::numeric,0),2),
         round(coalesce((l->>'quantity')::numeric,1) * coalesce((l->>'rate')::numeric,0),2),
         round(coalesce((l->>'vat_rate')::numeric,0),2),
         round(
           round(coalesce((l->>'quantity')::numeric,1) * coalesce((l->>'rate')::numeric,0),2)
           * coalesce((l->>'vat_rate')::numeric,0) / 100, 2
         ),
         round(coalesce((l->>'quantity')::numeric,1) * coalesce((l->>'rate')::numeric,0),2)
           + round(
               round(coalesce((l->>'quantity')::numeric,1) * coalesce((l->>'rate')::numeric,0),2)
               * coalesce((l->>'vat_rate')::numeric,0) / 100, 2
             ),
         nullif(l->>'item_id','')::uuid,
         nullif(l->>'hsn_code','')
  from jsonb_array_elements(p_lines) l;

  perform write_audit_log(
    case when p_bill_id is null then 'create_draft' else 'update_draft' end,
    'purchase_bills', v_id::text, null,
    jsonb_build_object('total',v_total,'document_status','draft')
  );
  return v_id;
end;
$$;

create or replace function delete_document_draft(p_document_type text, p_document_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  v_rows integer;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  if exists (
    select 1 from document_attachments
     where user_id=uid and document_type=p_document_type and document_id=p_document_id
  ) then
    raise exception 'Delete draft attachments before deleting the draft.';
  end if;
  if p_document_type='invoice' then
    delete from invoices where id=p_document_id and user_id=uid and document_status='draft';
  elsif p_document_type='bill' then
    delete from purchase_bills where id=p_document_id and user_id=uid and document_status='draft';
  else
    raise exception 'Unsupported draft type.';
  end if;
  get diagnostics v_rows = row_count;
  if v_rows=0 then raise exception 'Draft not found or already posted.'; end if;
  delete from document_internal_notes
   where user_id=uid and document_type=p_document_type and document_id=p_document_id;
  perform write_audit_log('delete_draft', p_document_type, p_document_id::text, null, null);
end;
$$;

-- ------------------------------------------------------------
-- 6. Post existing invoice/bill drafts atomically.
-- ------------------------------------------------------------
create or replace function post_invoice_draft(p_invoice_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  h record;
  l record;
  item record;
  debtor_acct uuid;
  v_voucher_id uuid;
  v_cogs numeric(18,2) := 0;
  v_move record;
  v_lines jsonb;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  select * into h from invoices
   where id=p_invoice_id and user_id=uid for update;
  if not found then raise exception 'Invoice draft not found.'; end if;
  if h.document_status <> 'draft' then raise exception 'Only a draft invoice can be posted.'; end if;
  if h.voucher_id is not null then raise exception 'Draft invoice already has a posting voucher.'; end if;
  if h.total <= 0 then raise exception 'Invoice total must be positive.'; end if;
  if not exists(select 1 from invoice_lines where invoice_id=h.id) then raise exception 'Invoice has no lines.'; end if;

  if h.party_id is not null then
    select account_id into debtor_acct from parties where id=h.party_id and user_id=uid;
    if debtor_acct is null then raise exception 'Customer does not belong to this business.'; end if;
  else debtor_acct := resolve_system_account('ar_control'); end if;

  for l in select * from invoice_lines where invoice_id=h.id order by id
  loop
    if l.item_id is not null then
      select * into item from inventory_items
       where id=l.item_id and user_id=uid and is_active=true for update;
      if not found then raise exception 'Invoice item does not belong to this business.'; end if;
      if coalesce(item.track_inventory,true) and coalesce(item.item_type,'goods')='goods' then
        select * into v_move from apply_inventory_movement(
          l.item_id, -l.quantity, null, h.invoice_date,
          'sale', 'Invoice #'||h.invoice_number, h.id, l.id,
          'Automatic stock issue and COGS for posted invoice.'
        );
        update invoice_lines set
          inventory_unit_cost=v_move.applied_unit_cost,
          inventory_cost_amount=v_move.applied_total_cost
        where id=l.id;
        v_cogs := v_cogs + v_move.applied_total_cost;
      end if;
    end if;
  end loop;

  v_lines := jsonb_build_array(
    jsonb_build_object('account_id',debtor_acct,'debit',h.total,'credit',0,'description',h.party_name),
    jsonb_build_object('account_id',resolve_system_account('sales'),'debit',0,'credit',h.subtotal,'description','Sales')
  );
  if h.vat_amount > 0.005 then
    v_lines := v_lines || jsonb_build_array(
      jsonb_build_object('account_id',resolve_system_account('vat_payable'),'debit',0,'credit',h.vat_amount,'description','Output VAT')
    );
  end if;
  if v_cogs > 0.005 then
    v_lines := v_lines || jsonb_build_array(
      jsonb_build_object('account_id',resolve_system_account('cogs'),'debit',v_cogs,'credit',0,'description','Cost of goods sold'),
      jsonb_build_object('account_id',resolve_system_account('inventory_asset'),'debit',0,'credit',v_cogs,'description','Inventory issued')
    );
  end if;

  v_voucher_id := post_voucher('sales',h.fiscal_year,h.invoice_date,
    'Sales Invoice #'||h.invoice_number,v_lines);
  update vouchers set source_document_type='invoice', source_document_id=h.id
   where id=v_voucher_id and user_id=uid;
  update inventory_movements set voucher_id=v_voucher_id
   where user_id=uid and source_type='sale' and reference_id=h.id and voucher_id is null;
  update invoices set
    voucher_id=v_voucher_id, cogs_amount=round(v_cogs,2),
    document_status='posted', posted_at=now(), status='open',
    net_total=total, outstanding_amount=total, payment_status_updated_at=now()
  where id=h.id and user_id=uid;
  perform write_audit_log('post','invoices',h.id::text,null,
    jsonb_build_object('voucher_id',v_voucher_id,'cogs',v_cogs));
  return h.id;
end;
$$;

create or replace function post_bill_draft(p_bill_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  h record;
  l record;
  item record;
  creditor_acct uuid;
  v_voucher_id uuid;
  v_inventory numeric(18,2) := 0;
  v_expense numeric(18,2) := 0;
  v_move record;
  v_lines jsonb;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  select * into h from purchase_bills
   where id=p_bill_id and user_id=uid for update;
  if not found then raise exception 'Bill draft not found.'; end if;
  if h.document_status <> 'draft' then raise exception 'Only a draft bill can be posted.'; end if;
  if h.voucher_id is not null then raise exception 'Draft bill already has a posting voucher.'; end if;
  if h.total <= 0 then raise exception 'Bill total must be positive.'; end if;
  if not exists(select 1 from purchase_bill_lines where bill_id=h.id) then raise exception 'Bill has no lines.'; end if;

  if h.vendor_id is not null then
    select account_id into creditor_acct from parties where id=h.vendor_id and user_id=uid;
    if creditor_acct is null then raise exception 'Vendor does not belong to this business.'; end if;
  else creditor_acct := resolve_system_account('ap_control'); end if;

  for l in select * from purchase_bill_lines where bill_id=h.id order by id
  loop
    if l.item_id is not null then
      select * into item from inventory_items
       where id=l.item_id and user_id=uid and is_active=true for update;
      if not found then raise exception 'Purchase item does not belong to this business.'; end if;
      if coalesce(item.track_inventory,true) and coalesce(item.item_type,'goods')='goods' then
        select * into v_move from apply_inventory_movement(
          l.item_id, l.quantity, round(l.amount/l.quantity,6), h.bill_date,
          'purchase', 'Bill #'||h.bill_number, h.id, l.id,
          'Automatic stock receipt for posted purchase bill.'
        );
        update purchase_bill_lines set
          inventory_unit_cost=v_move.applied_unit_cost,
          inventory_cost_amount=v_move.applied_total_cost
        where id=l.id;
        v_inventory := v_inventory + v_move.applied_total_cost;
      else v_expense := v_expense + l.amount; end if;
    else v_expense := v_expense + l.amount; end if;
  end loop;
  v_expense := greatest(round(h.subtotal-v_inventory,2),0);

  v_lines := jsonb_build_array(
    jsonb_build_object('account_id',creditor_acct,'debit',0,'credit',h.total,'description',h.vendor_name)
  );
  if v_inventory > 0.005 then v_lines := v_lines || jsonb_build_array(
    jsonb_build_object('account_id',resolve_system_account('inventory_asset'),'debit',v_inventory,'credit',0,'description','Tracked inventory purchased')
  ); end if;
  if v_expense > 0.005 then v_lines := v_lines || jsonb_build_array(
    jsonb_build_object('account_id',resolve_system_account('purchase'),'debit',v_expense,'credit',0,'description','Non-inventory purchases')
  ); end if;
  if h.vat_amount > 0.005 then v_lines := v_lines || jsonb_build_array(
    jsonb_build_object('account_id',resolve_system_account('vat_receivable'),'debit',h.vat_amount,'credit',0,'description','Input VAT')
  ); end if;

  v_voucher_id := post_voucher('purchase',h.fiscal_year,h.bill_date,
    'Purchase Bill #'||h.bill_number,v_lines);
  update vouchers set source_document_type='purchase_bill', source_document_id=h.id
   where id=v_voucher_id and user_id=uid;
  update inventory_movements set voucher_id=v_voucher_id
   where user_id=uid and source_type='purchase' and reference_id=h.id and voucher_id is null;
  update purchase_bills set
    voucher_id=v_voucher_id, inventory_amount=round(v_inventory,2), expense_amount=round(v_expense,2),
    document_status='posted', posted_at=now(), status='open',
    net_total=total, outstanding_amount=total, payment_status_updated_at=now()
  where id=h.id and user_id=uid;
  perform write_audit_log('post','purchase_bills',h.id::text,null,
    jsonb_build_object('voucher_id',v_voucher_id,'inventory',v_inventory,'expense',v_expense));
  return h.id;
end;
$$;

-- Existing immediate-post API now uses the draft/post lifecycle internally.
create or replace function create_invoice_with_posting(p_header jsonb, p_lines jsonb)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_id uuid;
begin
  v_id := save_invoice_draft(p_header,p_lines,null);
  perform post_invoice_draft(v_id);
  return v_id;
end;
$$;

create or replace function create_bill_with_posting(p_header jsonb, p_lines jsonb)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_id uuid;
begin
  v_id := save_bill_draft(p_header,p_lines,null);
  perform post_bill_draft(v_id);
  return v_id;
end;
$$;

-- ------------------------------------------------------------
-- 7. Payment status refresh based on net total after credits.
-- ------------------------------------------------------------
create or replace function refresh_document_payment_status(p_doc_type text, p_doc_id uuid)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  uid uuid := auth.uid();
  v_total numeric(14,2);
  v_paid numeric(14,2);
  v_outstanding numeric(14,2);
  v_due date;
  v_lifecycle text;
  v_new_status text;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  if p_doc_type='invoice' then
    select net_total,due_date,document_status into v_total,v_due,v_lifecycle
    from invoices where id=p_doc_id and user_id=uid for update;
    if not found then raise exception 'Invoice not found.'; end if;
    select coalesce(sum(a.allocated_amount),0) into v_paid
    from payment_allocations a join document_payments p on p.id=a.payment_id
    where a.user_id=uid and a.invoice_id=p_doc_id and a.reversed_at is null and p.status<>'reversed';
  elsif p_doc_type='bill' then
    select net_total,due_date,document_status into v_total,v_due,v_lifecycle
    from purchase_bills where id=p_doc_id and user_id=uid for update;
    if not found then raise exception 'Bill not found.'; end if;
    select coalesce(sum(a.allocated_amount),0) into v_paid
    from payment_allocations a join document_payments p on p.id=a.payment_id
    where a.user_id=uid and a.bill_id=p_doc_id and a.reversed_at is null and p.status<>'reversed';
  else raise exception 'Unknown document type: %',p_doc_type; end if;

  v_paid := round(coalesce(v_paid,0),2);
  v_outstanding := greatest(round(v_total-v_paid,2),0);
  if v_lifecycle='draft' then v_new_status:='draft';
  elsif v_lifecycle='cancelled' then v_new_status:='cancelled';
  elsif v_lifecycle='credited' then v_new_status:='credited';
  elsif v_outstanding<=0.005 then v_new_status:='paid';
  elsif v_due is not null and v_due<current_date then v_new_status:='overdue';
  elsif v_paid>0.005 then v_new_status:='partial';
  else v_new_status:='open'; end if;

  if p_doc_type='invoice' then
    update invoices set amount_paid=v_paid,outstanding_amount=v_outstanding,status=v_new_status,payment_status_updated_at=now()
    where id=p_doc_id and user_id=uid;
  else
    update purchase_bills set amount_paid=v_paid,outstanding_amount=v_outstanding,status=v_new_status,payment_status_updated_at=now()
    where id=p_doc_id and user_id=uid;
  end if;
end;
$$;

-- Rebuild payment recording so credits reduce the payable/receivable ceiling.
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
set search_path=public
as $$
declare
  uid uuid := auth.uid();
  v_amount numeric(14,2):=round(coalesce(p_amount,0),2);
  v_deposit_code text:=lower(coalesce(p_deposit_code,''));
  v_cashbank uuid; v_party_acct uuid; v_voucher_id uuid; v_payment_id uuid;
  v_paid numeric(14,2); v_outstanding numeric(14,2); h record;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  if v_amount<=0 then raise exception 'Amount must be positive.'; end if;
  if p_date is null then raise exception 'Payment date is required.'; end if;
  if v_deposit_code not in ('cash','bank') then raise exception 'Payment mode must be cash or bank.'; end if;
  v_cashbank:=resolve_system_account(v_deposit_code);

  if p_doc_type='invoice' then
    select * into h from invoices where id=p_doc_id and user_id=uid for update;
    if not found then raise exception 'Invoice not found.'; end if;
    if h.document_status<>'posted' then raise exception 'Payments can only be recorded against a posted invoice.'; end if;
    select coalesce(sum(a.allocated_amount),0) into v_paid
    from payment_allocations a join document_payments p on p.id=a.payment_id
    where a.user_id=uid and a.invoice_id=p_doc_id and a.reversed_at is null and p.status<>'reversed';
    v_outstanding:=greatest(round(h.net_total-v_paid,2),0);
    if v_outstanding<=0.005 then raise exception 'Invoice is already fully settled.'; end if;
    if v_amount>v_outstanding+0.005 then raise exception 'Amount % exceeds outstanding balance %.',v_amount,v_outstanding; end if;
    if h.party_id is not null then select account_id into v_party_acct from parties where id=h.party_id and user_id=uid; end if;
    if v_party_acct is null then v_party_acct:=resolve_system_account('ar_control'); end if;
    v_voucher_id:=post_voucher('receipt',h.fiscal_year,p_date,'Receipt against Invoice #'||h.invoice_number,
      jsonb_build_array(
        jsonb_build_object('account_id',v_cashbank,'debit',v_amount,'credit',0,'description','Received'),
        jsonb_build_object('account_id',v_party_acct,'debit',0,'credit',v_amount,'description',h.party_name)
      ));
    insert into document_payments(user_id,payment_kind,payment_date,deposit_code,amount,voucher_id,reference,notes)
    values(uid,'receipt',p_date,v_deposit_code,v_amount,v_voucher_id,nullif(trim(p_reference),''),nullif(trim(p_notes),''))
    returning id into v_payment_id;
    insert into payment_allocations(user_id,payment_id,invoice_id,allocated_amount)
    values(uid,v_payment_id,p_doc_id,v_amount);
    update invoices set settlement_voucher_id=v_voucher_id where id=p_doc_id and user_id=uid;
    update vouchers set source_document_type='document_payment',source_document_id=v_payment_id where id=v_voucher_id and user_id=uid;
  elsif p_doc_type='bill' then
    select * into h from purchase_bills where id=p_doc_id and user_id=uid for update;
    if not found then raise exception 'Bill not found.'; end if;
    if h.document_status<>'posted' then raise exception 'Payments can only be recorded against a posted bill.'; end if;
    select coalesce(sum(a.allocated_amount),0) into v_paid
    from payment_allocations a join document_payments p on p.id=a.payment_id
    where a.user_id=uid and a.bill_id=p_doc_id and a.reversed_at is null and p.status<>'reversed';
    v_outstanding:=greatest(round(h.net_total-v_paid,2),0);
    if v_outstanding<=0.005 then raise exception 'Bill is already fully settled.'; end if;
    if v_amount>v_outstanding+0.005 then raise exception 'Amount % exceeds outstanding balance %.',v_amount,v_outstanding; end if;
    if h.vendor_id is not null then select account_id into v_party_acct from parties where id=h.vendor_id and user_id=uid; end if;
    if v_party_acct is null then v_party_acct:=resolve_system_account('ap_control'); end if;
    v_voucher_id:=post_voucher('payment',h.fiscal_year,p_date,'Payment against Bill #'||h.bill_number,
      jsonb_build_array(
        jsonb_build_object('account_id',v_party_acct,'debit',v_amount,'credit',0,'description',h.vendor_name),
        jsonb_build_object('account_id',v_cashbank,'debit',0,'credit',v_amount,'description','Paid')
      ));
    insert into document_payments(user_id,payment_kind,payment_date,deposit_code,amount,voucher_id,reference,notes)
    values(uid,'payment',p_date,v_deposit_code,v_amount,v_voucher_id,nullif(trim(p_reference),''),nullif(trim(p_notes),''))
    returning id into v_payment_id;
    insert into payment_allocations(user_id,payment_id,bill_id,allocated_amount)
    values(uid,v_payment_id,p_doc_id,v_amount);
    update purchase_bills set settlement_voucher_id=v_voucher_id where id=p_doc_id and user_id=uid;
    update vouchers set source_document_type='document_payment',source_document_id=v_payment_id where id=v_voucher_id and user_id=uid;
  else raise exception 'Unknown document type: %',p_doc_type; end if;

  perform refresh_document_payment_status(p_doc_type,p_doc_id);
  perform write_audit_log('create','document_payments',v_payment_id::text,null,
    jsonb_build_object('document_type',p_doc_type,'document_id',p_doc_id,'amount',v_amount,'voucher_id',v_voucher_id));
  return v_payment_id;
end;
$$;

-- ------------------------------------------------------------
-- 8. Credit note (sales return) posting.
-- ------------------------------------------------------------
create or replace function create_credit_note(p_header jsonb, p_lines jsonb)
returns uuid
language plpgsql
security definer
set search_path=public
as $$
declare
  uid uuid:=auth.uid();
  inv record; orig record; item record; l jsonb; move record;
  v_id uuid; v_line_id uuid; v_num integer; v_voucher uuid; v_party uuid;
  v_qty numeric(14,3); v_prev_qty numeric(14,3); v_amount numeric(14,2); v_vat numeric(14,2);
  v_subtotal numeric(14,2):=0; v_vat_total numeric(14,2):=0; v_total numeric(14,2):=0;
  v_inventory numeric(18,2):=0; v_available numeric(14,2); v_lines jsonb;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  if nullif(p_header->>'invoice_id','') is null then raise exception 'A credit note must be linked to an invoice.'; end if;
  if nullif(trim(p_header->>'reason'),'') is null then raise exception 'Credit note reason is required.'; end if;
  if p_lines is null or jsonb_typeof(p_lines)<>'array' or jsonb_array_length(p_lines)=0 then raise exception 'At least one credit line is required.'; end if;
  if nullif(p_header->>'cn_date','') is null then raise exception 'Credit note date is required.'; end if;

  select * into inv from invoices where id=(p_header->>'invoice_id')::uuid and user_id=uid for update;
  if not found then raise exception 'Invoice not found.'; end if;
  if inv.document_status<>'posted' then raise exception 'Credit notes can only be issued against a posted invoice.'; end if;
  if inv.voucher_id is null then raise exception 'The original invoice has no posting voucher. Correct the legacy invoice before issuing a credit note.'; end if;
  if (p_header->>'cn_date')::date < inv.invoice_date then raise exception 'Credit note date cannot precede invoice date.'; end if;
  v_available:=round(inv.total-inv.credited_amount-inv.amount_paid,2);
  if v_available<=0.005 then raise exception 'No uncredited and unpaid invoice balance remains. Reverse/refund payments first.'; end if;
  select next_doc_number('credit_note',inv.fiscal_year) into v_num;
  if inv.party_id is not null then select account_id into v_party from parties where id=inv.party_id and user_id=uid; end if;
  if v_party is null then v_party:=resolve_system_account('ar_control'); end if;

  insert into credit_notes(user_id,cn_number,fiscal_year,cn_date,invoice_id,invoice_number,
    party_id,party_name,party_address,party_pan,reason,notes,document_status)
  values(uid,v_num,inv.fiscal_year,(p_header->>'cn_date')::date,inv.id,inv.invoice_number,
    inv.party_id,inv.party_name,inv.party_address,inv.party_pan,trim(p_header->>'reason'),nullif(trim(p_header->>'notes'),''),'posted')
  returning id into v_id;

  for l in select * from jsonb_array_elements(p_lines)
  loop
    if nullif(l->>'source_line_id','') is null then raise exception 'Every credit line must reference an original invoice line.'; end if;
    select * into orig from invoice_lines where id=(l->>'source_line_id')::uuid and invoice_id=inv.id;
    if not found then raise exception 'Original invoice line not found.'; end if;
    v_qty:=round(coalesce((l->>'quantity')::numeric,0),3);
    if v_qty<=0 then raise exception 'Credit quantity must be positive.'; end if;
    select coalesce(sum(cl.quantity),0) into v_prev_qty
    from credit_note_lines cl join credit_notes cn on cn.id=cl.credit_note_id
    where cl.source_line_id=orig.id and cn.document_status='posted';
    if v_prev_qty+v_qty>orig.quantity+0.0005 then
      raise exception 'Credit quantity exceeds remaining quantity for %.',orig.description;
    end if;
    v_amount:=round(v_qty*orig.rate,2);
    v_vat:=round(v_amount*orig.vat_rate/100,2);
    insert into credit_note_lines(credit_note_id,source_line_id,item_id,description,quantity,unit,
      rate,amount,vat_rate,vat_amount,line_total)
    values(v_id,orig.id,orig.item_id,orig.description,v_qty,orig.unit,orig.rate,v_amount,orig.vat_rate,v_vat,v_amount+v_vat)
    returning id into v_line_id;
    v_subtotal:=v_subtotal+v_amount; v_vat_total:=v_vat_total+v_vat;

    if orig.item_id is not null then
      select * into item from inventory_items where id=orig.item_id and user_id=uid and is_active=true for update;
      if found and coalesce(item.track_inventory,true) and coalesce(item.item_type,'goods')='goods' then
        if orig.inventory_unit_cost is null then
          raise exception 'Original invoice line % has no Stage 3 cost snapshot. Correct this legacy return through a reviewed journal.', orig.description;
        end if;
        select * into move from apply_inventory_movement(orig.item_id,v_qty,
          orig.inventory_unit_cost,
          (p_header->>'cn_date')::date,'sales_return','Credit Note #'||v_num,v_id,v_line_id,
          'Customer return against Invoice #'||inv.invoice_number);
        update credit_note_lines set inventory_unit_cost=move.applied_unit_cost,
          inventory_cost_amount=move.applied_total_cost where id=v_line_id;
        v_inventory:=v_inventory+move.applied_total_cost;
      end if;
    end if;
  end loop;
  v_total:=round(v_subtotal+v_vat_total,2);
  if v_total<=0.005 then raise exception 'Credit note total must be positive.'; end if;
  if v_total>v_available+0.005 then raise exception 'Credit note total % exceeds available unpaid balance %.',v_total,v_available; end if;

  v_lines:=jsonb_build_array(
    jsonb_build_object('account_id',resolve_system_account('sales'),'debit',v_subtotal,'credit',0,'description','Sales return'),
    jsonb_build_object('account_id',v_party,'debit',0,'credit',v_total,'description',inv.party_name)
  );
  if v_vat_total>0.005 then v_lines:=v_lines||jsonb_build_array(
    jsonb_build_object('account_id',resolve_system_account('vat_payable'),'debit',v_vat_total,'credit',0,'description','Output VAT reversed')
  ); end if;
  if v_inventory>0.005 then v_lines:=v_lines||jsonb_build_array(
    jsonb_build_object('account_id',resolve_system_account('inventory_asset'),'debit',v_inventory,'credit',0,'description','Returned inventory'),
    jsonb_build_object('account_id',resolve_system_account('cogs'),'debit',0,'credit',v_inventory,'description','COGS reversed')
  ); end if;

  v_voucher:=post_voucher('sales',inv.fiscal_year,(p_header->>'cn_date')::date,
    'Credit Note #'||v_num||' against Invoice #'||inv.invoice_number,v_lines);
  update vouchers set source_document_type='credit_note',source_document_id=v_id where id=v_voucher and user_id=uid;
  update inventory_movements set voucher_id=v_voucher where user_id=uid and source_type='sales_return' and reference_id=v_id and voucher_id is null;
  update credit_notes set subtotal=v_subtotal,vat_amount=v_vat_total,total=v_total,
    inventory_cost_amount=v_inventory,voucher_id=v_voucher,posted_at=now() where id=v_id;
  update invoices set credited_amount=round(credited_amount+v_total,2),
    net_total=greatest(round(total-(credited_amount+v_total),2),0),
    document_status=case when total-(credited_amount+v_total)<=0.005 then 'credited' else 'posted' end
  where id=inv.id and user_id=uid;
  perform refresh_document_payment_status('invoice',inv.id);
  perform write_audit_log('create','credit_notes',v_id::text,null,
    jsonb_build_object('invoice_id',inv.id,'total',v_total,'inventory_cost',v_inventory,'voucher_id',v_voucher));
  return v_id;
end;
$$;

-- ------------------------------------------------------------
-- 9. Debit note (purchase return) posting.
-- ------------------------------------------------------------
create or replace function create_debit_note(p_header jsonb, p_lines jsonb)
returns uuid
language plpgsql
security definer
set search_path=public
as $$
declare
  uid uuid:=auth.uid();
  bill record; orig record; item record; l jsonb; move record;
  v_id uuid; v_line_id uuid; v_num integer; v_voucher uuid; v_party uuid;
  v_qty numeric(14,3); v_prev_qty numeric(14,3); v_amount numeric(14,2); v_vat numeric(14,2);
  v_subtotal numeric(14,2):=0; v_vat_total numeric(14,2):=0; v_total numeric(14,2):=0;
  v_inventory numeric(18,2):=0; v_expense numeric(18,2):=0; v_difference numeric(18,2):=0;
  v_available numeric(14,2); v_lines jsonb;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  if nullif(p_header->>'bill_id','') is null then raise exception 'A debit note must be linked to a purchase bill.'; end if;
  if nullif(trim(p_header->>'reason'),'') is null then raise exception 'Debit note reason is required.'; end if;
  if p_lines is null or jsonb_typeof(p_lines)<>'array' or jsonb_array_length(p_lines)=0 then raise exception 'At least one debit line is required.'; end if;
  if nullif(p_header->>'dn_date','') is null then raise exception 'Debit note date is required.'; end if;

  select * into bill from purchase_bills where id=(p_header->>'bill_id')::uuid and user_id=uid for update;
  if not found then raise exception 'Purchase bill not found.'; end if;
  if bill.document_status<>'posted' then raise exception 'Debit notes can only be issued against a posted bill.'; end if;
  if bill.voucher_id is null then raise exception 'The original bill has no posting voucher. Correct the legacy bill before issuing a debit note.'; end if;
  if (p_header->>'dn_date')::date < bill.bill_date then raise exception 'Debit note date cannot precede bill date.'; end if;
  v_available:=round(bill.total-bill.credited_amount-bill.amount_paid,2);
  if v_available<=0.005 then raise exception 'No uncredited and unpaid bill balance remains. Reverse/refund payments first.'; end if;
  select next_doc_number('debit_note',bill.fiscal_year) into v_num;
  if bill.vendor_id is not null then select account_id into v_party from parties where id=bill.vendor_id and user_id=uid; end if;
  if v_party is null then v_party:=resolve_system_account('ap_control'); end if;

  insert into debit_notes(user_id,dn_number,fiscal_year,dn_date,bill_id,bill_number,
    vendor_id,vendor_name,vendor_address,vendor_pan,reason,notes,document_status)
  values(uid,v_num,bill.fiscal_year,(p_header->>'dn_date')::date,bill.id,bill.bill_number,
    bill.vendor_id,bill.vendor_name,bill.vendor_address,bill.vendor_pan,trim(p_header->>'reason'),nullif(trim(p_header->>'notes'),''),'posted')
  returning id into v_id;

  for l in select * from jsonb_array_elements(p_lines)
  loop
    if nullif(l->>'source_line_id','') is null then raise exception 'Every debit line must reference an original bill line.'; end if;
    select * into orig from purchase_bill_lines where id=(l->>'source_line_id')::uuid and bill_id=bill.id;
    if not found then raise exception 'Original purchase line not found.'; end if;
    v_qty:=round(coalesce((l->>'quantity')::numeric,0),3);
    if v_qty<=0 then raise exception 'Debit note quantity must be positive.'; end if;
    select coalesce(sum(dl.quantity),0) into v_prev_qty
    from debit_note_lines dl join debit_notes dn on dn.id=dl.debit_note_id
    where dl.source_line_id=orig.id and dn.document_status='posted';
    if v_prev_qty+v_qty>orig.quantity+0.0005 then
      raise exception 'Return quantity exceeds remaining quantity for %.',orig.description;
    end if;
    v_amount:=round(v_qty*orig.rate,2);
    v_vat:=round(v_amount*orig.vat_rate/100,2);
    insert into debit_note_lines(debit_note_id,source_line_id,item_id,description,quantity,unit,
      rate,amount,vat_rate,vat_amount,line_total)
    values(v_id,orig.id,orig.item_id,orig.description,v_qty,orig.unit,orig.rate,v_amount,orig.vat_rate,v_vat,v_amount+v_vat)
    returning id into v_line_id;
    v_subtotal:=v_subtotal+v_amount; v_vat_total:=v_vat_total+v_vat;

    if orig.item_id is not null then
      select * into item from inventory_items where id=orig.item_id and user_id=uid and is_active=true for update;
      if found and coalesce(item.track_inventory,true) and coalesce(item.item_type,'goods')='goods' then
        if orig.inventory_unit_cost is null then
          raise exception 'Original purchase line % has no Stage 3 cost snapshot. Correct this legacy return through a reviewed journal.', orig.description;
        end if;
        select * into move from apply_inventory_movement(orig.item_id,-v_qty,null,
          (p_header->>'dn_date')::date,'purchase_return','Debit Note #'||v_num,v_id,v_line_id,
          'Return to vendor against Bill #'||bill.bill_number);
        update debit_note_lines set inventory_unit_cost=move.applied_unit_cost,
          inventory_cost_amount=move.applied_total_cost where id=v_line_id;
        v_inventory:=v_inventory+move.applied_total_cost;
      else v_expense:=v_expense+v_amount; end if;
    else v_expense:=v_expense+v_amount; end if;
  end loop;
  v_total:=round(v_subtotal+v_vat_total,2);
  if v_total<=0.005 then raise exception 'Debit note total must be positive.'; end if;
  if v_total>v_available+0.005 then raise exception 'Debit note total % exceeds available unpaid balance %.',v_total,v_available; end if;
  v_difference:=round(v_subtotal-v_inventory-v_expense,2);

  v_lines:=jsonb_build_array(
    jsonb_build_object('account_id',v_party,'debit',v_total,'credit',0,'description',bill.vendor_name)
  );
  if v_vat_total>0.005 then v_lines:=v_lines||jsonb_build_array(
    jsonb_build_object('account_id',resolve_system_account('vat_receivable'),'debit',0,'credit',v_vat_total,'description','Input VAT reversed')
  ); end if;
  if v_inventory>0.005 then v_lines:=v_lines||jsonb_build_array(
    jsonb_build_object('account_id',resolve_system_account('inventory_asset'),'debit',0,'credit',v_inventory,'description','Inventory returned to vendor')
  ); end if;
  if v_expense>0.005 then v_lines:=v_lines||jsonb_build_array(
    jsonb_build_object('account_id',resolve_system_account('purchase'),'debit',0,'credit',v_expense,'description','Purchase expense reversed')
  ); end if;
  if v_difference>0.005 then v_lines:=v_lines||jsonb_build_array(
    jsonb_build_object('account_id',resolve_system_account('purchase_return'),'debit',0,'credit',v_difference,'description','Purchase return valuation difference')
  ); elsif v_difference < -0.005 then v_lines:=v_lines||jsonb_build_array(
    jsonb_build_object('account_id',resolve_system_account('purchase_return'),'debit',abs(v_difference),'credit',0,'description','Purchase return valuation difference')
  ); end if;

  v_voucher:=post_voucher('purchase',bill.fiscal_year,(p_header->>'dn_date')::date,
    'Debit Note #'||v_num||' against Bill #'||bill.bill_number,v_lines);
  update vouchers set source_document_type='debit_note',source_document_id=v_id where id=v_voucher and user_id=uid;
  update inventory_movements set voucher_id=v_voucher where user_id=uid and source_type='purchase_return' and reference_id=v_id and voucher_id is null;
  update debit_notes set subtotal=v_subtotal,vat_amount=v_vat_total,total=v_total,
    inventory_cost_amount=v_inventory,expense_reversal_amount=v_expense,
    valuation_difference=v_difference,voucher_id=v_voucher,posted_at=now() where id=v_id;
  update purchase_bills set credited_amount=round(credited_amount+v_total,2),
    net_total=greatest(round(total-(credited_amount+v_total),2),0),
    document_status=case when total-(credited_amount+v_total)<=0.005 then 'credited' else 'posted' end
  where id=bill.id and user_id=uid;
  perform refresh_document_payment_status('bill',bill.id);
  perform write_audit_log('create','debit_notes',v_id::text,null,
    jsonb_build_object('bill_id',bill.id,'total',v_total,'inventory_cost',v_inventory,'valuation_difference',v_difference,'voucher_id',v_voucher));
  return v_id;
end;
$$;

-- ------------------------------------------------------------
-- 10. Controlled cancellation of source documents.
-- ------------------------------------------------------------
create or replace function cancel_invoice_document(p_invoice_id uuid,p_reason text,p_date date default current_date)
returns uuid
language plpgsql security definer set search_path=public
as $$
declare
  uid uuid:=auth.uid(); h record; l record; move record; party_acct uuid;
  v_inventory numeric(18,2):=0; v_voucher uuid; v_lines jsonb;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  if nullif(trim(coalesce(p_reason,'')),'') is null then raise exception 'Cancellation reason is required.'; end if;
  select * into h from invoices where id=p_invoice_id and user_id=uid for update;
  if not found then raise exception 'Invoice not found.'; end if;
  if h.document_status<>'posted' then raise exception 'Only a posted invoice can be cancelled.'; end if;
  if h.voucher_id is null then raise exception 'Invoice has no posting voucher and cannot be automatically reversed.'; end if;
  if h.amount_paid>0.005 then raise exception 'Reverse all receipts before cancelling this invoice.'; end if;
  if h.credited_amount>0.005 then raise exception 'Cancel linked credit notes before cancelling this invoice.'; end if;
  if p_date<h.invoice_date then raise exception 'Cancellation date cannot precede invoice date.'; end if;
  if h.party_id is not null then select account_id into party_acct from parties where id=h.party_id and user_id=uid; end if;
  if party_acct is null then party_acct:=resolve_system_account('ar_control'); end if;

  for l in select il.*, i.track_inventory, i.item_type from invoice_lines il
    join inventory_items i on i.id=il.item_id and i.user_id=uid
    where il.invoice_id=h.id and il.item_id is not null
  loop
    if coalesce(l.track_inventory,true) and coalesce(l.item_type,'goods')='goods' then
      if l.inventory_cost_amount is null or l.inventory_unit_cost is null then
        raise exception 'Invoice contains legacy inventory lines without cost snapshots. Use a reviewed correction instead of automatic cancellation.';
      end if;
      select * into move from apply_inventory_movement(l.item_id,l.quantity,l.inventory_unit_cost,p_date,
        'sale_cancel','Invoice cancellation #'||h.invoice_number,h.id,l.id,trim(p_reason));
      v_inventory:=v_inventory+move.applied_total_cost;
    end if;
  end loop;
  v_lines:=jsonb_build_array(
    jsonb_build_object('account_id',resolve_system_account('sales'),'debit',h.subtotal,'credit',0,'description','Cancelled sales'),
    jsonb_build_object('account_id',party_acct,'debit',0,'credit',h.total,'description',h.party_name)
  );
  if h.vat_amount>0.005 then v_lines:=v_lines||jsonb_build_array(
    jsonb_build_object('account_id',resolve_system_account('vat_payable'),'debit',h.vat_amount,'credit',0,'description','Output VAT reversed')
  ); end if;
  if v_inventory>0.005 then v_lines:=v_lines||jsonb_build_array(
    jsonb_build_object('account_id',resolve_system_account('inventory_asset'),'debit',v_inventory,'credit',0,'description','Cancelled sale stock restored'),
    jsonb_build_object('account_id',resolve_system_account('cogs'),'debit',0,'credit',v_inventory,'description','Cancelled COGS')
  ); end if;
  v_voucher:=post_voucher('sales',h.fiscal_year,p_date,'Cancellation of Invoice #'||h.invoice_number||': '||trim(p_reason),v_lines);
  update vouchers set source_document_type='invoice_cancellation',source_document_id=h.id,
    reversal_of_voucher_id=h.voucher_id,reversal_reason=trim(p_reason) where id=v_voucher and user_id=uid;
  update inventory_movements set voucher_id=v_voucher where user_id=uid and source_type='sale_cancel' and reference_id=h.id and voucher_id is null;
  update invoices set document_status='cancelled',status='cancelled',cancelled_at=now(),
    cancellation_reason=left(trim(p_reason),500),cancellation_voucher_id=v_voucher,
    outstanding_amount=0,payment_status_updated_at=now() where id=h.id and user_id=uid;
  perform write_audit_log('cancel','invoices',h.id::text,null,jsonb_build_object('reason',trim(p_reason),'reversal_voucher_id',v_voucher));
  return v_voucher;
end;
$$;

create or replace function cancel_bill_document(p_bill_id uuid,p_reason text,p_date date default current_date)
returns uuid
language plpgsql security definer set search_path=public
as $$
declare
  uid uuid:=auth.uid(); h record; l record; move record; party_acct uuid;
  v_inventory numeric(18,2):=0; v_expense numeric(18,2):=0; v_difference numeric(18,2); v_voucher uuid; v_lines jsonb;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  if nullif(trim(coalesce(p_reason,'')),'') is null then raise exception 'Cancellation reason is required.'; end if;
  select * into h from purchase_bills where id=p_bill_id and user_id=uid for update;
  if not found then raise exception 'Bill not found.'; end if;
  if h.document_status<>'posted' then raise exception 'Only a posted bill can be cancelled.'; end if;
  if h.voucher_id is null then raise exception 'Bill has no posting voucher and cannot be automatically reversed.'; end if;
  if h.amount_paid>0.005 then raise exception 'Reverse all payments before cancelling this bill.'; end if;
  if h.credited_amount>0.005 then raise exception 'Cancel linked debit notes before cancelling this bill.'; end if;
  if p_date<h.bill_date then raise exception 'Cancellation date cannot precede bill date.'; end if;
  if h.vendor_id is not null then select account_id into party_acct from parties where id=h.vendor_id and user_id=uid; end if;
  if party_acct is null then party_acct:=resolve_system_account('ap_control'); end if;

  for l in select bl.*, i.track_inventory, i.item_type from purchase_bill_lines bl
    left join inventory_items i on i.id=bl.item_id and i.user_id=uid
    where bl.bill_id=h.id
  loop
    if l.item_id is not null and coalesce(l.track_inventory,true) and coalesce(l.item_type,'goods')='goods' then
      if l.inventory_cost_amount is null or l.inventory_unit_cost is null then
        raise exception 'Bill contains legacy inventory lines without cost snapshots. Use a reviewed correction instead of automatic cancellation.';
      end if;
      select * into move from apply_inventory_movement(l.item_id,-l.quantity,null,p_date,
        'purchase_cancel','Bill cancellation #'||h.bill_number,h.id,l.id,trim(p_reason));
      v_inventory:=v_inventory+move.applied_total_cost;
    else v_expense:=v_expense+l.amount; end if;
  end loop;
  v_difference:=round(h.subtotal-v_inventory-v_expense,2);
  v_lines:=jsonb_build_array(
    jsonb_build_object('account_id',party_acct,'debit',h.total,'credit',0,'description',h.vendor_name)
  );
  if h.vat_amount>0.005 then v_lines:=v_lines||jsonb_build_array(
    jsonb_build_object('account_id',resolve_system_account('vat_receivable'),'debit',0,'credit',h.vat_amount,'description','Input VAT reversed')
  ); end if;
  if v_inventory>0.005 then v_lines:=v_lines||jsonb_build_array(
    jsonb_build_object('account_id',resolve_system_account('inventory_asset'),'debit',0,'credit',v_inventory,'description','Cancelled purchase stock removed')
  ); end if;
  if v_expense>0.005 then v_lines:=v_lines||jsonb_build_array(
    jsonb_build_object('account_id',resolve_system_account('purchase'),'debit',0,'credit',v_expense,'description','Purchase expense reversed')
  ); end if;
  if v_difference>0.005 then v_lines:=v_lines||jsonb_build_array(
    jsonb_build_object('account_id',resolve_system_account('purchase_return'),'debit',0,'credit',v_difference,'description','Cancellation valuation difference')
  ); elsif v_difference < -0.005 then v_lines:=v_lines||jsonb_build_array(
    jsonb_build_object('account_id',resolve_system_account('purchase_return'),'debit',abs(v_difference),'credit',0,'description','Cancellation valuation difference')
  ); end if;
  v_voucher:=post_voucher('purchase',h.fiscal_year,p_date,'Cancellation of Bill #'||h.bill_number||': '||trim(p_reason),v_lines);
  update vouchers set source_document_type='bill_cancellation',source_document_id=h.id,
    reversal_of_voucher_id=h.voucher_id,reversal_reason=trim(p_reason) where id=v_voucher and user_id=uid;
  update inventory_movements set voucher_id=v_voucher where user_id=uid and source_type='purchase_cancel' and reference_id=h.id and voucher_id is null;
  update purchase_bills set document_status='cancelled',status='cancelled',cancelled_at=now(),
    cancellation_reason=left(trim(p_reason),500),cancellation_voucher_id=v_voucher,
    outstanding_amount=0,payment_status_updated_at=now() where id=h.id and user_id=uid;
  perform write_audit_log('cancel','purchase_bills',h.id::text,null,jsonb_build_object('reason',trim(p_reason),'reversal_voucher_id',v_voucher));
  return v_voucher;
end;
$$;

-- ------------------------------------------------------------
-- 11. Controlled cancellation of credit/debit notes.
-- ------------------------------------------------------------
create or replace function cancel_credit_note(p_credit_note_id uuid,p_reason text,p_date date default current_date)
returns uuid
language plpgsql security definer set search_path=public
as $$
declare
  uid uuid:=auth.uid(); n record; inv record; l record; move record; party_acct uuid;
  v_inventory numeric(18,2):=0; v_voucher uuid; v_lines jsonb;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  if nullif(trim(coalesce(p_reason,'')),'') is null then raise exception 'Cancellation reason is required.'; end if;
  select * into n from credit_notes where id=p_credit_note_id and user_id=uid for update;
  if not found or n.document_status<>'posted' then raise exception 'Posted credit note not found.'; end if;
  if n.voucher_id is null then raise exception 'Credit note has no posting voucher and cannot be automatically reversed.'; end if;
  select * into inv from invoices where id=n.invoice_id and user_id=uid for update;
  if inv.document_status='cancelled' then raise exception 'The original invoice is cancelled.'; end if;
  if p_date<n.cn_date then raise exception 'Cancellation date cannot precede credit note date.'; end if;
  if inv.party_id is not null then select account_id into party_acct from parties where id=inv.party_id and user_id=uid; end if;
  if party_acct is null then party_acct:=resolve_system_account('ar_control'); end if;
  for l in select * from credit_note_lines where credit_note_id=n.id and item_id is not null
  loop
    if l.inventory_cost_amount is not null then
      select * into move from apply_inventory_movement(l.item_id,-l.quantity,null,p_date,
        'sales_return_cancel','Credit note cancellation #'||n.cn_number,n.id,l.id,trim(p_reason));
      v_inventory:=v_inventory+move.applied_total_cost;
    end if;
  end loop;
  v_lines:=jsonb_build_array(
    jsonb_build_object('account_id',party_acct,'debit',n.total,'credit',0,'description',n.party_name),
    jsonb_build_object('account_id',resolve_system_account('sales'),'debit',0,'credit',n.subtotal,'description','Sales return cancelled')
  );
  if n.vat_amount>0.005 then v_lines:=v_lines||jsonb_build_array(
    jsonb_build_object('account_id',resolve_system_account('vat_payable'),'debit',0,'credit',n.vat_amount,'description','Output VAT restored')
  ); end if;
  if v_inventory>0.005 then v_lines:=v_lines||jsonb_build_array(
    jsonb_build_object('account_id',resolve_system_account('cogs'),'debit',v_inventory,'credit',0,'description','COGS restored'),
    jsonb_build_object('account_id',resolve_system_account('inventory_asset'),'debit',0,'credit',v_inventory,'description','Returned stock reissued')
  ); end if;
  v_voucher:=post_voucher('sales',n.fiscal_year,p_date,'Cancellation of Credit Note #'||n.cn_number||': '||trim(p_reason),v_lines);
  update vouchers set source_document_type='credit_note_cancellation',source_document_id=n.id,
    reversal_of_voucher_id=n.voucher_id,reversal_reason=trim(p_reason) where id=v_voucher and user_id=uid;
  update inventory_movements set voucher_id=v_voucher where user_id=uid and source_type='sales_return_cancel' and reference_id=n.id and voucher_id is null;
  update credit_notes set document_status='cancelled',cancelled_at=now(),cancellation_reason=left(trim(p_reason),500),cancellation_voucher_id=v_voucher where id=n.id;
  update invoices set credited_amount=greatest(round(credited_amount-n.total,2),0),
    net_total=least(total,round(total-greatest(credited_amount-n.total,0),2)),document_status='posted'
  where id=inv.id and user_id=uid;
  perform refresh_document_payment_status('invoice',inv.id);
  perform write_audit_log('cancel','credit_notes',n.id::text,null,jsonb_build_object('reason',trim(p_reason),'reversal_voucher_id',v_voucher));
  return v_voucher;
end;
$$;

create or replace function cancel_debit_note(p_debit_note_id uuid,p_reason text,p_date date default current_date)
returns uuid
language plpgsql security definer set search_path=public
as $$
declare
  uid uuid:=auth.uid(); n record; bill record; l record; move record; party_acct uuid;
  v_inventory numeric(18,2):=0; v_voucher uuid; v_lines jsonb; v_difference numeric(18,2);
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  if nullif(trim(coalesce(p_reason,'')),'') is null then raise exception 'Cancellation reason is required.'; end if;
  select * into n from debit_notes where id=p_debit_note_id and user_id=uid for update;
  if not found or n.document_status<>'posted' then raise exception 'Posted debit note not found.'; end if;
  if n.voucher_id is null then raise exception 'Debit note has no posting voucher and cannot be automatically reversed.'; end if;
  select * into bill from purchase_bills where id=n.bill_id and user_id=uid for update;
  if bill.document_status='cancelled' then raise exception 'The original bill is cancelled.'; end if;
  if p_date<n.dn_date then raise exception 'Cancellation date cannot precede debit note date.'; end if;
  if bill.vendor_id is not null then select account_id into party_acct from parties where id=bill.vendor_id and user_id=uid; end if;
  if party_acct is null then party_acct:=resolve_system_account('ap_control'); end if;
  for l in select * from debit_note_lines where debit_note_id=n.id and item_id is not null
  loop
    if l.inventory_cost_amount is not null then
      select * into move from apply_inventory_movement(l.item_id,l.quantity,l.inventory_unit_cost,p_date,
        'purchase_return_cancel','Debit note cancellation #'||n.dn_number,n.id,l.id,trim(p_reason));
      v_inventory:=v_inventory+move.applied_total_cost;
    end if;
  end loop;
  v_difference:=round(n.subtotal-v_inventory-n.expense_reversal_amount,2);
  v_lines:=jsonb_build_array(
    jsonb_build_object('account_id',party_acct,'debit',0,'credit',n.total,'description',n.vendor_name)
  );
  if n.vat_amount>0.005 then v_lines:=v_lines||jsonb_build_array(
    jsonb_build_object('account_id',resolve_system_account('vat_receivable'),'debit',n.vat_amount,'credit',0,'description','Input VAT restored')
  ); end if;
  if v_inventory>0.005 then v_lines:=v_lines||jsonb_build_array(
    jsonb_build_object('account_id',resolve_system_account('inventory_asset'),'debit',v_inventory,'credit',0,'description','Returned stock restored')
  ); end if;
  if n.expense_reversal_amount>0.005 then v_lines:=v_lines||jsonb_build_array(
    jsonb_build_object('account_id',resolve_system_account('purchase'),'debit',n.expense_reversal_amount,'credit',0,'description','Purchase expense restored')
  ); end if;
  if v_difference>0.005 then v_lines:=v_lines||jsonb_build_array(
    jsonb_build_object('account_id',resolve_system_account('purchase_return'),'debit',v_difference,'credit',0,'description','Return difference reversed')
  ); elsif v_difference < -0.005 then v_lines:=v_lines||jsonb_build_array(
    jsonb_build_object('account_id',resolve_system_account('purchase_return'),'debit',0,'credit',abs(v_difference),'description','Return difference reversed')
  ); end if;
  v_voucher:=post_voucher('purchase',n.fiscal_year,p_date,'Cancellation of Debit Note #'||n.dn_number||': '||trim(p_reason),v_lines);
  update vouchers set source_document_type='debit_note_cancellation',source_document_id=n.id,
    reversal_of_voucher_id=n.voucher_id,reversal_reason=trim(p_reason) where id=v_voucher and user_id=uid;
  update inventory_movements set voucher_id=v_voucher where user_id=uid and source_type='purchase_return_cancel' and reference_id=n.id and voucher_id is null;
  update debit_notes set document_status='cancelled',cancelled_at=now(),cancellation_reason=left(trim(p_reason),500),cancellation_voucher_id=v_voucher where id=n.id;
  update purchase_bills set credited_amount=greatest(round(credited_amount-n.total,2),0),
    net_total=least(total,round(total-greatest(credited_amount-n.total,0),2)),document_status='posted'
  where id=bill.id and user_id=uid;
  perform refresh_document_payment_status('bill',bill.id);
  perform write_audit_log('cancel','debit_notes',n.id::text,null,jsonb_build_object('reason',trim(p_reason),'reversal_voucher_id',v_voucher));
  return v_voucher;
end;
$$;

-- ------------------------------------------------------------
-- 12. Print tracking without direct document updates.
-- ------------------------------------------------------------
create or replace function mark_invoice_printed(p_invoice_id uuid)
returns integer
language plpgsql security definer set search_path=public
as $$
declare uid uuid:=auth.uid(); v_count integer;
begin
  update invoices set reprint_count=reprint_count+1,
    is_reprint=case when reprint_count+1>1 then true else is_reprint end
  where id=p_invoice_id and user_id=uid and document_status<>'draft'
  returning reprint_count into v_count;
  if v_count is null then raise exception 'Posted invoice not found.'; end if;
  return v_count;
end;
$$;

-- ------------------------------------------------------------
-- 13. Revoke direct financial writes; trusted RPCs remain writable.
-- ------------------------------------------------------------
revoke insert, update, delete on invoices, invoice_lines, purchase_bills, purchase_bill_lines from authenticated;
revoke insert, update, delete on credit_notes, credit_note_lines, debit_notes, debit_note_lines from authenticated;
revoke insert, update, delete on document_internal_notes, document_attachments from authenticated;

grant select on credit_notes, credit_note_lines, debit_notes, debit_note_lines to authenticated;
grant select on document_internal_notes, document_attachments to authenticated;

revoke all on function assert_owned_document(text,uuid) from public;
revoke all on function add_document_internal_note(text,uuid,text) from public;
revoke all on function register_document_attachment(text,uuid,text,text,text,bigint) from public;
revoke all on function delete_document_attachment(uuid) from public;
revoke all on function save_invoice_draft(jsonb,jsonb,uuid) from public;
revoke all on function save_bill_draft(jsonb,jsonb,uuid) from public;
revoke all on function delete_document_draft(text,uuid) from public;
revoke all on function post_invoice_draft(uuid) from public;
revoke all on function post_bill_draft(uuid) from public;
revoke all on function create_invoice_with_posting(jsonb,jsonb) from public;
revoke all on function create_bill_with_posting(jsonb,jsonb) from public;
revoke all on function create_credit_note(jsonb,jsonb) from public;
revoke all on function create_debit_note(jsonb,jsonb) from public;
revoke all on function cancel_invoice_document(uuid,text,date) from public;
revoke all on function cancel_bill_document(uuid,text,date) from public;
revoke all on function cancel_credit_note(uuid,text,date) from public;
revoke all on function cancel_debit_note(uuid,text,date) from public;
revoke all on function mark_invoice_printed(uuid) from public;

-- Internal trigger/helper functions are not callable APIs.
revoke all on function link_document_payment_voucher() from public;
revoke all on function link_payment_reversal_voucher() from public;
revoke all on function link_inventory_movement_voucher() from public;
revoke all on function protect_document_identity() from public;

grant execute on function save_invoice_draft(jsonb,jsonb,uuid) to authenticated;
grant execute on function save_bill_draft(jsonb,jsonb,uuid) to authenticated;
grant execute on function delete_document_draft(text,uuid) to authenticated;
grant execute on function post_invoice_draft(uuid) to authenticated;
grant execute on function post_bill_draft(uuid) to authenticated;
grant execute on function create_invoice_with_posting(jsonb,jsonb) to authenticated;
grant execute on function create_bill_with_posting(jsonb,jsonb) to authenticated;
grant execute on function create_credit_note(jsonb,jsonb) to authenticated;
grant execute on function create_debit_note(jsonb,jsonb) to authenticated;
grant execute on function cancel_invoice_document(uuid,text,date) to authenticated;
grant execute on function cancel_bill_document(uuid,text,date) to authenticated;
grant execute on function cancel_credit_note(uuid,text,date) to authenticated;
grant execute on function cancel_debit_note(uuid,text,date) to authenticated;
grant execute on function add_document_internal_note(text,uuid,text) to authenticated;
grant execute on function register_document_attachment(text,uuid,text,text,text,bigint) to authenticated;
grant execute on function delete_document_attachment(uuid) to authenticated;
grant execute on function mark_invoice_printed(uuid) to authenticated;
grant execute on function refresh_document_payment_status(text,uuid) to authenticated;
grant execute on function record_document_payment(text,uuid,numeric,text,date,text,text) to authenticated;


-- ------------------------------------------------------------
-- 14. Lifecycle-aware dashboard figures.
-- ------------------------------------------------------------
create or replace function get_dashboard_stats()
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  uid uuid:=auth.uid(); result jsonb;
  v_cash numeric; v_receivables numeric; v_payables numeric;
  v_sales_this numeric; v_sales_last numeric; v_vat_payable numeric;
  v_stock_value numeric; v_low_stock integer; v_invoice_count integer; v_overdue_count integer;
  v_overdue_amount numeric; v_invoice_outstanding numeric; v_bill_outstanding numeric;
  this_month_start date; last_month_start date; last_month_end date;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  this_month_start:=date_trunc('month',current_date)::date;
  last_month_start:=(date_trunc('month',current_date)-interval '1 month')::date;
  last_month_end:=(this_month_start-1)::date;

  select coalesce(sum(case when a.opening_balance_type='debit' then a.opening_balance else -a.opening_balance end
    +coalesce((select sum(vl.debit-vl.credit) from voucher_lines vl join vouchers v on v.id=vl.voucher_id and v.is_void=false where vl.account_id=a.id),0)),0)
  into v_cash from accounts a where a.user_id=uid and a.is_active and a.group_name in ('Cash-in-Hand','Bank Accounts');
  select coalesce(sum(case when a.opening_balance_type='debit' then a.opening_balance else -a.opening_balance end
    +coalesce((select sum(vl.debit-vl.credit) from voucher_lines vl join vouchers v on v.id=vl.voucher_id and v.is_void=false where vl.account_id=a.id),0)),0)
  into v_receivables from accounts a where a.user_id=uid and a.is_active and a.group_name='Sundry Debtors' and a.account_type='asset';
  select coalesce(sum(-(case when a.opening_balance_type='debit' then a.opening_balance else -a.opening_balance end
    +coalesce((select sum(vl.debit-vl.credit) from voucher_lines vl join vouchers v on v.id=vl.voucher_id and v.is_void=false where vl.account_id=a.id),0))),0)
  into v_payables from accounts a where a.user_id=uid and a.is_active and a.group_name='Sundry Creditors' and a.account_type='liability';

  select
    coalesce(sum(case when invoice_date>=this_month_start then subtotal else 0 end),0)
      -coalesce((select sum(subtotal) from credit_notes where user_id=uid and document_status='posted' and cn_date>=this_month_start),0),
    coalesce(sum(case when invoice_date between last_month_start and last_month_end then subtotal else 0 end),0)
      -coalesce((select sum(subtotal) from credit_notes where user_id=uid and document_status='posted' and cn_date between last_month_start and last_month_end),0)
  into v_sales_this,v_sales_last from invoices where user_id=uid and document_status in ('posted','credited');

  select
    coalesce((select sum(vat_amount) from invoices where user_id=uid and document_status in ('posted','credited') and invoice_date>=this_month_start),0)
    -coalesce((select sum(vat_amount) from credit_notes where user_id=uid and document_status='posted' and cn_date>=this_month_start),0)
    -coalesce((select sum(vat_amount) from purchase_bills where user_id=uid and document_status in ('posted','credited') and bill_date>=this_month_start),0)
    +coalesce((select sum(vat_amount) from debit_notes where user_id=uid and document_status='posted' and dn_date>=this_month_start),0)
  into v_vat_payable;

  select coalesce(sum(inventory_value),0),count(*) filter(where current_stock<=reorder_level)::integer
  into v_stock_value,v_low_stock from inventory_items where user_id=uid and is_active and item_type='goods' and track_inventory;

  select count(*)::integer,
    count(*) filter(where due_date<current_date and outstanding_amount>0.005 and status in ('open','partial','overdue'))::integer,
    coalesce(sum(outstanding_amount) filter(where due_date<current_date and outstanding_amount>0.005 and status in ('open','partial','overdue')),0),
    coalesce(sum(outstanding_amount),0)
  into v_invoice_count,v_overdue_count,v_overdue_amount,v_invoice_outstanding
  from invoices where user_id=uid and document_status='posted';

  select coalesce(sum(outstanding_amount),0) into v_bill_outstanding
  from purchase_bills where user_id=uid and document_status='posted';

  result:=jsonb_build_object(
    'cash',v_cash,'receivables',v_receivables,'payables',v_payables,
    'sales_this',v_sales_this,'sales_last',v_sales_last,'vat_payable',v_vat_payable,
    'stock_value',v_stock_value,'low_stock',v_low_stock,'invoice_count',v_invoice_count,
    'overdue_count',v_overdue_count,'overdue_amount',v_overdue_amount,
    'invoice_outstanding',v_invoice_outstanding,'bill_outstanding',v_bill_outstanding,
    'vat_deadline',to_char(date_trunc('month',current_date)+interval '1 month'+interval '14 days','YYYY-MM-DD')
  );
  return result;
end;
$$;
revoke all on function get_dashboard_stats() from public;
grant execute on function get_dashboard_stats() to authenticated;

commit;
