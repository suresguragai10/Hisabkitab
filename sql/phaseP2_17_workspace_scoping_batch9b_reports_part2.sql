-- ============================================================
-- HisabKitab P2.17 -- Workspace-scoping fix, batch 9b: Reports (part
-- 2 of 2).
--
-- Part of the larger workspace-scoping remediation (see memory:
-- workspace_scoping_gap.md). Fetched live and fixed with the minimal,
-- mechanical change: the uid variable's source only (auth.uid() ->
-- get_workspace_owner()). No other logic touched. Each function's
-- original search_path setting preserved exactly as found live.
-- ============================================================

create or replace function report_account_activity(p_from date, p_to date, p_fiscal_year text default null::text)
returns table(account_id uuid, account_code text, account_name text, account_type text, report_class text, account_subtype text, normal_balance text, cash_flow_category text, parent_account_id uuid, system_code text, opening_balance numeric, period_debit numeric, period_credit numeric, closing_balance numeric)
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

create or replace function get_trial_balance_report(p_as_of date)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'pg_temp'
as $$
declare
  uid uuid := get_workspace_owner();
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

create or replace function get_stock_valuation_report(p_as_of date)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'pg_temp'
as $$
declare uid uuid:=get_workspace_owner(); v_rows jsonb; v_stock numeric; v_ledger numeric;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  if p_as_of is null then raise exception 'As-of date is required.'; end if;

  with valued as (
    select i.id item_id,i.sku,i.name,i.unit,i.category_id,c.name category_name,i.is_active,
      coalesce(last_move.stock_after,first_future.stock_before,
        case when i.valuation_start_date is null or i.valuation_start_date<=p_as_of then i.current_stock else 0 end,0) quantity,
      coalesce(last_move.average_cost_after,first_future.average_cost_before,
        case when i.valuation_start_date is null or i.valuation_start_date<=p_as_of then i.average_cost else 0 end,0) average_cost,
      coalesce(last_move.value_after,first_future.value_before,
        case when i.valuation_start_date is null or i.valuation_start_date<=p_as_of then i.inventory_value else 0 end,0) inventory_value
    from inventory_items i
    left join item_categories c on c.id=i.category_id and c.user_id=uid
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
    where i.user_id=uid and i.track_inventory=true and i.item_type='goods'
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'item_id',item_id,'sku',sku,'name',name,'unit',unit,'category_name',category_name,'is_active',is_active,
    'quantity',round(quantity,3),'average_cost',round(average_cost,6),'inventory_value',round(inventory_value,2)
  ) order by name),'[]'::jsonb),coalesce(sum(inventory_value),0)
  into v_rows,v_stock from valued where abs(quantity)>0.0005 or abs(inventory_value)>0.005;

  select coalesce(sum(closing_balance),0) into v_ledger
    from report_account_activity(null,p_as_of,null) where system_code='inventory_asset';

  return jsonb_build_object('report','stock_valuation','as_of',p_as_of,'method','moving_weighted_average',
    'rows',v_rows,'stock_valuation',round(v_stock,2),'inventory_ledger_balance',round(coalesce(v_ledger,0),2),
    'difference',round(v_stock-coalesce(v_ledger,0),2),'reconciled',abs(v_stock-coalesce(v_ledger,0))<=0.01);
end; $$;

