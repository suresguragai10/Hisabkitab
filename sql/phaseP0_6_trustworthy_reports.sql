-- ============================================================
-- HisabKitab Stage 6 - trustworthy, ledger-reconciled reports
-- Apply after phaseP0_5_structured_chart.sql.
--
-- Reporting policy:
--   * posted, non-void vouchers are the accounting source of truth
--   * document registers include posted source documents and posted notes
--   * ageing is invoice/bill based and reconstructed as of the selected date
--   * Balance Sheet includes current earnings so it reconciles to the ledger
--   * Cash Flow is derived from movements through cash/bank accounts
--   * stock valuation is compared with the Inventory Asset ledger
-- ============================================================

begin;

create index if not exists idx_vouchers_report_date
  on vouchers(user_id, voucher_date, fiscal_year) where is_void = false;
create index if not exists idx_invoice_report_date
  on invoices(user_id, invoice_date, fiscal_year, document_status);
create index if not exists idx_bill_report_date
  on purchase_bills(user_id, bill_date, fiscal_year, document_status);
create index if not exists idx_credit_note_report_date
  on credit_notes(user_id, cn_date, fiscal_year, document_status);
create index if not exists idx_debit_note_report_date
  on debit_notes(user_id, dn_date, fiscal_year, document_status);
create index if not exists idx_payment_report_date
  on document_payments(user_id, payment_date);
create index if not exists idx_inventory_report_date
  on inventory_movements(user_id, item_id, movement_date, created_at);

-- ------------------------------------------------------------
-- 1. Shared account activity engine.
--    Debit balances are positive; credit balances are negative.
-- ------------------------------------------------------------
create or replace function report_account_activity(
  p_from date,
  p_to date,
  p_fiscal_year text default null
)
returns table (
  account_id uuid,
  account_code text,
  account_name text,
  account_type text,
  report_class text,
  account_subtype text,
  normal_balance text,
  cash_flow_category text,
  parent_account_id uuid,
  system_code text,
  opening_balance numeric,
  period_debit numeric,
  period_credit numeric,
  closing_balance numeric
)
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  if p_from is not null and p_to is not null and p_from > p_to then
    raise exception 'From date cannot be after To date.';
  end if;

  return query
  select
    a.id,
    a.account_code,
    a.name,
    a.account_type,
    a.report_class,
    a.account_subtype,
    a.normal_balance,
    a.cash_flow_category,
    a.parent_account_id,
    a.system_code,
    round(
      (case when a.opening_balance_type = 'debit' then a.opening_balance else -a.opening_balance end)
      + coalesce(sum(
          case when v.is_void = false
                 and p_from is not null
                 and v.voucher_date < p_from
               then vl.debit - vl.credit else 0 end
        ), 0),
      2
    ) as opening_balance,
    round(coalesce(sum(
      case when v.is_void = false
             and (p_from is null or v.voucher_date >= p_from)
             and (p_to is null or v.voucher_date <= p_to)
             and (p_fiscal_year is null or v.fiscal_year = p_fiscal_year)
           then vl.debit else 0 end
    ), 0), 2) as period_debit,
    round(coalesce(sum(
      case when v.is_void = false
             and (p_from is null or v.voucher_date >= p_from)
             and (p_to is null or v.voucher_date <= p_to)
             and (p_fiscal_year is null or v.fiscal_year = p_fiscal_year)
           then vl.credit else 0 end
    ), 0), 2) as period_credit,
    round(
      (case when a.opening_balance_type = 'debit' then a.opening_balance else -a.opening_balance end)
      + coalesce(sum(
          case when v.is_void = false
                 and (p_to is null or v.voucher_date <= p_to)
                 and (
                   p_fiscal_year is null
                   or p_from is not null and v.voucher_date < p_from
                   or v.fiscal_year = p_fiscal_year
                 )
               then vl.debit - vl.credit else 0 end
        ), 0),
      2
    ) as closing_balance
  from accounts a
  left join voucher_lines vl on vl.account_id = a.id
  left join vouchers v on v.id = vl.voucher_id and v.user_id = uid
  where a.user_id = uid and a.is_active = true
  group by a.id;
end;
$$;

revoke all on function report_account_activity(date,date,text) from public;
grant execute on function report_account_activity(date,date,text) to authenticated;

-- ------------------------------------------------------------
-- 2. Fiscal-year selector.
-- ------------------------------------------------------------
create or replace function get_report_fiscal_years()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  result jsonb;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  select coalesce(jsonb_agg(fiscal_year order by fiscal_year desc), '[]'::jsonb)
    into result
    from (
      select distinct fiscal_year from vouchers where user_id = uid
      union select distinct fiscal_year from invoices where user_id = uid
      union select distinct fiscal_year from purchase_bills where user_id = uid
      union select distinct fiscal_year from credit_notes where user_id = uid
      union select distinct fiscal_year from debit_notes where user_id = uid
    ) x
   where fiscal_year is not null and btrim(fiscal_year) <> '';
  return result;
