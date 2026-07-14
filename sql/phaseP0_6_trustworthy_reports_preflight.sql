-- HisabKitab Stage 6 preflight. Resolve every returned blocking row.

select 'missing_table' issue_type, x.name object_name, 'Required by Stage 6' details
from (values
 ('accounts'),('vouchers'),('voucher_lines'),('invoices'),('purchase_bills'),
 ('credit_notes'),('debit_notes'),('document_payments'),('payment_allocations'),
 ('inventory_items'),('inventory_movements')
) x(name)
where to_regclass('public.'||x.name) is null;

select 'missing_column' issue_type, x.table_name||'.'||x.column_name object_name, 'Required by Stage 6' details
from (values
 ('accounts','account_code'),('accounts','report_class'),('accounts','account_subtype'),
 ('accounts','normal_balance'),('accounts','cash_flow_category'),('accounts','system_code'),
 ('vouchers','source_document_type'),('vouchers','source_document_id'),
 ('invoices','document_status'),('invoices','cancellation_voucher_id'),
 ('purchase_bills','document_status'),('purchase_bills','cancellation_voucher_id'),
 ('payment_allocations','reversal_voucher_id'),
 ('inventory_movements','stock_before'),('inventory_movements','stock_after'),
 ('inventory_movements','value_before'),('inventory_movements','value_after')
) x(table_name,column_name)
where not exists (
  select 1 from information_schema.columns c
  where c.table_schema='public' and c.table_name=x.table_name and c.column_name=x.column_name
);

select 'invalid_account_classification' issue_type,id::text object_name,
       coalesce(account_code,'(no code)')||' · '||name details
from accounts
where report_class is null or account_subtype is null or normal_balance is null or cash_flow_category is null;

select 'posted_document_without_voucher' issue_type,id::text object_name,
       'Invoice #'||invoice_number||' FY '||fiscal_year details
from invoices where document_status in ('posted','credited') and voucher_id is null
union all
select 'posted_document_without_voucher',id::text,
       'Bill #'||bill_number||' FY '||fiscal_year
from purchase_bills where document_status in ('posted','credited') and voucher_id is null;

select 'unbalanced_active_voucher' issue_type,v.id::text object_name,
       v.voucher_type||' #'||v.voucher_number||' difference='||round(sum(vl.debit-vl.credit),2) details
from vouchers v join voucher_lines vl on vl.voucher_id=v.id
where v.is_void=false
group by v.id
having abs(sum(vl.debit-vl.credit))>0.005;
