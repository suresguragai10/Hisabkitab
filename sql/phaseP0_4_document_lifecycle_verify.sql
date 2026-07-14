-- ============================================================
-- HisabKitab Stage 4 verification (read-only)
-- Run after phaseP0_4_document_lifecycle.sql.
-- Queries marked "Expected: zero rows" are release gates.
-- ============================================================

-- 1. Lifecycle/source-link columns installed.
select table_name, column_name, data_type, is_nullable
from information_schema.columns
where table_schema='public' and (
  (table_name in ('invoices','purchase_bills') and column_name in (
    'document_status','posted_at','cancelled_at','cancellation_reason',
    'cancellation_voucher_id','credited_amount','net_total'
  ))
  or (table_name='vouchers' and column_name in (
    'source_document_type','source_document_id','reversal_of_voucher_id','reversal_reason'
  ))
)
order by table_name, column_name;

-- 2. Stage 4 tables installed.
select table_name
from information_schema.tables
where table_schema='public'
  and table_name in (
    'credit_notes','credit_note_lines','debit_notes','debit_note_lines',
    'document_internal_notes','document_attachments'
  )
order by table_name;

-- 3. Stage 4 RPC signatures installed.
select p.proname as function_name,
       pg_get_function_identity_arguments(p.oid) as arguments,
       pg_get_function_result(p.oid) as result_type
from pg_proc p
join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.proname in (
  'save_invoice_draft','save_bill_draft','delete_document_draft',
  'post_invoice_draft','post_bill_draft',
  'create_invoice_with_posting','create_bill_with_posting',
  'create_credit_note','create_debit_note',
  'cancel_invoice_document','cancel_bill_document',
  'cancel_credit_note','cancel_debit_note',
  'add_document_internal_note','register_document_attachment',
  'delete_document_attachment','mark_invoice_printed'
)
order by p.proname, arguments;

-- 4. Required unique indexes and source-link triggers.
select schemaname, tablename, indexname
from pg_indexes
where schemaname='public' and indexname in (
  'uq_invoice_number_fy','uq_bill_number_fy',
  'uq_credit_note_number_fy','uq_debit_note_number_fy',
  'idx_vouchers_source_document','idx_vouchers_reversal'
)
order by indexname;

select event_object_table as table_name, trigger_name,
       action_timing, event_manipulation
from information_schema.triggers
where trigger_schema='public' and trigger_name in (
  'trg_invoice_identity','trg_bill_identity',
  'trg_credit_note_identity','trg_debit_note_identity',
  'trg_link_document_payment_voucher',
  'trg_link_payment_reversal_voucher',
  'trg_link_inventory_movement_voucher'
)
order by table_name, trigger_name, event_manipulation;

-- 5. Invalid lifecycle/amount states. Expected: zero rows.
select 'invoice' as invalid_type, id, document_status, status,
       total, credited_amount, net_total, amount_paid, outstanding_amount
from invoices
where document_status not in ('draft','posted','cancelled','credited')
   or credited_amount < -0.005
   or net_total < -0.005
   or abs(net_total-greatest(total-credited_amount,0)) > 0.01
   or amount_paid < -0.005
   or outstanding_amount < -0.005
   or (document_status <> 'cancelled'
       and abs(outstanding_amount-greatest(net_total-amount_paid,0)) > 0.01)
union all
select 'purchase_bill', id, document_status, status,
       total, credited_amount, net_total, amount_paid, outstanding_amount
from purchase_bills
where document_status not in ('draft','posted','cancelled','credited')
   or credited_amount < -0.005
   or net_total < -0.005
   or abs(net_total-greatest(total-credited_amount,0)) > 0.01
   or amount_paid < -0.005
   or outstanding_amount < -0.005
   or (document_status <> 'cancelled'
       and abs(outstanding_amount-greatest(net_total-amount_paid,0)) > 0.01);

-- 6. Draft/posting integrity. Expected: zero rows.
select 'invoice_draft_has_voucher' as invalid_type, id, voucher_id
from invoices where document_status='draft' and voucher_id is not null
union all
select 'invoice_posted_missing_voucher', id, voucher_id
from invoices where document_status in ('posted','credited') and voucher_id is null
union all
select 'bill_draft_has_voucher', id, voucher_id
from purchase_bills where document_status='draft' and voucher_id is not null
union all
select 'bill_posted_missing_voucher', id, voucher_id
from purchase_bills where document_status in ('posted','credited') and voucher_id is null
union all
select 'credit_note_missing_voucher', id, voucher_id
from credit_notes where document_status='posted' and voucher_id is null
union all
select 'debit_note_missing_voucher', id, voucher_id
from debit_notes where document_status='posted' and voucher_id is null;

-- 7. Duplicate immutable numbers. Expected: zero rows.
select 'invoice' as duplicate_type, user_id, fiscal_year,
       invoice_number as document_number, count(*) as duplicate_count