end;
$$;
revoke all on function get_report_fiscal_years() from public;
grant execute on function get_report_fiscal_years() to authenticated;

-- ------------------------------------------------------------
-- 3. General Ledger.
-- ------------------------------------------------------------
create or replace function get_general_ledger_report(
  p_account_id uuid,
  p_from date,
  p_to date,
  p_fiscal_year text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  a record;
  v_opening numeric := 0;
  v_debit numeric := 0;
  v_credit numeric := 0;
  v_closing numeric := 0;
  v_rows jsonb;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  if p_account_id is null then raise exception 'Account is required.'; end if;
  if p_from is null or p_to is null then raise exception 'From and To dates are required.'; end if;
  if p_from > p_to then raise exception 'From date cannot be after To date.'; end if;

  select * into a from accounts where id = p_account_id and user_id = uid;
  if not found then raise exception 'Account not found.'; end if;

  select opening_balance, period_debit, period_credit, closing_balance
    into v_opening, v_debit, v_credit, v_closing
    from report_account_activity(p_from, p_to, p_fiscal_year)
   where account_id = p_account_id;

  with entries as (
    select
      vl.id,
      v.id as voucher_id,
      v.voucher_date,
      v.voucher_type,
      v.voucher_number,
      v.fiscal_year,
      v.narration,
      v.source_document_type,
      v.source_document_id,
      vl.description,
      round(vl.debit,2) debit,
      round(vl.credit,2) credit,
      v.created_at,
      round(v_opening + sum(vl.debit - vl.credit) over (
        order by v.voucher_date, v.created_at, v.id, vl.id
        rows between unbounded preceding and current row
      ), 2) running_balance
    from voucher_lines vl
    join vouchers v on v.id = vl.voucher_id
    where vl.account_id = p_account_id
      and v.user_id = uid
      and v.is_void = false
      and v.voucher_date between p_from and p_to
      and (p_fiscal_year is null or v.fiscal_year = p_fiscal_year)
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',id,'voucher_id',voucher_id,'date',voucher_date,
    'voucher_type',voucher_type,'voucher_number',voucher_number,'fiscal_year',fiscal_year,
    'narration',narration,'description',description,'debit',debit,'credit',credit,
    'running_balance',running_balance,'source_document_type',source_document_type,
    'source_document_id',source_document_id
  ) order by voucher_date,created_at,voucher_id,id), '[]'::jsonb)
  into v_rows from entries;

  return jsonb_build_object(
    'report','general_ledger','from',p_from,'to',p_to,'fiscal_year',p_fiscal_year,
    'account',jsonb_build_object(
      'id',a.id,'account_code',a.account_code,'name',a.name,
      'account_type',a.account_type,'report_class',a.report_class,
      'normal_balance',a.normal_balance
    ),
    'opening_balance',coalesce(v_opening,0),
    'period_debit',coalesce(v_debit,0),
    'period_credit',coalesce(v_credit,0),
    'closing_balance',coalesce(v_closing,0),
    'rows',v_rows
  );
end;
$$;
revoke all on function get_general_ledger_report(uuid,date,date,text) from public;
grant execute on function get_general_ledger_report(uuid,date,date,text) to authenticated;

-- ------------------------------------------------------------
-- 4. Day Book.
-- ------------------------------------------------------------
create or replace function get_day_book_report(
  p_from date,
  p_to date,
  p_fiscal_year text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  v_rows jsonb;
  v_debit numeric;
  v_credit numeric;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  if p_from is null or p_to is null or p_from > p_to then raise exception 'A valid date range is required.'; end if;

  with selected as (
    select v.*
      from vouchers v
     where v.user_id = uid and v.is_void = false
       and v.voucher_date between p_from and p_to
       and (p_fiscal_year is null or v.fiscal_year = p_fiscal_year)
  ), rows as (
    select s.id,s.voucher_date,s.voucher_type,s.voucher_number,s.fiscal_year,s.narration,
           s.source_document_type,s.source_document_id,s.created_at,
           coalesce((select sum(vl.debit) from voucher_lines vl where vl.voucher_id=s.id),0) debit,
           coalesce((select sum(vl.credit) from voucher_lines vl where vl.voucher_id=s.id),0) credit,
           coalesce((select jsonb_agg(jsonb_build_object(
             'line_id',vl.id,'account_id',a.id,'account_code',a.account_code,'account_name',a.name,
             'description',vl.description,'debit',vl.debit,'credit',vl.credit
           ) order by vl.id)
           from voucher_lines vl join accounts a on a.id=vl.account_id where vl.voucher_id=s.id),'[]'::jsonb) lines
      from selected s
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'voucher_id',id,'date',voucher_date,'voucher_type',voucher_type,'voucher_number',voucher_number,
    'fiscal_year',fiscal_year,'narration',narration,'debit',round(debit,2),'credit',round(credit,2),
    'source_document_type',source_document_type,'source_document_id',source_document_id,'lines',lines
  ) order by voucher_date,created_at,id),'[]'::jsonb),
  coalesce(sum(debit),0),coalesce(sum(credit),0)
  into v_rows,v_debit,v_credit from rows;

  return jsonb_build_object(
    'report','day_book','from',p_from,'to',p_to,'fiscal_year',p_fiscal_year,
    'total_debit',round(v_debit,2),'total_credit',round(v_credit,2),
    'difference',round(v_debit-v_credit,2),'rows',v_rows
  );
