-- ============================================================
-- HisabKitab Stage 4 preflight (read-only)
-- Run before phaseP0_4_document_lifecycle.sql.
-- Every result set labelled "missing", "duplicate", or "blocking"
-- should return zero rows before the migration is applied.
-- ============================================================

-- 1. Required Stage 1-3 tables. Expected: zero rows.
with required(name) as (
  values
    ('accounts'), ('parties'), ('vouchers'), ('voucher_lines'), ('audit_log'),
    ('doc_sequences'),
    ('invoices'), ('invoice_lines'),
    ('purchase_bills'), ('purchase_bill_lines'),
    ('document_payments'), ('payment_allocations'),
    ('inventory_items'), ('inventory_movements')
)
select r.name as missing_table
from required r
where to_regclass('public.' || r.name) is null
order by r.name;

-- 2. Supabase Storage prerequisites. Expected: zero rows.
select 'storage.buckets' as missing_storage_object
where to_regclass('storage.buckets') is null
union all
select 'storage.objects'
where to_regclass('storage.objects') is null
union all
select 'storage.foldername(text)'
where to_regprocedure('storage.foldername(text)') is null;

-- 3. Required baseline columns. Expected: zero rows.
with required(table_name, column_name) as (
  values
    ('accounts','id'), ('accounts','user_id'), ('accounts','system_code'),
    ('parties','id'), ('parties','user_id'), ('parties','account_id'),
    ('vouchers','id'), ('vouchers','user_id'), ('vouchers','voucher_type'),
    ('vouchers','voucher_date'), ('vouchers','is_void'),
    ('voucher_lines','voucher_id'), ('voucher_lines','account_id'),
    ('voucher_lines','debit'), ('voucher_lines','credit'),
    ('invoices','id'), ('invoices','user_id'), ('invoices','invoice_number'),
    ('invoices','fiscal_year'), ('invoices','invoice_date'), ('invoices','due_date'),
    ('invoices','party_id'), ('invoices','subtotal'), ('invoices','vat_amount'),
    ('invoices','total'), ('invoices','status'), ('invoices','voucher_id'),
    ('invoices','amount_paid'), ('invoices','outstanding_amount'),
    ('invoices','cogs_amount'), ('invoices','created_at'),
    ('invoices','invoice_date_bs'), ('invoices','due_date_bs'),
    ('invoices','is_reprint'), ('invoices','reprint_count'),
    ('invoice_lines','id'), ('invoice_lines','invoice_id'), ('invoice_lines','item_id'),
    ('invoice_lines','description'), ('invoice_lines','quantity'), ('invoice_lines','rate'),
    ('invoice_lines','amount'), ('invoice_lines','vat_rate'), ('invoice_lines','vat_amount'),
    ('invoice_lines','line_total'), ('invoice_lines','inventory_unit_cost'),
    ('invoice_lines','inventory_cost_amount'),
    ('purchase_bills','id'), ('purchase_bills','user_id'), ('purchase_bills','bill_number'),
    ('purchase_bills','fiscal_year'), ('purchase_bills','bill_date'), ('purchase_bills','due_date'),
    ('purchase_bills','vendor_id'), ('purchase_bills','subtotal'), ('purchase_bills','vat_amount'),
    ('purchase_bills','total'), ('purchase_bills','status'), ('purchase_bills','voucher_id'),
    ('purchase_bills','amount_paid'), ('purchase_bills','outstanding_amount'),
    ('purchase_bills','inventory_amount'), ('purchase_bills','expense_amount'),
    ('purchase_bills','created_at'),
    ('purchase_bill_lines','id'), ('purchase_bill_lines','bill_id'),
    ('purchase_bill_lines','item_id'), ('purchase_bill_lines','description'),
    ('purchase_bill_lines','quantity'), ('purchase_bill_lines','rate'),
    ('purchase_bill_lines','amount'), ('purchase_bill_lines','vat_rate'),
    ('purchase_bill_lines','vat_amount'), ('purchase_bill_lines','line_total'),
    ('purchase_bill_lines','inventory_unit_cost'),
    ('purchase_bill_lines','inventory_cost_amount'),
    ('document_payments','id'), ('document_payments','user_id'),
    ('document_payments','voucher_id'), ('document_payments','status'),
    ('payment_allocations','id'), ('payment_allocations','user_id'),
    ('payment_allocations','payment_id'), ('payment_allocations','invoice_id'),
    ('payment_allocations','bill_id'), ('payment_allocations','allocated_amount'),
    ('payment_allocations','reversed_at'), ('payment_allocations','reversal_voucher_id'),
    ('inventory_items','id'), ('inventory_items','user_id'),
    ('inventory_items','track_inventory'), ('inventory_items','item_type'),
    ('inventory_items','average_cost'), ('inventory_items','inventory_value'),
    ('inventory_movements','id'), ('inventory_movements','user_id'),
    ('inventory_movements','item_id'), ('inventory_movements','source_type'),
    ('inventory_movements','source_line_id'), ('inventory_movements','reference_id'),
    ('inventory_movements','voucher_id'), ('inventory_movements','quantity_delta'),
    ('inventory_movements','unit_cost'), ('inventory_movements','total_cost')
)
select r.table_name, r.column_name as missing_column
from required r
left join information_schema.columns c
  on c.table_schema='public'
 and c.table_name=r.table_name
 and c.column_name=r.column_name
where c.column_name is null
order by r.table_name, r.column_name;

