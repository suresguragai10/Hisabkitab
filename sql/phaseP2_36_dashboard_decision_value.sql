-- ============================================================
-- HisabKitab P2.36 -- Dashboard decision-value cards (audit item 4.9).
--
-- Existing dashboard already covered cash/receivables/payables,
-- overdue invoice count+amount, sales trend, VAT this month, and
-- stock value/low-stock count. Adding the audit's other suggestions:
-- bills due soon, bills overdue (payables side, symmetric to the
-- existing invoice-overdue card), pending TDS liability, bank items
-- awaiting reconciliation, negative-stock exceptions, gross margin,
-- and a top-5 overdue-customers list.
--
-- Purely additive: new jsonb keys on an already-jsonb-returning
-- function, so no return-type/column changes needed (unlike the
-- earlier report_account_activity fix which needed a DROP).
-- ============================================================

create or replace function get_dashboard_stats()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  uid uuid:=get_workspace_owner(); result jsonb;
  v_cash numeric; v_receivables numeric; v_payables numeric;
  v_sales_this numeric; v_sales_last numeric; v_vat_payable numeric;
  v_stock_value numeric; v_low_stock integer; v_invoice_count integer; v_overdue_count integer;
  v_overdue_amount numeric; v_invoice_outstanding numeric; v_bill_outstanding numeric;
  this_month_start date; last_month_start date; last_month_end date;
  v_bills_due_soon_count integer; v_bills_due_soon_amount numeric;
  v_bills_overdue_count integer; v_bills_overdue_amount numeric;
  v_tds_pending numeric; v_bank_unreconciled integer; v_negative_stock integer;
  v_cogs_this numeric; v_gross_margin_pct numeric;
  v_top_overdue jsonb;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  this_month_start:=date_trunc('month',current_date)::date;
  last_month_start:=(date_trunc('month',current_date)-interval '1 month')::date;
  last_month_end:=(this_month_start-1)::date;

  with balances as (
    select a.id,a.account_subtype,a.report_class,
      (case when a.opening_balance_type='debit' then a.opening_balance else -a.opening_balance end)
      +coalesce(sum(case when v.is_void=false then vl.debit-vl.credit else 0 end),0) balance
    from accounts a left join voucher_lines vl on vl.account_id=a.id left join vouchers v on v.id=vl.voucher_id
    where a.user_id=uid and a.is_active group by a.id
  )
  select coalesce(sum(balance) filter(where account_subtype in ('cash','bank')),0),
         coalesce(sum(balance) filter(where account_subtype in ('receivable','receivable_control')),0),
         coalesce(sum(-balance) filter(where account_subtype in ('payable','payable_control')),0)
  into v_cash,v_receivables,v_payables from balances;

  select coalesce(sum(case when invoice_date>=this_month_start then subtotal else 0 end),0)
      -coalesce((select sum(subtotal) from credit_notes where user_id=uid and document_status='posted' and cn_date>=this_month_start),0),
    coalesce(sum(case when invoice_date between last_month_start and last_month_end then subtotal else 0 end),0)
      -coalesce((select sum(subtotal) from credit_notes where user_id=uid and document_status='posted' and cn_date between last_month_start and last_month_end),0)
  into v_sales_this,v_sales_last from invoices where user_id=uid and document_status in ('posted','credited');

  select coalesce((select sum(vat_amount) from invoices where user_id=uid and document_status in ('posted','credited') and invoice_date>=this_month_start),0)
    -coalesce((select sum(vat_amount) from credit_notes where user_id=uid and document_status='posted' and cn_date>=this_month_start),0)
    -coalesce((select sum(vat_amount) from purchase_bills where user_id=uid and document_status in ('posted','credited') and bill_date>=this_month_start),0)
    +coalesce((select sum(vat_amount) from debit_notes where user_id=uid and document_status='posted' and dn_date>=this_month_start),0)
  into v_vat_payable;

  select coalesce(sum(inventory_value),0),count(*) filter(where current_stock<=reorder_level)::integer
  into v_stock_value,v_low_stock from inventory_items where user_id=uid and is_active and item_type='goods' and track_inventory;
  select count(*)::integer,count(*) filter(where due_date<current_date and outstanding_amount>0.005 and status in ('open','partial','overdue'))::integer,
    coalesce(sum(outstanding_amount) filter(where due_date<current_date and outstanding_amount>0.005 and status in ('open','partial','overdue')),0),coalesce(sum(outstanding_amount),0)
  into v_invoice_count,v_overdue_count,v_overdue_amount,v_invoice_outstanding from invoices where user_id=uid and document_status='posted';
  select coalesce(sum(outstanding_amount),0) into v_bill_outstanding from purchase_bills where user_id=uid and document_status='posted';

  -- Bills due soon (next 7 days, not yet overdue) and bills overdue --
  -- symmetric to the existing invoice-overdue card, payables side.
  select count(*) filter(where due_date between current_date and current_date+7 and outstanding_amount>0.005 and status in ('open','partial','overdue'))::integer,
    coalesce(sum(outstanding_amount) filter(where due_date between current_date and current_date+7 and outstanding_amount>0.005 and status in ('open','partial','overdue')),0),
    count(*) filter(where due_date<current_date and outstanding_amount>0.005 and status in ('open','partial','overdue'))::integer,
    coalesce(sum(outstanding_amount) filter(where due_date<current_date and outstanding_amount>0.005 and status in ('open','partial','overdue')),0)
  into v_bills_due_soon_count,v_bills_due_soon_amount,v_bills_overdue_count,v_bills_overdue_amount
  from purchase_bills where user_id=uid and document_status='posted';

  -- Pending TDS liability (deducted, not yet remitted).
  select coalesce(sum(tds_amount),0) into v_tds_pending
  from tds_entries where user_id=uid and status='deducted';

  -- Bank statement lines not yet matched to a voucher.
  select count(*)::integer into v_bank_unreconciled
  from bank_statement_lines where user_id=uid and is_matched=false;

  -- Negative stock is a data-integrity exception, not a normal state.
  select count(*)::integer into v_negative_stock
  from inventory_items where user_id=uid and is_active and track_inventory and current_stock<0;

  -- Gross margin this month = (sales - COGS) / sales.
  select coalesce(sum(cogs_amount),0) into v_cogs_this
  from invoices where user_id=uid and document_status in ('posted','credited') and invoice_date>=this_month_start;
  v_gross_margin_pct := case when v_sales_this>0.005 then round((v_sales_this-v_cogs_this)/v_sales_this*100,1) else null end;

  -- Top 5 overdue customers by outstanding amount.
  select coalesce(jsonb_agg(jsonb_build_object('party_name',party_name,'amount',amount) order by amount desc),'[]'::jsonb)
  into v_top_overdue
  from (
    select party_name, sum(outstanding_amount) amount
    from invoices
    where user_id=uid and document_status='posted' and due_date<current_date and outstanding_amount>0.005 and status in ('open','partial','overdue')
    group by party_name
    order by sum(outstanding_amount) desc
    limit 5
  ) top;

  return jsonb_build_object('cash',v_cash,'receivables',v_receivables,'payables',v_payables,'sales_this',v_sales_this,'sales_last',v_sales_last,
    'vat_payable',v_vat_payable,'stock_value',v_stock_value,'low_stock',v_low_stock,'invoice_count',v_invoice_count,'overdue_count',v_overdue_count,
    'overdue_amount',v_overdue_amount,'invoice_outstanding',v_invoice_outstanding,'bill_outstanding',v_bill_outstanding,
    'vat_deadline',to_char(date_trunc('month',current_date)+interval '1 month'+interval '14 days','YYYY-MM-DD'),
    'bills_due_soon_count',v_bills_due_soon_count,'bills_due_soon_amount',v_bills_due_soon_amount,
    'bills_overdue_count',v_bills_overdue_count,'bills_overdue_amount',v_bills_overdue_amount,
    'tds_pending',v_tds_pending,'bank_unreconciled',v_bank_unreconciled,'negative_stock_count',v_negative_stock,
    'gross_margin_pct',v_gross_margin_pct,'top_overdue_customers',v_top_overdue);
end;
$$;