end;
$$;
revoke all on function get_day_book_report(date,date,text) from public;
grant execute on function get_day_book_report(date,date,text) to authenticated;

-- ------------------------------------------------------------
-- 5. Trial Balance.
-- ------------------------------------------------------------
create or replace function get_trial_balance_report(p_as_of date)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  v_rows jsonb;
  v_debit numeric;
  v_credit numeric;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  if p_as_of is null then raise exception 'As-of date is required.'; end if;

  with rows as (
    select *,
      case when closing_balance >= 0 then closing_balance else 0 end debit,
      case when closing_balance < 0 then -closing_balance else 0 end credit
    from report_account_activity(null,p_as_of,null)
    where abs(closing_balance) > 0.005
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'account_id',account_id,'account_code',account_code,'name',account_name,
    'account_type',account_type,'report_class',report_class,'account_subtype',account_subtype,
    'debit',round(debit,2),'credit',round(credit,2),'balance',round(closing_balance,2)
  ) order by account_code,account_name),'[]'::jsonb),
  coalesce(sum(debit),0),coalesce(sum(credit),0)
  into v_rows,v_debit,v_credit from rows;

  return jsonb_build_object(
    'report','trial_balance','as_of',p_as_of,'rows',v_rows,
    'total_debit',round(v_debit,2),'total_credit',round(v_credit,2),
    'difference',round(v_debit-v_credit,2),'balanced',abs(v_debit-v_credit)<=0.005
  );
end;
$$;
revoke all on function get_trial_balance_report(date) from public;
grant execute on function get_trial_balance_report(date) to authenticated;

-- ------------------------------------------------------------
-- 6. Profit and Loss.
-- ------------------------------------------------------------
create or replace function get_profit_loss_report(
  p_from date,
  p_to date,
  p_fiscal_year text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  v_rows jsonb;
  v_revenue numeric;
  v_other_income numeric;
  v_cogs numeric;
  v_operating numeric;
  v_other_expense numeric;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  if p_from is null or p_to is null or p_from > p_to then raise exception 'A valid date range is required.'; end if;

  with rows as (
    select account_id,account_code,account_name,report_class,
      round(case when report_class in ('revenue','other_income')
        then period_credit-period_debit else period_debit-period_credit end,2) amount
    from report_account_activity(p_from,p_to,p_fiscal_year)
    where report_class in ('revenue','other_income','cost_of_sales','operating_expense','other_expense')
      and abs(period_debit-period_credit)>0.005
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'account_id',account_id,'account_code',account_code,'name',account_name,
    'report_class',report_class,'amount',amount
  ) order by report_class,account_code,account_name),'[]'::jsonb),
  coalesce(sum(amount) filter(where report_class='revenue'),0),
  coalesce(sum(amount) filter(where report_class='other_income'),0),
  coalesce(sum(amount) filter(where report_class='cost_of_sales'),0),
  coalesce(sum(amount) filter(where report_class='operating_expense'),0),
  coalesce(sum(amount) filter(where report_class='other_expense'),0)
  into v_rows,v_revenue,v_other_income,v_cogs,v_operating,v_other_expense from rows;

  return jsonb_build_object(
    'report','profit_loss','from',p_from,'to',p_to,'fiscal_year',p_fiscal_year,
    'rows',v_rows,'revenue',round(v_revenue,2),'other_income',round(v_other_income,2),
    'cost_of_sales',round(v_cogs,2),'gross_profit',round(v_revenue-v_cogs,2),
    'operating_expense',round(v_operating,2),'other_expense',round(v_other_expense,2),
    'net_profit',round(v_revenue+v_other_income-v_cogs-v_operating-v_other_expense,2)
  );
end;
$$;
revoke all on function get_profit_loss_report(date,date,text) from public;
grant execute on function get_profit_loss_report(date,date,text) to authenticated;

