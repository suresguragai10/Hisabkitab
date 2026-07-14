-- ============================================================
-- HisabKitab Stage 5 verification
-- ============================================================

select column_name, data_type, is_nullable
from information_schema.columns
where table_schema='public' and table_name='accounts'
  and column_name in (
    'account_code','parent_account_id','report_class','account_subtype',
    'normal_balance','cash_flow_category','is_control_account',
    'is_system_account','allow_manual_posting'
  )
order by column_name;

select proname as function_name,
       pg_get_function_identity_arguments(oid) as arguments
from pg_proc
where proname in (
  'create_structured_account','update_structured_account',
  'deactivate_structured_account','post_opening_journal',
  'migrate_legacy_opening_balances','resolve_system_account'
)
order by proname;

select account_code, count(*)
from accounts
group by user_id, account_code
having count(*) > 1;

select id, name, account_type, report_class
from accounts
where not (
  (account_type='asset' and report_class in ('current_asset','non_current_asset')) or
  (account_type='liability' and report_class in ('current_liability','non_current_liability')) or
  (account_type='equity' and report_class='equity') or
  (account_type='income' and report_class in ('revenue','other_income')) or
  (account_type='expense' and report_class in ('cost_of_sales','operating_expense','other_expense'))
);

select a.id, a.name, a.parent_account_id
from accounts a
left join accounts p on p.id=a.parent_account_id and p.user_id=a.user_id
where a.parent_account_id is not null and p.id is null;

select user_id,
       round(sum(debit),2) as total_debit,
       round(sum(credit),2) as total_credit,
       round(sum(debit)-sum(credit),2) as difference
from trial_balance
group by user_id
having abs(sum(debit)-sum(credit)) > 0.005;

select
  has_table_privilege('authenticated','public.accounts','INSERT') as account_insert,
  has_table_privilege('authenticated','public.accounts','UPDATE') as account_update,
  has_table_privilege('authenticated','public.accounts','DELETE') as account_delete,
  has_table_privilege('authenticated','public.accounts','SELECT') as account_select;
