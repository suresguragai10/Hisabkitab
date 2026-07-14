-- ============================================================
-- HisabKitab Stage 3 preflight (read-only)
-- Run before phaseP0_3_inventory_cogs.sql.
-- Every result set labelled "missing" should return zero rows.
-- ============================================================

-- 1. Required tables. Expected missing count: zero.
with required(name) as (
  values
    ('accounts'), ('vouchers'), ('voucher_lines'),
    ('parties'), ('item_categories'),
    ('inventory_items'), ('inventory_movements'),
    ('invoices'), ('invoice_lines'),
    ('purchase_bills'), ('purchase_bill_lines')
)
select r.name as missing_table
from required r
where to_regclass('public.' || r.name) is null
order by r.name;

-- 2. Required baseline columns from the accepted Stage 1/2 and master schemas.
--    Expected: zero rows.
with required(table_name, column_name) as (
  values
    ('accounts','user_id'), ('accounts','account_type'), ('accounts','group_name'),
    ('vouchers','is_void'), ('vouchers','voucher_date'),
    ('voucher_lines','account_id'), ('voucher_lines','debit'), ('voucher_lines','credit'),
    ('parties','account_id'),
    ('inventory_items','user_id'), ('inventory_items','current_stock'), ('inventory_items','cost_price'),
    ('inventory_movements','item_id'), ('inventory_movements','movement_type'),
    ('invoices','amount_paid'), ('invoices','outstanding_amount'), ('invoices','fiscal_year'),
    ('invoice_lines','invoice_id'),
    ('purchase_bills','amount_paid'), ('purchase_bills','outstanding_amount'), ('purchase_bills','fiscal_year'),
    ('purchase_bill_lines','bill_id')
)
select r.table_name, r.column_name as missing_column
from required r
left join information_schema.columns c
  on c.table_schema = 'public'
 and c.table_name = r.table_name
 and c.column_name = r.column_name
where c.column_name is null
order by r.table_name, r.column_name;

-- 3. Required posting functions. Expected: zero rows.
with required(name, args) as (
  values
    ('post_voucher', 'p_type text, p_fiscal_year text, p_date date, p_narration text, p_lines jsonb'),
    ('next_doc_number', 'p_doc_type text, p_fiscal_year text'),
    ('write_audit_log', 'p_action text, p_table text, p_record_id text, p_old jsonb, p_new jsonb')
), existing as (
  select p.proname as name, pg_get_function_identity_arguments(p.oid) as args
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
)
select r.name as missing_function, r.args as expected_arguments
from required r
where not exists (
  select 1 from existing e where e.name = r.name and e.args = r.args
)
order by r.name;

-- 4. Stage 2 function presence. Expected missing count: zero.
select 'record_document_payment' as missing_function
where to_regprocedure('public.record_document_payment(text,uuid,numeric,text,date,text,text)') is null
union all
select 'get_payment_history'
where to_regprocedure('public.get_payment_history(text,uuid)') is null
union all
select 'reverse_payment_allocation'
where to_regprocedure('public.reverse_payment_allocation(uuid,text,date)') is null;