-- ------------------------------------------------------------
-- 7. Balance Sheet with current earnings.
-- ------------------------------------------------------------
create or replace function get_balance_sheet_report(p_as_of date)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  v_rows jsonb;
  v_assets numeric;
  v_liabilities numeric;
  v_equity numeric;
  v_earnings numeric;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  if p_as_of is null then raise exception 'As-of date is required.'; end if;

  with activity as (
    select * from report_account_activity(null,p_as_of,null)
  ), rows as (
    select account_id,account_code,account_name,report_class,account_subtype,
      round(case when report_class in ('current_asset','non_current_asset')
        then closing_balance else -closing_balance end,2) amount
    from activity
    where report_class in ('current_asset','non_current_asset','current_liability','non_current_liability','equity')
      and abs(closing_balance)>0.005
  ), earnings as (
    select round(coalesce(sum(case
      when report_class in ('revenue','other_income') then -closing_balance
      when report_class in ('cost_of_sales','operating_expense','other_expense') then -closing_balance
      else 0 end),0),2) value
    from activity
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'account_id',account_id,'account_code',account_code,'name',account_name,
    'report_class',report_class,'account_subtype',account_subtype,'amount',amount
  ) order by report_class,account_code,account_name),'[]'::jsonb),
  coalesce(sum(amount) filter(where report_class in ('current_asset','non_current_asset')),0),
  coalesce(sum(amount) filter(where report_class in ('current_liability','non_current_liability')),0),
  coalesce(sum(amount) filter(where report_class='equity'),0),
  (select value from earnings)
  into v_rows,v_assets,v_liabilities,v_equity,v_earnings from rows;

  return jsonb_build_object(
    'report','balance_sheet','as_of',p_as_of,'rows',v_rows,
    'total_assets',round(v_assets,2),'total_liabilities',round(v_liabilities,2),
    'equity_before_current_earnings',round(v_equity,2),'current_earnings',round(v_earnings,2),
    'total_equity',round(v_equity+v_earnings,2),
    'liabilities_and_equity',round(v_liabilities+v_equity+v_earnings,2),
    'difference',round(v_assets-(v_liabilities+v_equity+v_earnings),2),
    'balanced',abs(v_assets-(v_liabilities+v_equity+v_earnings))<=0.01
  );
end;
$$;
revoke all on function get_balance_sheet_report(date) from public;
grant execute on function get_balance_sheet_report(date) to authenticated;

-- ------------------------------------------------------------
-- 8. Cash Flow, derived from cash/bank voucher movements.
-- ------------------------------------------------------------
create or replace function get_cash_flow_report(
  p_from date,
  p_to date,
  p_fiscal_year text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  v_rows jsonb;
  v_opening numeric;
  v_closing numeric;
  v_operating numeric;
  v_investing numeric;
  v_financing numeric;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  if p_from is null or p_to is null or p_from > p_to then raise exception 'A valid date range is required.'; end if;

  select coalesce(sum(opening_balance),0),coalesce(sum(closing_balance),0)
    into v_opening,v_closing
    from report_account_activity(p_from,p_to,p_fiscal_year)
   where account_subtype in ('cash','bank') or system_code in ('cash','bank');

  with cash_accounts as (
    select id from accounts where user_id=uid and is_active
      and (account_subtype in ('cash','bank') or system_code in ('cash','bank'))
  ), flow_rows as (
    select v.id voucher_id,v.voucher_date,v.voucher_type,v.voucher_number,v.fiscal_year,v.narration,
           a.cash_flow_category,
           round(sum(vl.credit-vl.debit),2) amount,
           v.created_at
      from vouchers v
      join voucher_lines vl on vl.voucher_id=v.id
      join accounts a on a.id=vl.account_id
     where v.user_id=uid and v.is_void=false
       and v.voucher_date between p_from and p_to
       and (p_fiscal_year is null or v.fiscal_year=p_fiscal_year)
       and vl.account_id not in (select id from cash_accounts)
       and exists(select 1 from voucher_lines cvl where cvl.voucher_id=v.id and cvl.account_id in (select id from cash_accounts))
     group by v.id,a.cash_flow_category
     having abs(sum(vl.credit-vl.debit))>0.005
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'voucher_id',voucher_id,'date',voucher_date,'voucher_type',voucher_type,
    'voucher_number',voucher_number,'fiscal_year',fiscal_year,'narration',narration,
    'cash_flow_category',cash_flow_category,'amount',amount
  ) order by voucher_date,created_at,voucher_id),'[]'::jsonb),
  coalesce(sum(amount) filter(where cash_flow_category='operating'),0),
  coalesce(sum(amount) filter(where cash_flow_category='investing'),0),
  coalesce(sum(amount) filter(where cash_flow_category='financing'),0)
  into v_rows,v_operating,v_investing,v_financing from flow_rows;

  return jsonb_build_object(
    'report','cash_flow','from',p_from,'to',p_to,'fiscal_year',p_fiscal_year,
    'rows',v_rows,'opening_cash',round(v_opening,2),
    'operating',round(v_operating,2),'investing',round(v_investing,2),
    'financing',round(v_financing,2),'net_change',round(v_operating+v_investing+v_financing,2),
    'closing_cash',round(v_closing,2),
    'difference',round(v_opening+v_operating+v_investing+v_financing-v_closing,2),
    'reconciled',abs(v_opening+v_operating+v_investing+v_financing-v_closing)<=0.01
  );
