-- HisabKitab Stage 7a preflight — Fiscal period locking.
-- Resolve every returned blocking row before running phaseP0_7_period_locks.sql.

-- ------------------------------------------------------------
-- 1. Tables this stage adds triggers to must already exist.
-- ------------------------------------------------------------
select 'missing_table' issue_type, x.name object_name, 'Required before Stage 7' details
from (values
 ('vouchers'),('voucher_lines'),('invoices'),('invoice_lines'),
 ('purchase_bills'),('purchase_bill_lines'),
 ('credit_notes'),('credit_note_lines'),('debit_notes'),('debit_note_lines'),
 ('document_payments'),('payment_allocations'),('inventory_movements')
) x(name)
where to_regclass('public.'||x.name) is null;

-- ------------------------------------------------------------
-- 2. Date/owner columns the triggers read must already exist.
-- ------------------------------------------------------------
select 'missing_column' issue_type, x.table_name||'.'||x.column_name object_name, 'Required before Stage 7' details
from (values
 ('vouchers','voucher_date'),('vouchers','user_id'),
 ('invoices','invoice_date'),('invoices','user_id'),
 ('purchase_bills','bill_date'),('purchase_bills','user_id'),
 ('credit_notes','cn_date'),('credit_notes','user_id'),
 ('debit_notes','dn_date'),('debit_notes','user_id'),
 ('document_payments','payment_date'),('document_payments','user_id'),
 ('inventory_movements','movement_date'),('inventory_movements','user_id'),
 ('voucher_lines','voucher_id'),
 ('invoice_lines','invoice_id'),
 ('purchase_bill_lines','bill_id'),
 ('credit_note_lines','credit_note_id'),
 ('debit_note_lines','debit_note_id'),
 ('payment_allocations','payment_id')
) x(table_name,column_name)
where not exists (
  select 1 from information_schema.columns c
  where c.table_schema='public' and c.table_name=x.table_name and c.column_name=x.column_name
);

-- ------------------------------------------------------------
-- 3. Existing rows with a NULL date/owner would silently bypass
--    the lock check (the guard only ever inspects non-null dates).
-- ------------------------------------------------------------
select 'null_date_on_existing_row' issue_type, 'vouchers' object_name, count(*)::text||' rows' details
from vouchers where voucher_date is null or user_id is null having count(*)>0
union all
select 'null_date_on_existing_row','invoices',count(*)::text||' rows'
from invoices where invoice_date is null or user_id is null having count(*)>0
union all
select 'null_date_on_existing_row','purchase_bills',count(*)::text||' rows'
from purchase_bills where bill_date is null or user_id is null having count(*)>0
union all
select 'null_date_on_existing_row','credit_notes',count(*)::text||' rows'
from credit_notes where cn_date is null or user_id is null having count(*)>0
union all
select 'null_date_on_existing_row','debit_notes',count(*)::text||' rows'
from debit_notes where dn_date is null or user_id is null having count(*)>0
union all
select 'null_date_on_existing_row','document_payments',count(*)::text||' rows'
from document_payments where payment_date is null or user_id is null having count(*)>0
union all
select 'null_date_on_existing_row','inventory_movements',count(*)::text||' rows'
from inventory_movements where movement_date is null or user_id is null having count(*)>0;

-- ------------------------------------------------------------
-- 4. The overlap-prevention constraint needs the btree_gist
--    extension. Confirm it is installable in this database.
-- ------------------------------------------------------------
select 'extension_unavailable' issue_type, 'btree_gist' object_name, 'Required for overlap prevention' details
where not exists (select 1 from pg_available_extensions where name = 'btree_gist');

-- ------------------------------------------------------------
-- 5. Informational only — objects this stage is about to create.
--    Non-empty results here mean a previous partial run exists;
--    review before re-running phaseP0_7_period_locks.sql.
-- ------------------------------------------------------------
select 'object_already_exists' issue_type, x.name object_name, 'Review before re-running Stage 7' details
from (values
 ('fiscal_periods'),('fiscal_period_lock_history')
) x(name)
where to_regclass('public.'||x.name) is not null;

select 'function_already_exists' issue_type, p.proname object_name, 'Review before re-running Stage 7' details
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.proname in (
 'assert_period_not_locked','list_fiscal_periods','create_fiscal_periods','set_period_lock',
 'trg_check_period_lock_vouchers','trg_check_period_lock_voucher_lines',
 'trg_check_period_lock_invoices','trg_check_period_lock_invoice_lines',
 'trg_check_period_lock_purchase_bills','trg_check_period_lock_purchase_bill_lines',
 'trg_check_period_lock_credit_notes','trg_check_period_lock_credit_note_lines',
 'trg_check_period_lock_debit_notes','trg_check_period_lock_debit_note_lines',
 'trg_check_period_lock_document_payments','trg_check_period_lock_payment_allocations',
 'trg_check_period_lock_inventory_movements'
);