create or replace function get_vat_report(p_from date, p_to date, p_fiscal_year text default null::text)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'pg_temp'
as $$
declare uid uuid:=get_workspace_owner(); v_rows jsonb;
  v_sales_taxable numeric; v_sales_zero numeric; v_sales_exempt numeric; v_sales_oos numeric;
  v_purchase_taxable numeric; v_purchase_zero numeric; v_purchase_exempt numeric; v_purchase_oos numeric;
  v_output numeric; v_input numeric; v_output_ledger numeric; v_input_ledger numeric;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  if p_from is null or p_to is null or p_from>p_to then raise exception 'A valid date range is required.'; end if;

  with line_events as (
    select 'sales_invoice'::text source_type,i.id source_id,pv.voucher_date document_date,
      i.invoice_number document_number,pv.fiscal_year,i.party_name,l.vat_treatment,
      l.amount,l.vat_amount,1 sign,'sale'::text side,pv.id voucher_id
    from invoices i
    join invoice_lines l on l.invoice_id=i.id
    join vouchers pv on pv.id=i.voucher_id and pv.user_id=uid and pv.is_void=false
    where i.user_id=uid

    union all
    select 'sales_invoice_cancellation',i.id,cv.voucher_date,i.invoice_number,cv.fiscal_year,i.party_name,
      l.vat_treatment,l.amount,l.vat_amount,-1,'sale',cv.id
    from invoices i
    join invoice_lines l on l.invoice_id=i.id
    join vouchers cv on cv.id=i.cancellation_voucher_id and cv.user_id=uid and cv.is_void=false
    where i.user_id=uid

    union all
    select 'sales_credit_note',n.id,pv.voucher_date,n.cn_number,pv.fiscal_year,n.party_name,
      l.vat_treatment,l.amount,l.vat_amount,-1,'sale',pv.id
    from credit_notes n
    join credit_note_lines l on l.credit_note_id=n.id
    join vouchers pv on pv.id=n.voucher_id and pv.user_id=uid and pv.is_void=false
    where n.user_id=uid

    union all
    select 'sales_credit_note_cancellation',n.id,cv.voucher_date,n.cn_number,cv.fiscal_year,n.party_name,
      l.vat_treatment,l.amount,l.vat_amount,1,'sale',cv.id
    from credit_notes n
    join credit_note_lines l on l.credit_note_id=n.id
    join vouchers cv on cv.id=n.cancellation_voucher_id and cv.user_id=uid and cv.is_void=false
    where n.user_id=uid

    union all
    select 'purchase_bill',b.id,pv.voucher_date,b.bill_number,pv.fiscal_year,b.vendor_name,
      l.vat_treatment,l.amount,l.vat_amount,1,'purchase',pv.id
    from purchase_bills b
    join purchase_bill_lines l on l.bill_id=b.id
    join vouchers pv on pv.id=b.voucher_id and pv.user_id=uid and pv.is_void=false
    where b.user_id=uid

    union all
    select 'purchase_bill_cancellation',b.id,cv.voucher_date,b.bill_number,cv.fiscal_year,b.vendor_name,
      l.vat_treatment,l.amount,l.vat_amount,-1,'purchase',cv.id
    from purchase_bills b
    join purchase_bill_lines l on l.bill_id=b.id
    join vouchers cv on cv.id=b.cancellation_voucher_id and cv.user_id=uid and cv.is_void=false
    where b.user_id=uid

    union all
    select 'purchase_debit_note',n.id,pv.voucher_date,n.dn_number,pv.fiscal_year,n.vendor_name,
      l.vat_treatment,l.amount,l.vat_amount,-1,'purchase',pv.id
    from debit_notes n
    join debit_note_lines l on l.debit_note_id=n.id
    join vouchers pv on pv.id=n.voucher_id and pv.user_id=uid and pv.is_void=false
    where n.user_id=uid

    union all
    select 'purchase_debit_note_cancellation',n.id,cv.voucher_date,n.dn_number,cv.fiscal_year,n.vendor_name,
      l.vat_treatment,l.amount,l.vat_amount,1,'purchase',cv.id
    from debit_notes n
    join debit_note_lines l on l.debit_note_id=n.id
    join vouchers cv on cv.id=n.cancellation_voucher_id and cv.user_id=uid and cv.is_void=false
    where n.user_id=uid
  ), selected_events as (
    select * from line_events
    where document_date between p_from and p_to
      and (p_fiscal_year is null or fiscal_year=p_fiscal_year)
  ), docs as (
    select source_type,source_id,document_date,document_number,fiscal_year,party_name,side,voucher_id,
      round(sum(case when vat_treatment='standard' then sign*amount else 0 end),2) taxable_amount,
      round(sum(case when vat_treatment='zero_rated' then sign*amount else 0 end),2) zero_rated_amount,
      round(sum(case when vat_treatment='exempt' then sign*amount else 0 end),2) exempt_amount,
      round(sum(case when vat_treatment='out_of_scope' then sign*amount else 0 end),2) out_of_scope_amount,
      round(sum(sign*vat_amount),2) vat_amount
    from selected_events
    group by source_type,source_id,document_date,document_number,fiscal_year,party_name,side,voucher_id
  )
  select coalesce(jsonb_agg(jsonb_build_object('source_type',source_type,'source_id',source_id,'document_date',document_date,
      'document_number',document_number,'fiscal_year',fiscal_year,'party_name',party_name,'side',side,'taxable_amount',taxable_amount,
      'zero_rated_amount',zero_rated_amount,'exempt_amount',exempt_amount,'out_of_scope_amount',out_of_scope_amount,
      'output_vat',case when side='sale' then vat_amount else 0 end,'input_vat',case when side='purchase' then vat_amount else 0 end,'voucher_id',voucher_id)
      order by document_date,source_type,document_number,voucher_id),'[]'::jsonb),
    coalesce(sum(taxable_amount) filter(where side='sale'),0),coalesce(sum(zero_rated_amount) filter(where side='sale'),0),
    coalesce(sum(exempt_amount) filter(where side='sale'),0),coalesce(sum(out_of_scope_amount) filter(where side='sale'),0),
    coalesce(sum(taxable_amount) filter(where side='purchase'),0),coalesce(sum(zero_rated_amount) filter(where side='purchase'),0),
    coalesce(sum(exempt_amount) filter(where side='purchase'),0),coalesce(sum(out_of_scope_amount) filter(where side='purchase'),0),
    coalesce(sum(vat_amount) filter(where side='sale'),0),coalesce(sum(vat_amount) filter(where side='purchase'),0)
  into v_rows,v_sales_taxable,v_sales_zero,v_sales_exempt,v_sales_oos,v_purchase_taxable,v_purchase_zero,v_purchase_exempt,v_purchase_oos,v_output,v_input from docs;

  select coalesce(sum(case when a.system_code='vat_payable' then vl.credit-vl.debit else 0 end),0),
    coalesce(sum(case when a.system_code='vat_receivable' then vl.debit-vl.credit else 0 end),0)
  into v_output_ledger,v_input_ledger
  from voucher_lines vl
  join vouchers v on v.id=vl.voucher_id
  join accounts a on a.id=vl.account_id and a.user_id=uid
  where v.user_id=uid and v.is_void=false and v.voucher_date between p_from and p_to
    and (p_fiscal_year is null or v.fiscal_year=p_fiscal_year)
    and a.system_code in ('vat_payable','vat_receivable');

  return jsonb_build_object('report','vat','from',p_from,'to',p_to,'fiscal_year',p_fiscal_year,'rows',v_rows,
    'sales_taxable',round(v_sales_taxable,2),'sales_zero_rated',round(v_sales_zero,2),'sales_exempt',round(v_sales_exempt,2),'sales_out_of_scope',round(v_sales_oos,2),
    'purchase_taxable',round(v_purchase_taxable,2),'purchase_zero_rated',round(v_purchase_zero,2),'purchase_exempt',round(v_purchase_exempt,2),'purchase_out_of_scope',round(v_purchase_oos,2),
    'output_vat',round(v_output,2),'input_vat',round(v_input,2),'net_vat_payable',round(v_output-v_input,2),
    'output_vat_ledger',round(v_output_ledger,2),'input_vat_ledger',round(v_input_ledger,2),
    'output_variance',round(v_output-v_output_ledger,2),'input_variance',round(v_input-v_input_ledger,2),
    'reconciled',abs(v_output-v_output_ledger)<=0.01 and abs(v_input-v_input_ledger)<=0.01);