end;
$$;
revoke all on function get_cash_flow_report(date,date,text) from public;
grant execute on function get_cash_flow_report(date,date,text) to authenticated;

-- ------------------------------------------------------------
-- 9. Invoice-level receivables ageing as of a historical date.
-- ------------------------------------------------------------
create or replace function get_receivables_ageing_report(p_as_of date)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  v_rows jsonb;
  v_current numeric; v_30 numeric; v_60 numeric; v_90 numeric; v_over numeric;
  v_ledger numeric;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  if p_as_of is null then raise exception 'As-of date is required.'; end if;

  with credits as (
    select n.invoice_id,sum(n.total) amount
      from credit_notes n
      left join vouchers cv on cv.id=n.cancellation_voucher_id
     where n.user_id=uid and n.cn_date<=p_as_of
       and (n.document_status='posted' or cv.voucher_date>p_as_of)
     group by n.invoice_id
  ), paid as (
    select a.invoice_id,sum(a.allocated_amount) amount
      from payment_allocations a
      join document_payments p on p.id=a.payment_id
      left join vouchers rv on rv.id=a.reversal_voucher_id
     where a.user_id=uid and a.invoice_id is not null and p.payment_date<=p_as_of
       and (a.reversed_at is null or coalesce(rv.voucher_date,a.reversed_at::date)>p_as_of)
     group by a.invoice_id
  ), rows as (
    select i.id,i.invoice_number,i.fiscal_year,i.invoice_date,i.due_date,i.party_id,i.party_name,
      round(i.total-coalesce(c.amount,0),2) net_amount,
      round(coalesce(p.amount,0),2) paid_amount,
      greatest(round(i.total-coalesce(c.amount,0)-coalesce(p.amount,0),2),0) outstanding,
      greatest(p_as_of-coalesce(i.due_date,i.invoice_date),0) age_days
    from invoices i
    left join credits c on c.invoice_id=i.id
    left join paid p on p.invoice_id=i.id
    left join vouchers cv on cv.id=i.cancellation_voucher_id
    where i.user_id=uid and i.invoice_date<=p_as_of and i.document_status<>'draft'
      and (i.document_status<>'cancelled' or cv.voucher_date>p_as_of)
  ), aged as (
    select *,
      case when age_days=0 then 'current'
           when age_days<=30 then '1_30'
           when age_days<=60 then '31_60'
           when age_days<=90 then '61_90' else 'over_90' end bucket
    from rows where outstanding>0.005
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'document_id',id,'invoice_number',invoice_number,'fiscal_year',fiscal_year,
    'invoice_date',invoice_date,'due_date',due_date,'party_id',party_id,'party_name',party_name,
    'net_amount',net_amount,'paid_amount',paid_amount,'outstanding',outstanding,
    'age_days',age_days,'bucket',bucket
  ) order by due_date,invoice_date,invoice_number),'[]'::jsonb),
  coalesce(sum(outstanding) filter(where bucket='current'),0),
  coalesce(sum(outstanding) filter(where bucket='1_30'),0),
  coalesce(sum(outstanding) filter(where bucket='31_60'),0),
  coalesce(sum(outstanding) filter(where bucket='61_90'),0),
  coalesce(sum(outstanding) filter(where bucket='over_90'),0)
  into v_rows,v_current,v_30,v_60,v_90,v_over from aged;

  select coalesce(sum(closing_balance),0) into v_ledger
    from report_account_activity(null,p_as_of,null)
   where account_subtype in ('receivable','receivable_control');

  return jsonb_build_object(
    'report','receivables_ageing','as_of',p_as_of,'rows',v_rows,
    'current',round(v_current,2),'days_1_30',round(v_30,2),'days_31_60',round(v_60,2),
    'days_61_90',round(v_90,2),'over_90',round(v_over,2),
    'total',round(v_current+v_30+v_60+v_90+v_over,2),
    'ledger_balance',round(v_ledger,2),
    'difference',round(v_current+v_30+v_60+v_90+v_over-v_ledger,2),
    'reconciled',abs(v_current+v_30+v_60+v_90+v_over-v_ledger)<=0.01
  );
end;
$$;
revoke all on function get_receivables_ageing_report(date) from public;
grant execute on function get_receivables_ageing_report(date) to authenticated;

