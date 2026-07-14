-- HisabKitab Stage 6 verification.

select p.proname function_name,pg_get_function_identity_arguments(p.oid) arguments,
       pg_get_function_result(p.oid) return_type
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.proname in (
 'report_account_activity','get_report_fiscal_years','get_general_ledger_report','get_day_book_report',
 'get_trial_balance_report','get_profit_loss_report','get_balance_sheet_report','get_cash_flow_report',
 'get_receivables_ageing_report','get_payables_ageing_report','get_sales_register_report',
 'get_purchase_register_report','get_vat_report','get_stock_valuation_report'
) order by p.proname;

select user_id,round(sum(case when balance>=0 then balance else 0 end),2) total_debit,
       round(sum(case when balance<0 then -balance else 0 end),2) total_credit,
       round(sum(balance),2) difference
from (
  select a.user_id,a.id,
    (case when a.opening_balance_type='debit' then a.opening_balance else -a.opening_balance end)
    +coalesce(sum(case when v.is_void=false then vl.debit-vl.credit else 0 end),0) balance
  from accounts a left join voucher_lines vl on vl.account_id=a.id left join vouchers v on v.id=vl.voucher_id
  group by a.user_id,a.id
) x group by user_id having abs(sum(balance))>0.005;

select 'vat_output_variance' issue_type,v.user_id::text owner,
  round(coalesce(d.document_vat,0)-coalesce(l.ledger_vat,0),2) difference
from (select distinct user_id from vouchers) v
left join (
 select user_id,sum(vat_amount) document_vat from invoices where document_status in ('posted','credited') group by user_id
) d on d.user_id=v.user_id
left join (
 select a.user_id,sum(vl.credit-vl.debit) ledger_vat from accounts a join voucher_lines vl on vl.account_id=a.id
 join vouchers x on x.id=vl.voucher_id and x.is_void=false where a.system_code='vat_payable' group by a.user_id
) l on l.user_id=v.user_id
where abs(coalesce(d.document_vat,0)-coalesce(l.ledger_vat,0))>0.01;

select has_function_privilege('authenticated','public.get_trial_balance_report(date)','EXECUTE') trial_balance_execute,
       has_function_privilege('authenticated','public.get_profit_loss_report(date,date,text)','EXECUTE') profit_loss_execute,
       has_function_privilege('authenticated','public.get_balance_sheet_report(date)','EXECUTE') balance_sheet_execute,
       has_function_privilege('authenticated','public.get_cash_flow_report(date,date,text)','EXECUTE') cash_flow_execute,
       has_function_privilege('authenticated','public.get_stock_valuation_report(date)','EXECUTE') stock_execute;
