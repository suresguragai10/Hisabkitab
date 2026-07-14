create table if not exists invoices (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  invoice_number integer not null,
  fiscal_year text not null,
  invoice_date date not null,
  due_date date,
  party_id uuid references parties(id),
  party_name text not null,
  party_address text,
  party_pan text,
  subtotal numeric(14,2) not null default 0,
  vat_amount numeric(14,2) not null default 0,
  total numeric(14,2) not null default 0,
  status text not null default 'draft' check (status in ('draft','sent','paid','cancelled')),
  notes text,
  created_at timestamptz not null default now()
);

create table if not exists invoice_lines (
  id uuid primary key default gen_random_uuid(),
  invoice_id uuid not null references invoices(id) on delete cascade,
  description text not null,
  quantity numeric(10,3) not null default 1,
  unit text default 'pcs',
  rate numeric(14,2) not null default 0,
  amount numeric(14,2) not null default 0,
  vat_rate numeric(5,2) not null default 13,
  vat_amount numeric(14,2) not null default 0,
  line_total numeric(14,2) not null default 0
);

alter table invoices enable row level security;
alter table invoice_lines enable row level security;

drop policy if exists "own invoices" on invoices;
create policy "own invoices" on invoices for all
  using (auth.uid() = user_id) with check (auth.uid() = user_id);

drop policy if exists "own invoice lines" on invoice_lines;
create policy "own invoice lines" on invoice_lines for all
  using (exists (select 1 from invoices i where i.id = invoice_lines.invoice_id and i.user_id = auth.uid()))
  with check (exists (select 1 from invoices i where i.id = invoice_lines.invoice_id and i.user_id = auth.uid()));

create index if not exists idx_invoices_user on invoices(user_id);
create index if not exists idx_invoice_lines_invoice on invoice_lines(invoice_id);

create or replace function next_invoice_number(p_fiscal_year text)
returns integer
language sql
security definer
set search_path = public
as $$
  select coalesce(max(invoice_number), 0) + 1
  from invoices
  where user_id = auth.uid() and fiscal_year = p_fiscal_year;
$$;

grant execute on function next_invoice_number(text) to authenticated;