-- ------------------------------------------------------------
-- 10. Bill-level payables ageing.
-- ------------------------------------------------------------
create or replace function get_payables_ageing_report(p_as_of date)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  v_rows jsonb;
  v_current numeric; v_30 numeric; v_60 numeric; v_90 numeric; v_over numeric;
  v_ledger numeric;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  if p_as_of is null then raise exception 'As-of date is required.'; end if;

  with debits as (
    select n.bill_id,sum(n.total) amount
      from debit_notes n
      left join vouchers cv on cv.id=n.cancellation_voucher_id
     where n.user_id=uid and n.dn_date<=p_as_of
       and (n.document_status='posted' or cv.voucher_date>p_as_of)
     group by n.bill_id
  ), paid as (
    select a.bill_id,sum(a.allocated_amount) amount
      from payment_allocations a
      join document_payments p on p.id=a.payment_id
      left join vouchers rv on rv.id=a.reversal_voucher_id
     where a.user_id=uid and a.bill_id is not null and p.payment_date<=p_as_of
       and (a.reversed_at is null or coalesce(rv.voucher_date,a.reversed_at::date)>p_as_of)
     group by a.bill_id
  ), rows as (
    select b.id,b.bill_number,b.fiscal_year,b.bill_date,b.due_date,b.vendor_id,b.vendor_name,
      round(b.total-coalesce(d.amount,0),2) net_amount,
      round(coalesce(p.amount,0),2) paid_amount,
      greatest(round(b.total-coalesce(d.amount,0)-coalesce(p.amount,0),2),0) outstanding,
      greatest(p_as_of-coalesce(b.due_date,b.bill_date),0) age_days
    from purchase_bills b
    left join debits d on d.bill_id=b.id
    left join paid p on p.bill_id=b.id
    left join vouchers cv on cv.id=b.cancellation_voucher_id
    where b.user_id=uid and b.bill_date<=p_as_of and b.document_status<>'draft'
      and (b.document_status<>'cancelled' or cv.voucher_date>p_as_of)
  ), aged as (
    select *,
      case when age_days=0 then 'current'
           when age_days<=30 then '1_30'
           when age_days<=60 then '31_60'
           when age_days<=90 then '61_90' else 'over_90' end bucket
    from rows where outstanding>0.005
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'document_id',id,'bill_number',bill_number,'fiscal_year',fiscal_year,
    'bill_date',bill_date,'due_date',due_date,'vendor_id',vendor_id,'vendor_name',vendor_name,
    'net_amount',net_amount,'paid_amount',paid_amount,'outstanding',outstanding,
    'age_days',age_days,'bucket',bucket
  ) order by due_date,bill_date,bill_number),'[]'::jsonb),
  coalesce(sum(outstanding) filter(where bucket='current'),0),
  coalesce(sum(outstanding) filter(where bucket='1_30'),0),
  coalesce(sum(outstanding) filter(where bucket='31_60'),0),
  coalesce(sum(outstanding) filter(where bucket='61_90'),0),
  coalesce(sum(outstanding) filter(where bucket='over_90'),0)
  into v_rows,v_current,v_30,v_60,v_90,v_over from aged;

  select coalesce(sum(-closing_balance),0) into v_ledger
    from report_account_activity(null,p_as_of,null)
   where account_subtype in ('payable','payable_control');

  return jsonb_build_object(
    'report','payables_ageing','as_of',p_as_of,'rows',v_rows,
    'current',round(v_current,2),'days_1_30',round(v_30,2),'days_31_60',round(v_60,2),
    'days_61_90',round(v_90,2),'over_90',round(v_over,2),
    'total',round(v_current+v_30+v_60+v_90+v_over,2),
    'ledger_balance',round(v_ledger,2),
    'difference',round(v_current+v_30+v_60+v_90+v_over-v_ledger,2),
    'reconciled',abs(v_current+v_30+v_60+v_90+v_over-v_ledger)<=0.01
  );
end;
$$;
revoke all on function get_payables_ageing_report(date) from public;
grant execute on function get_payables_ageing_report(date) to authenticated;