from invoices group by user_id,fiscal_year,invoice_number having count(*)>1
union all
select 'purchase_bill', user_id, fiscal_year, bill_number, count(*)
from purchase_bills group by user_id,fiscal_year,bill_number having count(*)>1
union all
select 'credit_note', user_id, fiscal_year, cn_number, count(*)
from credit_notes group by user_id,fiscal_year,cn_number having count(*)>1
union all
select 'debit_note', user_id, fiscal_year, dn_number, count(*)
from debit_notes group by user_id,fiscal_year,dn_number having count(*)>1;

-- 8. Primary vouchers missing/mismatching their source link. Expected: zero rows.
select 'invoice' as invalid_type, i.id, i.voucher_id,
       v.source_document_type, v.source_document_id
from invoices i
join vouchers v on v.id=i.voucher_id
where i.document_status in ('posted','credited')
  and (v.source_document_type is distinct from 'invoice' or v.source_document_id is distinct from i.id)
union all
select 'purchase_bill', b.id, b.voucher_id,
       v.source_document_type, v.source_document_id
from purchase_bills b
join vouchers v on v.id=b.voucher_id
where b.document_status in ('posted','credited')
  and (v.source_document_type is distinct from 'purchase_bill' or v.source_document_id is distinct from b.id)
union all
select 'credit_note', n.id, n.voucher_id,
       v.source_document_type, v.source_document_id
from credit_notes n
join vouchers v on v.id=n.voucher_id
where n.document_status='posted'
  and (v.source_document_type is distinct from 'credit_note' or v.source_document_id is distinct from n.id)
union all
select 'debit_note', n.id, n.voucher_id,
       v.source_document_type, v.source_document_id
from debit_notes n
join vouchers v on v.id=n.voucher_id
where n.document_status='posted'
  and (v.source_document_type is distinct from 'debit_note' or v.source_document_id is distinct from n.id);

-- 9. Cancellation vouchers must point to the original voucher. Expected: zero rows.
select 'invoice' as invalid_type, i.id, i.voucher_id, i.cancellation_voucher_id,
       v.reversal_of_voucher_id
from invoices i
left join vouchers v on v.id=i.cancellation_voucher_id
where i.document_status='cancelled'
  and (i.cancellation_voucher_id is null or v.reversal_of_voucher_id is distinct from i.voucher_id)
union all
select 'purchase_bill', b.id, b.voucher_id, b.cancellation_voucher_id,
       v.reversal_of_voucher_id
from purchase_bills b
left join vouchers v on v.id=b.cancellation_voucher_id
where b.document_status='cancelled'
  and (b.cancellation_voucher_id is null or v.reversal_of_voucher_id is distinct from b.voucher_id)
union all
select 'credit_note', n.id, n.voucher_id, n.cancellation_voucher_id,
       v.reversal_of_voucher_id
from credit_notes n
left join vouchers v on v.id=n.cancellation_voucher_id
where n.document_status='cancelled'
  and (n.cancellation_voucher_id is null or v.reversal_of_voucher_id is distinct from n.voucher_id)
union all
select 'debit_note', n.id, n.voucher_id, n.cancellation_voucher_id,
       v.reversal_of_voucher_id
from debit_notes n
left join vouchers v on v.id=n.cancellation_voucher_id
where n.document_status='cancelled'
  and (n.cancellation_voucher_id is null or v.reversal_of_voucher_id is distinct from n.voucher_id);

-- 10. Credited amounts must equal active notes. Expected: zero rows.
with invoice_credits as (
  select i.id, i.credited_amount,
         coalesce(sum(n.total) filter(where n.document_status='posted'),0) as note_total
  from invoices i left join credit_notes n on n.invoice_id=i.id
  group by i.id,i.credited_amount
), bill_credits as (
  select b.id, b.credited_amount,
         coalesce(sum(n.total) filter(where n.document_status='posted'),0) as note_total
  from purchase_bills b left join debit_notes n on n.bill_id=b.id
  group by b.id,b.credited_amount
)
select 'invoice' as invalid_type, id, credited_amount, note_total
from invoice_credits where abs(credited_amount-note_total)>0.01
union all
select 'purchase_bill', id, credited_amount, note_total
from bill_credits where abs(credited_amount-note_total)>0.01;

-- 11. Cached paid/outstanding summaries versus active allocations.
--     Expected: zero rows.
with invoice_paid as (
  select i.id, i.amount_paid, i.outstanding_amount, i.net_total,
         coalesce(sum(a.allocated_amount) filter(
           where a.reversed_at is null and p.status<>'reversed'
         ),0) as allocation_total
  from invoices i
  left join payment_allocations a on a.invoice_id=i.id
  left join document_payments p on p.id=a.payment_id
  group by i.id,i.amount_paid,i.outstanding_amount,i.net_total
), bill_paid as (
  select b.id, b.amount_paid, b.outstanding_amount, b.net_total,
         coalesce(sum(a.allocated_amount) filter(
           where a.reversed_at is null and p.status<>'reversed'
         ),0) as allocation_total
  from purchase_bills b
  left join payment_allocations a on a.bill_id=b.id
  left join document_payments p on p.id=a.payment_id
  group by b.id,b.amount_paid,b.outstanding_amount,b.net_total
)
select 'invoice' as invalid_type, id, amount_paid, allocation_total,
       outstanding_amount, greatest(net_total-allocation_total,0) as expected_outstanding
