-- ============================================================
-- HisabKitab Stage 5 preflight - structured Chart of Accounts
-- Run before phaseP0_5_structured_chart.sql.
-- Every row returned requires review. Informational legacy-opening
-- rows may be converted after the migration from the Chart of Accounts.
-- ============================================================

-- Missing prerequisite tables.
select 'missing_table' as issue_type, required_table as object_name, null::text as details
from (values
  ('accounts'), ('vouchers'), ('voucher_lines'), ('parties'), ('audit_log')
) r(required_table)
where to_regclass('public.' || required_table) is null;

-- Missing prerequisite account columns.
select 'missing_column' as issue_type,
       table_name || '.' || column_name as object_name,
       null::text as details
from (values
  ('accounts','id'), ('accounts','user_id'), ('accounts','name'),
  ('accounts','account_type'), ('accounts','group_name'),
  ('accounts','opening_balance'), ('accounts','opening_balance_type'),
  ('accounts','is_active'), ('accounts','is_party_account'),
  ('accounts','system_code'), ('vouchers','voucher_type'),
  ('vouchers','voucher_number'), ('vouchers','fiscal_year'),
  ('vouchers','voucher_date'), ('voucher_lines','account_id')
) r(table_name,column_name)
where not exists (
  select 1 from information_schema.columns c
  where c.table_schema='public'
    and c.table_name=r.table_name
    and c.column_name=r.column_name
);

-- Required functions. Parameter names are intentionally ignored.
select 'missing_function' as issue_type,
       required_signature as object_name,
       null::text as details
from (values
  ('write_audit_log(text,text,text,jsonb,jsonb)'),
  ('resolve_system_account(text)'),
  ('post_voucher(text,text,date,text,jsonb)')
) r(required_signature)
where to_regprocedure('public.' || required_signature) is null;

-- Invalid legacy account types would prevent structured classification.
select 'invalid_account_type' as issue_type,
       id::text as object_name,
       coalesce(name,'') || ' / ' || coalesce(account_type,'<null>') as details
from public.accounts
where account_type is null
   or account_type not in ('asset','liability','equity','income','expense');

-- Duplicate system codes must be resolved before structured protection.
select 'duplicate_system_code' as issue_type,
       user_id::text || ':' || system_code as object_name,
       count(*)::text || ' accounts' as details
from public.accounts
where system_code is not null
group by user_id, system_code
having count(*) > 1;

-- Informational: these legacy fields will remain read-only until converted
-- into a balanced opening journal.
select 'legacy_opening_balance' as issue_type,
       user_id::text as object_name,
       count(*)::text || ' account(s), debit=' ||
       round(sum(case when opening_balance_type='debit' then opening_balance else 0 end),2)::text ||
       ', credit=' ||
       round(sum(case when opening_balance_type='credit' then opening_balance else 0 end),2)::text as details
from public.accounts
where opening_balance <> 0
group by user_id;