-- ------------------------------------------------------------
-- 11. Sales and purchase registers, including notes as negatives.
-- ------------------------------------------------------------
create or replace function get_sales_register_report(p_from date,p_to date,p_fiscal_year text default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid:=auth.uid(); v_rows jsonb; v_sub numeric; v_vat numeric; v_total numeric;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  if p_from is null or p_to is null or p_from>p_to then raise exception 'A valid date range is required.'; end if;
  with rows as (
    select 'invoice'::text document_type,i.id document_id,i.invoice_date document_date,i.invoice_number document_number,
      i.fiscal_year,i.party_name,i.party_pan pan_vat,i.subtotal,i.vat_amount,i.total,i.voucher_id,i.notes,1 sign
    from invoices i where i.user_id=uid and i.document_status in ('posted','credited') and i.invoice_date between p_from and p_to
      and (p_fiscal_year is null or i.fiscal_year=p_fiscal_year)
    union all
    select 'credit_note',n.id,n.cn_date,n.cn_number,n.fiscal_year,n.party_name,n.party_pan,
      -n.subtotal,-n.vat_amount,-n.total,n.voucher_id,n.reason,-1
    from credit_notes n where n.user_id=uid and n.document_status='posted' and n.cn_date between p_from and p_to
      and (p_fiscal_year is null or n.fiscal_year=p_fiscal_year)
  )
  select coalesce(jsonb_agg(to_jsonb(rows) order by document_date,document_type,document_number),'[]'::jsonb),
    coalesce(sum(subtotal),0),coalesce(sum(vat_amount),0),coalesce(sum(total),0)
  into v_rows,v_sub,v_vat,v_total from rows;
  return jsonb_build_object('report','sales_register','from',p_from,'to',p_to,'fiscal_year',p_fiscal_year,
    'rows',v_rows,'subtotal',round(v_sub,2),'vat',round(v_vat,2),'total',round(v_total,2));
end; $$;
revoke all on function get_sales_register_report(date,date,text) from public;
grant execute on function get_sales_register_report(date,date,text) to authenticated;

create or replace function get_purchase_register_report(p_from date,p_to date,p_fiscal_year text default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid:=auth.uid(); v_rows jsonb; v_sub numeric; v_vat numeric; v_total numeric;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  if p_from is null or p_to is null or p_from>p_to then raise exception 'A valid date range is required.'; end if;
  with rows as (
    select 'purchase_bill'::text document_type,b.id document_id,b.bill_date document_date,b.bill_number document_number,
      b.fiscal_year,b.vendor_name party_name,b.vendor_pan pan_vat,b.vendor_bill_ref external_reference,
      b.subtotal,b.vat_amount,b.total,b.voucher_id,b.notes,1 sign
    from purchase_bills b where b.user_id=uid and b.document_status in ('posted','credited') and b.bill_date between p_from and p_to
      and (p_fiscal_year is null or b.fiscal_year=p_fiscal_year)
    union all
    select 'debit_note',n.id,n.dn_date,n.dn_number,n.fiscal_year,n.vendor_name,n.vendor_pan,null,
      -n.subtotal,-n.vat_amount,-n.total,n.voucher_id,n.reason,-1
    from debit_notes n where n.user_id=uid and n.document_status='posted' and n.dn_date between p_from and p_to
      and (p_fiscal_year is null or n.fiscal_year=p_fiscal_year)
  )
  select coalesce(jsonb_agg(to_jsonb(rows) order by document_date,document_type,document_number),'[]'::jsonb),
    coalesce(sum(subtotal),0),coalesce(sum(vat_amount),0),coalesce(sum(total),0)
  into v_rows,v_sub,v_vat,v_total from rows;
  return jsonb_build_object('report','purchase_register','from',p_from,'to',p_to,'fiscal_year',p_fiscal_year,
    'rows',v_rows,'subtotal',round(v_sub,2),'vat',round(v_vat,2),'total',round(v_total,2));
end; $$;
revoke all on function get_purchase_register_report(date,date,text) from public;
grant execute on function get_purchase_register_report(date,date,text) to authenticated;

-- ------------------------------------------------------------
-- 12. VAT report reconciled to VAT ledger accounts.
-- ------------------------------------------------------------
create or replace function get_vat_report(p_from date,p_to date,p_fiscal_year text default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  uid uuid:=auth.uid(); v_rows jsonb;
  v_output numeric; v_input numeric; v_output_ledger numeric; v_input_ledger numeric;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  if p_from is null or p_to is null or p_from>p_to then raise exception 'A valid date range is required.'; end if;

  with rows as (
    select 'sales_invoice'::text source_type,i.id source_id,i.invoice_date document_date,i.invoice_number document_number,
      i.fiscal_year,i.party_name,round(i.vat_amount,2) output_vat,0::numeric input_vat,i.voucher_id
    from invoices i where i.user_id=uid and i.document_status in ('posted','credited') and i.invoice_date between p_from and p_to
      and (p_fiscal_year is null or i.fiscal_year=p_fiscal_year)
    union all
    select 'sales_credit_note',n.id,n.cn_date,n.cn_number,n.fiscal_year,n.party_name,-round(n.vat_amount,2),0,n.voucher_id
    from credit_notes n where n.user_id=uid and n.document_status='posted' and n.cn_date between p_from and p_to
      and (p_fiscal_year is null or n.fiscal_year=p_fiscal_year)
    union all
    select 'purchase_bill',b.id,b.bill_date,b.bill_number,b.fiscal_year,b.vendor_name,0,round(b.vat_amount,2),b.voucher_id
    from purchase_bills b where b.user_id=uid and b.document_status in ('posted','credited') and b.bill_date between p_from and p_to
      and (p_fiscal_year is null or b.fiscal_year=p_fiscal_year)
    union all
    select 'purchase_debit_note',n.id,n.dn_date,n.dn_number,n.fiscal_year,n.vendor_name,0,-round(n.vat_amount,2),n.voucher_id
    from debit_notes n where n.user_id=uid and n.document_status='posted' and n.dn_date between p_from and p_to
      and (p_fiscal_year is null or n.fiscal_year=p_fiscal_year)
  )
  select coalesce(jsonb_agg(to_jsonb(rows) order by document_date,source_type,document_number),'[]'::jsonb),
    coalesce(sum(output_vat),0),coalesce(sum(input_vat),0)
  into v_rows,v_output,v_input from rows;

  select coalesce(sum(case when a.system_code='vat_payable' then vl.credit-vl.debit else 0 end),0),
         coalesce(sum(case when a.system_code='vat_receivable' then vl.debit-vl.credit else 0 end),0)
    into v_output_ledger,v_input_ledger
    from voucher_lines vl join vouchers v on v.id=vl.voucher_id join accounts a on a.id=vl.account_id
   where v.user_id=uid and v.is_void=false and v.voucher_date between p_from and p_to
     and (p_fiscal_year is null or v.fiscal_year=p_fiscal_year)
     and a.system_code in ('vat_payable','vat_receivable');

  return jsonb_build_object('report','vat','from',p_from,'to',p_to,'fiscal_year',p_fiscal_year,'rows',v_rows,
    'output_vat',round(v_output,2),'input_vat',round(v_input,2),'net_vat_payable',round(v_output-v_input,2),
    'output_vat_ledger',round(v_output_ledger,2),'input_vat_ledger',round(v_input_ledger,2),
    'output_variance',round(v_output-v_output_ledger,2),'input_variance',round(v_input-v_input_ledger,2),
    'reconciled',abs(v_output-v_output_ledger)<=0.01 and abs(v_input-v_input_ledger)<=0.01);
end; $$;
revoke all on function get_vat_report(date,date,text) from public;
grant execute on function get_vat_report(date,date,text) to authenticated;

-- ------------------------------------------------------------
-- 13. Historical stock valuation and Inventory Asset comparison.
-- ------------------------------------------------------------
create or replace function get_stock_valuation_report(p_as_of date)
returns jsonb
language plpgsql
security definer
set search_path=public as $$
declare uid uuid:=auth.uid(); v_rows jsonb; v_stock numeric; v_ledger numeric;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  if p_as_of is null then raise exception 'As-of date is required.'; end if;

  with valued as (
    select i.id item_id,i.sku,i.name,i.unit,i.category_id,c.name category_name,
      coalesce(last_move.stock_after,first_future.stock_before,
        case when i.valuation_start_date is null or i.valuation_start_date<=p_as_of then i.current_stock else 0 end,0) quantity,
      coalesce(last_move.average_cost_after,first_future.average_cost_before,
        case when i.valuation_start_date is null or i.valuation_start_date<=p_as_of then i.average_cost else 0 end,0) average_cost,
      coalesce(last_move.value_after,first_future.value_before,
        case when i.valuation_start_date is null or i.valuation_start_date<=p_as_of then i.inventory_value else 0 end,0) inventory_value
    from inventory_items i
    left join item_categories c on c.id=i.category_id
    left join lateral (
      select m.stock_after,m.average_cost_after,m.value_after
      from inventory_movements m where m.user_id=uid and m.item_id=i.id and m.movement_date<=p_as_of
      order by m.movement_date desc,m.created_at desc,m.id desc limit 1
    ) last_move on true
    left join lateral (
      select m.stock_before,m.average_cost_before,m.value_before
      from inventory_movements m where m.user_id=uid and m.item_id=i.id and m.movement_date>p_as_of
      order by m.movement_date,m.created_at,m.id limit 1
    ) first_future on last_move.stock_after is null
    where i.user_id=uid and i.is_active=true and i.track_inventory=true and i.item_type='goods'
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'item_id',item_id,'sku',sku,'name',name,'unit',unit,'category_name',category_name,
    'quantity',round(quantity,3),'average_cost',round(average_cost,6),'inventory_value',round(inventory_value,2)
  ) order by name),'[]'::jsonb),coalesce(sum(inventory_value),0)
  into v_rows,v_stock from valued where abs(quantity)>0.0005 or abs(inventory_value)>0.005;

  select coalesce(closing_balance,0) into v_ledger
    from report_account_activity(null,p_as_of,null) where system_code='inventory_asset' limit 1;

  return jsonb_build_object('report','stock_valuation','as_of',p_as_of,'method','moving_weighted_average',
    'rows',v_rows,'stock_valuation',round(v_stock,2),'inventory_ledger_balance',round(coalesce(v_ledger,0),2),
    'difference',round(v_stock-coalesce(v_ledger,0),2),'reconciled',abs(v_stock-coalesce(v_ledger,0))<=0.01);
end; $$;
revoke all on function get_stock_valuation_report(date) from public;
grant execute on function get_stock_valuation_report(date) to authenticated;

commit;