-- 4. Required function signatures. Parameter names are intentionally ignored.
--    Expected: zero rows.
with required(signature) as (
  values
    ('public.post_voucher(text,text,date,text,jsonb)'),
    ('public.next_doc_number(text,text)'),
    ('public.write_audit_log(text,text,text,jsonb,jsonb)'),
    ('public.resolve_system_account(text)'),
    ('public.apply_inventory_movement(uuid,numeric,numeric,date,text,text,uuid,uuid,text)'),
    ('public.record_document_payment(text,uuid,numeric,text,date,text,text)'),
    ('public.refresh_document_payment_status(text,uuid)'),
    ('public.refresh_document_payment_statuses()'),
    ('public.reverse_payment_allocation(uuid,text,date)')
)
select signature as missing_function
from required
where to_regprocedure(signature) is null
order by signature;

-- 5. Duplicate source-document numbers would block the unique indexes.
--    Expected: zero rows.
select 'invoice' as duplicate_type, user_id, fiscal_year,
       invoice_number as document_number, count(*) as duplicate_count
from invoices
group by user_id, fiscal_year, invoice_number
having count(*) > 1
union all
select 'purchase_bill', user_id, fiscal_year, bill_number, count(*)
from purchase_bills
group by user_id, fiscal_year, bill_number
having count(*) > 1
order by duplicate_type, user_id, fiscal_year, document_number;

-- 6. Posted/active legacy documents without a posting voucher cannot be safely
--    cancelled or credited automatically. Expected: zero rows, or resolve each
--    row through the reviewed Stage 1/3 backfill process before Stage 4 use.
select 'invoice' as blocking_type, id, fiscal_year,
       invoice_number as document_number, status, total
from invoices
where status not in ('draft','cancelled') and voucher_id is null
union all
select 'purchase_bill', id, fiscal_year, bill_number, status, total
from purchase_bills
where status not in ('draft','cancelled') and voucher_id is null
order by blocking_type, fiscal_year, document_number;

-- 7. Invalid source totals or payment summaries. Expected: zero rows.
select 'invoice' as blocking_type, id, total, amount_paid, outstanding_amount
from invoices
where total < 0 or amount_paid < 0 or outstanding_amount < 0
   or amount_paid > total + 0.01
union all
select 'purchase_bill', id, total, amount_paid, outstanding_amount
from purchase_bills
where total < 0 or amount_paid < 0 or outstanding_amount < 0
   or amount_paid > total + 0.01;

-- 8. If note/activity tables already exist from a hand-created prototype,
--    list any columns Stage 4 requires but the existing table lacks.
--    Expected: zero rows. Missing tables themselves are fine; Stage 4 creates them.
with required(table_name, column_name) as (
  values
    ('credit_notes','id'), ('credit_notes','user_id'), ('credit_notes','cn_number'),
    ('credit_notes','fiscal_year'), ('credit_notes','cn_date'), ('credit_notes','invoice_id'),
    ('credit_notes','party_name'), ('credit_notes','subtotal'), ('credit_notes','vat_amount'),
    ('credit_notes','total'), ('credit_notes','reason'), ('credit_notes','created_at'),
    ('credit_note_lines','id'), ('credit_note_lines','credit_note_id'),
    ('credit_note_lines','description'), ('credit_note_lines','quantity'),
    ('credit_note_lines','rate'), ('credit_note_lines','amount'),
    ('credit_note_lines','vat_rate'), ('credit_note_lines','vat_amount'),
    ('credit_note_lines','line_total'),
    ('debit_notes','id'), ('debit_notes','user_id'), ('debit_notes','dn_number'),
    ('debit_notes','fiscal_year'), ('debit_notes','dn_date'), ('debit_notes','bill_id'),
    ('debit_notes','vendor_name'), ('debit_notes','subtotal'), ('debit_notes','vat_amount'),
    ('debit_notes','total'), ('debit_notes','reason'), ('debit_notes','created_at'),
    ('debit_note_lines','id'), ('debit_note_lines','debit_note_id'),
    ('debit_note_lines','description'), ('debit_note_lines','quantity'),
    ('debit_note_lines','rate'), ('debit_note_lines','amount'),
    ('debit_note_lines','vat_rate'), ('debit_note_lines','vat_amount'),
    ('debit_note_lines','line_total'),
    ('document_internal_notes','id'), ('document_internal_notes','user_id'),
    ('document_internal_notes','document_type'), ('document_internal_notes','document_id'),
    ('document_internal_notes','note_text'), ('document_internal_notes','created_at'),
    ('document_attachments','id'), ('document_attachments','user_id'),
    ('document_attachments','document_type'), ('document_attachments','document_id'),
    ('document_attachments','storage_path'), ('document_attachments','file_name'),
    ('document_attachments','created_at')
)
select r.table_name, r.column_name as incompatible_existing_table_missing_column
from required r
left join information_schema.columns c
  on c.table_schema='public' and c.table_name=r.table_name and c.column_name=r.column_name
where to_regclass('public.' || r.table_name) is not null
  and c.column_name is null
order by r.table_name, r.column_name;

-- 9. Informational: existing optional Stage 4 tables and approximate row counts.
select c.relname as existing_optional_table,
       greatest(c.reltuples::bigint, 0) as approximate_rows
from pg_class c
join pg_namespace n on n.oid=c.relnamespace
where n.nspname='public'
  and c.relkind='r'
  and c.relname in (
    'credit_notes','credit_note_lines','debit_notes','debit_note_lines',
    'document_internal_notes','document_attachments'
  )
order by c.relname;