from invoice_paid
where abs(amount_paid-allocation_total)>0.01
   or abs(outstanding_amount-greatest(net_total-allocation_total,0))>0.01
union all
select 'purchase_bill', id, amount_paid, allocation_total,
       outstanding_amount, greatest(net_total-allocation_total,0)
from bill_paid
where abs(amount_paid-allocation_total)>0.01
   or abs(outstanding_amount-greatest(net_total-allocation_total,0))>0.01;

-- 12. Return quantities exceeding original quantities. Expected: zero rows.
select 'credit_note_line' as invalid_type, il.id as source_line_id,
       il.quantity as original_quantity,
       sum(cl.quantity) as active_return_quantity
from invoice_lines il
join credit_note_lines cl on cl.source_line_id=il.id
join credit_notes cn on cn.id=cl.credit_note_id and cn.document_status='posted'
group by il.id,il.quantity
having sum(cl.quantity)>il.quantity+0.0005
union all
select 'debit_note_line', bl.id, bl.quantity, sum(dl.quantity)
from purchase_bill_lines bl
join debit_note_lines dl on dl.source_line_id=bl.id
join debit_notes dn on dn.id=dl.debit_note_id and dn.document_status='posted'
group by bl.id,bl.quantity
having sum(dl.quantity)>bl.quantity+0.0005;

-- 13. Stage 4 vouchers must balance. Expected: zero rows.
select v.id, v.source_document_type,
       round(sum(vl.debit),2) as total_debit,
       round(sum(vl.credit),2) as total_credit
from vouchers v
join voucher_lines vl on vl.voucher_id=v.id
where v.source_document_type in (
  'invoice','purchase_bill','credit_note','debit_note',
  'invoice_cancellation','bill_cancellation',
  'credit_note_cancellation','debit_note_cancellation',
  'document_payment','payment_allocation_reversal','inventory_movement'
)
group by v.id,v.source_document_type
having abs(sum(vl.debit)-sum(vl.credit))>0.005;

-- 14. Return/cancellation stock movements missing vouchers. Expected: zero rows.
select id, source_type, reference_id, source_line_id
from inventory_movements
where source_type in (
  'sales_return','purchase_return','sale_cancel','purchase_cancel',
  'sales_return_cancel','purchase_return_cancel'
) and voucher_id is null;

-- 15. Attachment metadata ownership/path consistency. Expected: zero rows.
select id, user_id, storage_path
from document_attachments
where split_part(storage_path,'/',1)<>user_id::text
   or size_bytes<0
   or size_bytes>20971520;

-- 16. Private storage bucket and policies.
select id, name, public, file_size_limit, allowed_mime_types
from storage.buckets
where id='document-attachments';

select policyname, cmd, roles, qual, with_check
from pg_policies
where schemaname='storage' and tablename='objects'
  and policyname in (
    'document attachment owner read',
    'document attachment owner upload',
    'document attachment owner delete'
  )
order by policyname;

-- 17. Direct financial table writes must not be granted to authenticated.
--     Expected: every value false.
select
  has_table_privilege('authenticated','public.invoices','INSERT') as invoice_insert,
  has_table_privilege('authenticated','public.invoices','UPDATE') as invoice_update,
  has_table_privilege('authenticated','public.invoices','DELETE') as invoice_delete,
  has_table_privilege('authenticated','public.purchase_bills','INSERT') as bill_insert,
  has_table_privilege('authenticated','public.purchase_bills','UPDATE') as bill_update,
  has_table_privilege('authenticated','public.purchase_bills','DELETE') as bill_delete,
  has_table_privilege('authenticated','public.credit_notes','INSERT') as credit_note_insert,
  has_table_privilege('authenticated','public.debit_notes','INSERT') as debit_note_insert;

-- 18. Stage 4 RPCs must not be executable by PUBLIC. Expected: zero rows.
select routine_name, grantee, privilege_type
from information_schema.routine_privileges
where routine_schema='public' and grantee='PUBLIC'
  and routine_name in (
    'save_invoice_draft','save_bill_draft','delete_document_draft',
    'post_invoice_draft','post_bill_draft','create_credit_note','create_debit_note',
    'cancel_invoice_document','cancel_bill_document',
    'cancel_credit_note','cancel_debit_note',
    'add_document_internal_note','register_document_attachment',
    'delete_document_attachment','mark_invoice_printed'
  )
order by routine_name;
