-- HisabKitab Stage 7a verification.
-- Run after phaseP0_7_period_locks.sql. Every check should return
-- either zero rows (for the "problem" queries) or the expected
-- object list (for the inventory queries) — review anything else.

-- ------------------------------------------------------------
-- 1. New tables exist with the expected columns.
-- ------------------------------------------------------------
select 'missing_column' issue_type, x.table_name||'.'||x.column_name object_name, 'Expected after Stage 7' details
from (values
 ('fiscal_periods','user_id'),('fiscal_periods','fiscal_year'),('fiscal_periods','period_label'),
 ('fiscal_periods','from_date'),('fiscal_periods','to_date'),('fiscal_periods','is_locked'),
 ('fiscal_periods','locked_at'),('fiscal_periods','locked_by'),
 ('fiscal_period_lock_history','period_id'),('fiscal_period_lock_history','changed_by'),
 ('fiscal_period_lock_history','action'),('fiscal_period_lock_history','previous_status'),
 ('fiscal_period_lock_history','new_status'),('fiscal_period_lock_history','reason'),
 ('fiscal_period_lock_history','changed_at')
) x(table_name,column_name)
where not exists (
  select 1 from information_schema.columns c
  where c.table_schema='public' and c.table_name=x.table_name and c.column_name=x.column_name
);

-- ------------------------------------------------------------
-- 2. The overlap-prevention exclusion constraint exists.
-- ------------------------------------------------------------
select 'missing_overlap_constraint' issue_type, 'fiscal_periods' object_name, 'Expected after Stage 7' details
where not exists (
  select 1 from pg_constraint
  where conname = 'fiscal_periods_no_overlap' and contype = 'x'
);

-- ------------------------------------------------------------
-- 3. Every ledger table has its lock-enforcing trigger attached.
-- ------------------------------------------------------------
select 'missing_trigger' issue_type, x.table_name||'.'||x.trigger_name object_name, 'Expected after Stage 7' details
from (values
 ('vouchers','trg_period_lock_vouchers'),
 ('voucher_lines','trg_period_lock_voucher_lines'),
 ('invoices','trg_period_lock_invoices'),
 ('invoice_lines','trg_period_lock_invoice_lines'),
 ('purchase_bills','trg_period_lock_purchase_bills'),
 ('purchase_bill_lines','trg_period_lock_purchase_bill_lines'),
 ('credit_notes','trg_period_lock_credit_notes'),
 ('credit_note_lines','trg_period_lock_credit_note_lines'),
 ('debit_notes','trg_period_lock_debit_notes'),
 ('debit_note_lines','trg_period_lock_debit_note_lines'),
 ('document_payments','trg_period_lock_document_payments'),
 ('payment_allocations','trg_period_lock_payment_allocations'),
 ('inventory_movements','trg_period_lock_inventory_movements')
) x(table_name,trigger_name)
where not exists (
  select 1 from pg_trigger t
  join pg_class c on c.oid = t.tgrelid
  where c.relname = x.table_name and t.tgname = x.trigger_name and not t.tgisinternal
);

-- ------------------------------------------------------------
-- 4. Required functions exist.
-- ------------------------------------------------------------
select p.proname function_name, pg_get_function_identity_arguments(p.oid) arguments
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
) order by p.proname;

-- ------------------------------------------------------------
-- 5. Direct client writes to the ledger tables are blocked, but
--    reading them still works. Every row below must show
--    select=true and insert/update/delete=false.
-- ------------------------------------------------------------
select x.table_name,
       has_table_privilege('authenticated', 'public.'||x.table_name, 'SELECT') can_select,
       has_table_privilege('authenticated', 'public.'||x.table_name, 'INSERT') can_insert,
       has_table_privilege('authenticated', 'public.'||x.table_name, 'UPDATE') can_update,
       has_table_privilege('authenticated', 'public.'||x.table_name, 'DELETE') can_delete
from (values
 ('vouchers'),('voucher_lines'),('invoices'),('invoice_lines'),
 ('purchase_bills'),('purchase_bill_lines'),
 ('credit_notes'),('credit_note_lines'),('debit_notes'),('debit_note_lines'),
 ('fiscal_periods'),('fiscal_period_lock_history')
) x(table_name);

-- ------------------------------------------------------------
-- 6. The three client-facing functions are callable, and the
--    internal guard is NOT directly callable by a client.
-- ------------------------------------------------------------
select has_function_privilege('authenticated','public.list_fiscal_periods(text)','EXECUTE') list_periods_execute,
       has_function_privilege('authenticated','public.create_fiscal_periods(text,jsonb)','EXECUTE') create_periods_execute,
       has_function_privilege('authenticated','public.set_period_lock(uuid,boolean,text)','EXECUTE') set_lock_execute,
       has_function_privilege('authenticated','public.assert_period_not_locked(uuid,date)','EXECUTE') internal_guard_should_be_false;

-- ------------------------------------------------------------
-- 7. No period is locked automatically by this migration — this
--    should return zero rows immediately after applying it.
-- ------------------------------------------------------------
select 'unexpected_locked_period' issue_type, id::text object_name, period_label||' ('||fiscal_year||')' details
from fiscal_periods where is_locked = true;