end; $$;

create or replace function get_report_fiscal_years()
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public', 'pg_temp'
as $$
declare
  uid uuid := get_workspace_owner();
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

create or replace function get_annex13_report(p_period_id uuid)
returns table(party_name text, party_pan text, opening_balance numeric, exempted_purchase numeric, vatable_purchase numeric, vat_on_purchase numeric, exempted_sales numeric, vatable_sales numeric, vat_on_sales numeric, closing_balance numeric)
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  uid uuid := get_workspace_owner();
  p fiscal_periods%rowtype;
  v_report jsonb;
begin
  if uid is null then raise exception 'Not authenticated'; end if;

  select * into p from fiscal_periods where id = p_period_id and user_id = uid;
  if not found then raise exception 'Fiscal period not found.'; end if;

  v_report := get_vat_report(p.from_date, p.to_date, p.fiscal_year);

  return query
  with doc_rows as (
    select
      (r->>'party_name') as doc_party_name,
      (r->>'side') as side,
      coalesce((r->>'exempt_amount')::numeric, 0) as exempt_amount,
      coalesce((r->>'taxable_amount')::numeric, 0) as taxable_amount,
      coalesce((r->>'output_vat')::numeric, 0) as output_vat,
      coalesce((r->>'input_vat')::numeric, 0) as input_vat
    from jsonb_array_elements(v_report->'rows') r
  ),
  grouped as (
    select
      doc_party_name,
      round(coalesce(sum(exempt_amount)  filter (where side = 'purchase'), 0), 2) as exempted_purchase,
      round(coalesce(sum(taxable_amount) filter (where side = 'purchase'), 0), 2) as vatable_purchase,
      round(coalesce(sum(input_vat)      filter (where side = 'purchase'), 0), 2) as vat_on_purchase,
      round(coalesce(sum(exempt_amount)  filter (where side = 'sale'), 0), 2) as exempted_sales,
      round(coalesce(sum(taxable_amount) filter (where side = 'sale'), 0), 2) as vatable_sales,
      round(coalesce(sum(output_vat)     filter (where side = 'sale'), 0), 2) as vat_on_sales
    from doc_rows
    group by doc_party_name
  ),
  balances as (
    select act.account_id, act.account_name, pt.pan_number,
           round(act.opening_balance, 2) as opening_balance,
           round(act.closing_balance, 2) as closing_balance
    from report_account_activity(p.from_date, p.to_date, p.fiscal_year) act
    join parties pt on pt.account_id = act.account_id and pt.user_id = uid
  )
  select
    coalesce(b.account_name, g.doc_party_name) as party_name,
    coalesce(b.pan_number, '') as party_pan,
    coalesce(b.opening_balance, 0) as opening_balance,
    coalesce(g.exempted_purchase, 0) as exempted_purchase,
    coalesce(g.vatable_purchase, 0) as vatable_purchase,
    coalesce(g.vat_on_purchase, 0) as vat_on_purchase,
    coalesce(g.exempted_sales, 0) as exempted_sales,
    coalesce(g.vatable_sales, 0) as vatable_sales,
    coalesce(g.vat_on_sales, 0) as vat_on_sales,
    coalesce(b.closing_balance, 0) as closing_balance
  from balances b
  full outer join grouped g on g.doc_party_name = b.account_name
  where coalesce(b.opening_balance, 0) <> 0 or coalesce(b.closing_balance, 0) <> 0
     or coalesce(g.vatable_purchase, 0) <> 0 or coalesce(g.vatable_sales, 0) <> 0
     or coalesce(g.exempted_purchase, 0) <> 0 or coalesce(g.exempted_sales, 0) <> 0
  order by 1;
