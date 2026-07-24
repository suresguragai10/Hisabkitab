-- ============================================================
-- HisabKitab — Accounting Foundation Health Check
--
-- Run this anytime to verify the core accounting engine is still
-- sound. IMPORTANT: replace the UUID below with whichever business's
-- user id you want to check (Authentication -> Users in Supabase
-- Studio) -- these reporting functions all require a real logged-in
-- user context, so this can't run as plain `postgres`. Run the
-- set_config line and the rest of this file together, in the same
-- query box, in one Run click.
--
-- One combined query, so there's nothing to miss from running the
-- wrong statement in a multi-statement box -- every check returns as
-- one row in one result set: PASS or FAIL, with a plain-language
-- detail.
--
-- Built after the Phase 1 accounting foundation audit (2026-07-24),
-- which verified posting integrity, golden-scenario ledger
-- correctness, report reconciliation, and inventory valuation math
-- against real data -- and found + fixed one real bug ("both"
-- customer+vendor parties posting purchases to the wrong account
-- type). This script re-checks the same invariants going forward.
-- ============================================================

select set_config('request.jwt.claims', json_build_object('sub', 'REPLACE-WITH-USER-UUID')::text, true);

select 'Unbalanced vouchers' as check_name,
       case when count(*) = 0 then 'PASS' else 'FAIL' end as status,
       case when count(*) = 0 then 'None found'
            else count(*)::text || ' unbalanced voucher(s) -- debits must always equal credits' end as detail
from (
  select v.id
  from vouchers v join voucher_lines vl on vl.voucher_id = v.id
  where v.is_void = false
  group by v.id
  having abs(sum(vl.debit) - sum(vl.credit)) > 0.005
) unbalanced

union all

select 'Balance Sheet reconciliation',
       case when coalesce((get_balance_sheet_report(current_date)->>'balanced')::boolean, false) then 'PASS' else 'FAIL' end,
       'Assets vs Liabilities+Equity difference: ' || coalesce(get_balance_sheet_report(current_date)->>'difference', 'unknown')

union all

select 'Trial Balance reconciliation',
       case when coalesce((get_trial_balance_report(current_date)->>'balanced')::boolean, false) then 'PASS' else 'FAIL' end,
       'Total debit vs credit difference: ' || coalesce(get_trial_balance_report(current_date)->>'difference', 'unknown')

union all

select '"Both" customer+vendor parties have a proper payable account',
       case when count(*) = 0 then 'PASS' else 'FAIL' end,
       case when count(*) = 0 then 'None found'
            else count(*)::text || ' "both"-type part(y/ies) still missing a payable account -- run update_contact() for each' end
from parties where party_type = 'both' and payable_account_id is null

union all

select 'Inventory ledger reconciliation',
       case when coalesce((get_inventory_reconciliation()->>'difference')::numeric, 1) = 0
             and coalesce((get_inventory_reconciliation()->>'negative_stock_items')::int, 1) = 0
             and coalesce((get_inventory_reconciliation()->>'unvalued_stock_items')::int, 1) = 0
            then 'PASS' else 'FAIL' end,
       'Stock valuation vs GL difference: ' || (get_inventory_reconciliation()->>'difference')
       || ' | negative-stock items: ' || (get_inventory_reconciliation()->>'negative_stock_items')
       || ' | unvalued-stock items: ' || (get_inventory_reconciliation()->>'unvalued_stock_items')

union all

select 'VAT return reconciliation (all prepared/filed returns)',
       case when count(*) filter (where not coalesce((snapshot->>'reconciled')::boolean, false)) = 0 then 'PASS' else 'FAIL' end,
       count(*) filter (where not coalesce((snapshot->>'reconciled')::boolean, false))::text
       || ' unreconciled out of ' || count(*)::text || ' total VAT return(s)'
from vat_returns;
