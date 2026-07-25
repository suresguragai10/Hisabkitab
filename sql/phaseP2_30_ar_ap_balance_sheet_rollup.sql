-- ============================================================
-- HisabKitab P2.30 -- Roll up party accounts on the Balance Sheet.
--
-- Every customer/vendor gets its own standalone GL account
-- (AR-0001, AR-0002, ...) rather than sharing one AR/AP control
-- account -- confirmed 2026-07-24 (see memory: ar-ap-architecture-
-- concern) that get_balance_sheet_report() lists every one
-- individually, so 100 customers would mean 100 separate receivable
-- lines instead of one "Accounts Receivable" total. This is a
-- report-level fix, not a schema redesign: the per-party accounts,
-- all posting logic, and the Ageing reports (which correctly show
-- per-party detail on purpose) are untouched. Only the Balance
-- Sheet's presentation changes -- party-type receivable/payable
-- accounts are now summed into one line each; every other account
-- (cash, inventory, fixed assets, equity, non-party liabilities,
-- etc.) still lists individually exactly as before.
--
-- report_account_activity() gains one new output column
-- (is_party_account) -- additive and safe: every existing caller
-- selects columns by name, not position, so nothing else breaks.
-- ============================================================

-- Adding a column changes the function's row type, which CREATE OR
-- REPLACE cannot do -- must drop first.
drop function if exists report_account_activity(date,date,text);

create or replace function report_account_activity(p_from date, p_to date, p_fiscal_year text default null::text)
returns table(account_id uuid, account_code text, account_name text, account_type text, report_class text, account_subtype text, normal_balance text, cash_flow_category text, parent_account_id uuid, system_code text, is_party_account boolean, opening_balance numeric, period_debit numeric, period_credit numeric, closing_balance numeric)
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'pg_temp'
as $$
declare
  uid uuid := get_workspace_owner();
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
    a.is_party_account,
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
  where a.user_id = uid
  group by a.id;
end;
$$;

create or replace function get_balance_sheet_report(p_as_of date)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'pg_temp'
as $$
declare
  uid uuid := get_workspace_owner();
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
  ), party_rows as (
    select
      null::uuid account_id, null::text account_code,
      case when account_subtype='receivable' then 'Accounts Receivable (all customers)'
           when account_subtype='payable' then 'Accounts Payable (all vendors)'
           else initcap(replace(account_subtype,'_',' '))||' (combined)' end account_name,
      report_class, account_subtype,
      round(case when report_class in ('current_asset','non_current_asset')
        then sum(closing_balance) else -sum(closing_balance) end,2) amount
    from activity
    where report_class in ('current_asset','non_current_asset','current_liability','non_current_liability','equity')
      and is_party_account = true
    group by report_class, account_subtype
    having abs(sum(closing_balance)) > 0.005
  ), non_party_rows as (
    select account_id,account_code,account_name,report_class,account_subtype,
      round(case when report_class in ('current_asset','non_current_asset')
        then closing_balance else -closing_balance end,2) amount
    from activity
    where report_class in ('current_asset','non_current_asset','current_liability','non_current_liability','equity')
      and coalesce(is_party_account,false) = false
      and abs(closing_balance)>0.005
  ), rows as (
    select * from party_rows
    union all
    select * from non_party_rows
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
  ) order by report_class,coalesce(account_code,''),account_name),'[]'::jsonb),
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
