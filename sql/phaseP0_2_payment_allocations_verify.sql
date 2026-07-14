-- HisabKitab Stage 2 verification queries
-- Run after phaseP0_2_payment_allocations.sql.

-- 1. Required tables and summary columns.
select
  to_regclass('public.document_payments') as document_payments,
  to_regclass('public.payment_allocations') as payment_allocations;

select table_name, column_name, data_type
from information_schema.columns
where table_schema = 'public'
  and table_name in ('invoices', 'purchase_bills')
  and column_name in ('amount_paid', 'outstanding_amount', 'payment_status_updated_at')
order by table_name, column_name;

-- 2. Required functions.
select
  proname as function_name,
  pg_get_function_identity_arguments(oid) as arguments
from pg_proc
where proname in (
  'record_document_payment',
  'settle_document',
  'get_payment_history',
  'reverse_payment_allocation',
  'refresh_document_payment_status',
  'refresh_document_payment_statuses'
)
order by proname, arguments;

-- 3. Invalid statuses should return zero rows.
select 'invoices' as source, id, status
from invoices
where status not in ('draft','open','partial','paid','overdue','cancelled','credited')
union all
select 'purchase_bills', id, status
from purchase_bills
where status not in ('draft','open','partial','paid','overdue','cancelled','credited');

-- 4. Cached summaries must reconcile to active allocations.
with invoice_allocations as (
  select i.id,
         least(i.total, coalesce(sum(a.allocated_amount) filter (where a.reversed_at is null), 0)) as calculated_paid
  from invoices i
  left join payment_allocations a on a.invoice_id = i.id
  group by i.id, i.total
)
select i.id, i.total, i.amount_paid, ia.calculated_paid,
       i.outstanding_amount, greatest(i.total - ia.calculated_paid, 0) as calculated_outstanding
from invoices i
join invoice_allocations ia on ia.id = i.id
where abs(i.amount_paid - ia.calculated_paid) > 0.005
   or abs(i.outstanding_amount - greatest(i.total - ia.calculated_paid, 0)) > 0.005;

with bill_allocations as (
  select b.id,
         least(b.total, coalesce(sum(a.allocated_amount) filter (where a.reversed_at is null), 0)) as calculated_paid
  from purchase_bills b
  left join payment_allocations a on a.bill_id = b.id
  group by b.id, b.total
)
select b.id, b.total, b.amount_paid, ba.calculated_paid,
       b.outstanding_amount, greatest(b.total - ba.calculated_paid, 0) as calculated_outstanding
from purchase_bills b
join bill_allocations ba on ba.id = b.id
where abs(b.amount_paid - ba.calculated_paid) > 0.005
   or abs(b.outstanding_amount - greatest(b.total - ba.calculated_paid, 0)) > 0.005;

-- 5. Allocation ownership and amount integrity should return zero rows.
select a.id, a.user_id as allocation_user, p.user_id as payment_user,
       i.user_id as invoice_user, b.user_id as bill_user,
       a.allocated_amount
from payment_allocations a
join document_payments p on p.id = a.payment_id
left join invoices i on i.id = a.invoice_id
left join purchase_bills b on b.id = a.bill_id
where a.allocated_amount <= 0
   or a.user_id <> p.user_id
   or (a.invoice_id is not null and a.user_id <> i.user_id)
   or (a.bill_id is not null and a.user_id <> b.user_id);

-- 6. Legacy rows requiring evidence review.
select id, payment_kind, payment_date, deposit_code, amount, voucher_id, notes
from document_payments
where is_legacy = true
order by created_at;
