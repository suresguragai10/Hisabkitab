-- ============================================================
-- HisabKitab P2.1 — IRD Annex 13 party-wise VAT register.
--
-- Party Name | Party PAN | Opening Balance | Exempted Purchase |
-- Vatable Purchase | VAT on Purchase | Exempted Sales |
-- Vatable Sales | VAT on Sales | Closing Balance
--
-- Reuses get_vat_report()'s already-trusted per-document VAT
-- classification (same source data as the VAT filing screen),
-- grouped by party instead of by document, and joins each party's
-- real opening/closing ledger balance from report_account_activity()
-- so the export reconciles to the actual books, not just the VAT
-- side. Only rows with a non-zero balance or VAT movement in the
-- period are included.
-- ============================================================

create or replace function get_annex13_report(p_period_id uuid)
returns table(
  party_name text,
  party_pan text,
  opening_balance numeric,
  exempted_purchase numeric,
  vatable_purchase numeric,
  vat_on_purchase numeric,
  exempted_sales numeric,
  vatable_sales numeric,
  vat_on_sales numeric,
  closing_balance numeric
)
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
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

revoke all on function get_annex13_report(uuid) from public;
grant execute on function get_annex13_report(uuid) to authenticated;