end;
$$;

create or replace function get_tds_reconciliation(p_from date, p_to date, p_fiscal_year text default null::text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare uid uuid:=get_workspace_owner(); v_deducted numeric; v_remitted numeric; v_pending numeric; v_ledger numeric; v_rows jsonb;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  if p_from is null or p_to is null or p_from>p_to then raise exception 'A valid date range is required.'; end if;

  select coalesce(sum(e.tds_amount),0),
    coalesce(jsonb_agg(jsonb_build_object('id',e.id,'entry_date',e.entry_date,'payee_name',e.payee_name,'payee_pan',e.payee_pan,'tds_type',e.tds_type,
      'gross_amount',e.gross_amount,'tds_rate',e.tds_rate,'tds_amount',e.tds_amount,'status',e.status,'due_date',e.due_date,'reference',e.reference)
      order by e.entry_date,e.id),'[]'::jsonb)
  into v_deducted,v_rows
  from tds_entries e
  where e.user_id=uid and e.entry_date between p_from and p_to
    and (p_fiscal_year is null or e.fiscal_year=p_fiscal_year)
    and (e.reversed_at is null or e.reversed_at::date>p_to);

  select coalesce(sum(r.total_tds),0) into v_remitted
  from tds_remittances r
  where r.user_id=uid and r.remittance_date between p_from and p_to
    and (p_fiscal_year is null or r.fiscal_year=p_fiscal_year);

  select coalesce(sum(e.tds_amount),0) into v_pending
  from tds_entries e
  left join tds_remittances r on r.id=e.remittance_id and r.user_id=uid
  where e.user_id=uid and e.entry_date<=p_to
    and (p_fiscal_year is null or e.fiscal_year=p_fiscal_year)
    and (e.reversed_at is null or e.reversed_at::date>p_to)
    and (r.id is null or r.remittance_date>p_to);

  select coalesce(sum(vl.credit-vl.debit),0) into v_ledger
  from accounts a join voucher_lines vl on vl.account_id=a.id join vouchers v on v.id=vl.voucher_id
  where a.user_id=uid and a.system_code='tds_payable' and v.user_id=uid and v.is_void=false and v.voucher_date<=p_to
    and (p_fiscal_year is null or v.fiscal_year=p_fiscal_year);

  return jsonb_build_object('from',p_from,'to',p_to,'fiscal_year',p_fiscal_year,'rows',v_rows,
    'deducted',round(v_deducted,2),'remitted',round(v_remitted,2),'pending',round(v_pending,2),
    'tds_payable_ledger',round(v_ledger,2),'difference',round(v_pending-v_ledger,2),
    'reconciled',abs(v_pending-v_ledger)<=0.01);
end; $$;

create or replace function get_inventory_reconciliation()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  uid uuid := get_workspace_owner();
  v_inventory_account uuid;
  v_stock_value numeric(18,2);
  v_ledger_value numeric(18,2);
  v_tracked_items integer;
  v_negative_items integer;
  v_unvalued_items integer;
  v_legacy_movements integer;
begin
  if uid is null then raise exception 'Not authenticated'; end if;

  v_inventory_account := resolve_system_account('inventory_asset');

  select coalesce(round(sum(inventory_value), 2), 0),
         count(*)::integer,
         count(*) filter (where current_stock < -0.0005)::integer,
         count(*) filter (where current_stock > 0.0005 and inventory_value <= 0.005)::integer
    into v_stock_value, v_tracked_items, v_negative_items, v_unvalued_items
    from inventory_items
   where user_id = uid and is_active = true
     and track_inventory = true and item_type = 'goods';

  select round(
    coalesce(case when a.opening_balance_type = 'debit' then a.opening_balance else -a.opening_balance end, 0)
    + coalesce(sum(case when v.is_void = false then vl.debit - vl.credit else 0 end), 0),
    2
  )
    into v_ledger_value
    from accounts a
    left join voucher_lines vl on vl.account_id = a.id
    left join vouchers v on v.id = vl.voucher_id
   where a.id = v_inventory_account and a.user_id = uid
   group by a.id, a.opening_balance, a.opening_balance_type;

  select count(*)::integer into v_legacy_movements
    from inventory_movements
   where user_id = uid and is_legacy = true;

  return jsonb_build_object(
    'method', 'moving_weighted_average',
    'stock_valuation', coalesce(v_stock_value, 0),
    'inventory_ledger_balance', coalesce(v_ledger_value, 0),
    'difference', round(coalesce(v_stock_value, 0) - coalesce(v_ledger_value, 0), 2),
    'tracked_items', coalesce(v_tracked_items, 0),
    'negative_stock_items', coalesce(v_negative_items, 0),
    'unvalued_stock_items', coalesce(v_unvalued_items, 0),
    'legacy_movements', coalesce(v_legacy_movements, 0),
    'as_of', current_date
  );
end;
$$;

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
  return jsonb_build_object('cash',v_cash,'receivables',v_receivables,'payables',v_payables,'sales_this',v_sales_this,'sales_last',v_sales_last,
    'vat_payable',v_vat_payable,'stock_value',v_stock_value,'low_stock',v_low_stock,'invoice_count',v_invoice_count,'overdue_count',v_overdue_count,
    'overdue_amount',v_overdue_amount,'invoice_outstanding',v_invoice_outstanding,'bill_outstanding',v_bill_outstanding,
    'vat_deadline',to_char(date_trunc('month',current_date)+interval '1 month'+interval '14 days','YYYY-MM-DD'));
end;
$$;

create or replace function next_doc_number(p_doc_type text, p_fiscal_year text)
returns integer
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  uid uuid := get_workspace_owner();
  n   integer;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  insert into doc_sequences (user_id, doc_type, fiscal_year, last_num)
  values (uid, p_doc_type, p_fiscal_year, 1)
  on conflict (user_id, doc_type, fiscal_year)
  do update set last_num = doc_sequences.last_num + 1
  returning last_num into n;
  return n;
end; $$;
