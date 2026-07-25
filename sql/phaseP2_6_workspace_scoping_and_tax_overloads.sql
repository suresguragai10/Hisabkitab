-- ============================================================
-- HisabKitab P2.6 -- Workspace-scoping consistency + tax function
-- overload cleanup + VAT direct-filing removal.
--
-- Found during an independent audit cross-check (2026-07-25): several
-- functions used auth.uid() directly for data scoping instead of
-- get_workspace_owner(), which silently breaks them for an invited
-- accountant/staff member acting inside someone else's workspace --
-- their calls would operate on their own empty personal workspace
-- instead of the business they were invited to. Dormant today (no
-- effect for a solo owner, since get_workspace_owner() falls back to
-- auth.uid() when there's no active_workspace switch), but must be
-- fixed before any team member is invited to use these specific
-- screens (fiscal periods, VAT prepare/review, TDS, period lock).
--
-- NOTE: this does NOT touch the core posting engine (post_voucher,
-- post_invoice_draft, post_bill_draft, create_contact, etc.) -- that
-- has the same auth.uid()-direct pattern across ~89 occurrences in 16
-- files, but is deliberately out of scope here. Rewriting the entire
-- accounting engine's identity handling needs its own careful,
-- dedicated pass (see memory: workspace_scoping_gap.md), not a rushed
-- addition to this fix.
--
-- Also folds in the known create_tds_entry/get_tax_rates overload bug
-- (deferred earlier this project, now confirmed live): Postgres's
-- exact-arity-wins rule means the app was silently calling the OLDER,
-- less complete create_tds_entry (ad-hoc per-type expense accounts,
-- no PAN compliance check) instead of the current one. Dropping the
-- stale overload so only one definition can ever be called.
--
-- Also removes direct VAT filing from the product per founder
-- decision following the independent audit: HisabKitab's VAT scope is
-- Prepare -> Review -> Export Annex 13 only; submission to IRD happens
-- separately. file_vat_return is retained in the database (harmless,
-- unreachable) but access is revoked so nothing can call it.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Drop the stale create_tds_entry overload. The frontend always
-- calls with exactly 11 named args, which -- per Postgres's
-- exact-arity-wins overload resolution -- means this OLDER copy has
-- been winning over the newer 12-arg version this whole time.
-- ------------------------------------------------------------
drop function if exists create_tds_entry(date,text,text,text,text,uuid,numeric,numeric,text,text,text);

-- Re-create the (only remaining) create_tds_entry with corrected
-- workspace scoping. Logic otherwise unchanged from the 12-arg version
-- already live (resolve_system_account, PAN compliance check).
create or replace function create_tds_entry(
  p_date date, p_fiscal_year text, p_tds_type text, p_payee_name text, p_payee_pan text,
  p_payee_id uuid, p_gross numeric, p_rate numeric, p_mode text, p_reference text, p_notes text,
  p_expense_account_id uuid default null::uuid
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := get_workspace_owner();
  v_id uuid; v_tds numeric(14,2); v_net numeric(14,2); v_cash uuid; v_tds_acct uuid; v_expense uuid; v_voucher uuid; v_due_day integer; v_due date; v_period_end date;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  if p_date is null or nullif(btrim(p_fiscal_year),'') is null then raise exception 'Date and fiscal year are required.'; end if;
  if nullif(btrim(p_payee_name),'') is null then raise exception 'Payee name is required.'; end if;
  if p_gross<=0 or p_rate<=0 or p_rate>100 then raise exception 'Gross amount and a valid positive TDS rate are required.'; end if;
  if lower(p_mode) not in ('cash','bank') then raise exception 'Payment mode must be cash or bank.'; end if;
  if p_payee_id is not null and not exists(select 1 from parties where id=p_payee_id and user_id=uid) then raise exception 'Payee does not belong to this business.'; end if;
  insert into tax_compliance_settings(user_id) values(uid) on conflict(user_id) do nothing;
  if (select require_pan_for_tds from tax_compliance_settings where user_id=uid) and nullif(btrim(p_payee_pan),'') is null then raise exception 'Payee PAN is required by your compliance settings.'; end if;
  v_expense:=coalesce(p_expense_account_id,resolve_system_account('tds_expense'));
  if not exists(select 1 from accounts where id=v_expense and user_id=uid and is_active=true and report_class in ('cost_of_sales','operating_expense','other_expense')) then raise exception 'Select an active expense account owned by this business.'; end if;
  v_tds:=round(p_gross*p_rate/100,2); v_net:=round(p_gross-v_tds,2);
  if v_tds<=0 or v_net<0 then raise exception 'Invalid TDS calculation.'; end if;
  v_cash:=resolve_system_account(lower(p_mode)); v_tds_acct:=resolve_system_account('tds_payable');
  v_voucher:=post_voucher('payment',p_fiscal_year,p_date,'TDS deduction - '||btrim(p_payee_name),jsonb_build_array(
    jsonb_build_object('account_id',v_expense,'debit',round(p_gross,2),'credit',0,'description',p_tds_type||' gross expense'),
    jsonb_build_object('account_id',v_cash,'debit',0,'credit',v_net,'description','Net paid to '||btrim(p_payee_name)),
    jsonb_build_object('account_id',v_tds_acct,'debit',0,'credit',v_tds,'description','TDS withheld')
  ));
  select tds_due_day into v_due_day from tax_compliance_settings where user_id=uid;
  select to_date into v_period_end
    from fiscal_periods
   where user_id=uid and p_date between from_date and to_date
   order by from_date
   limit 1;
  v_due:=coalesce(v_period_end,p_date)+v_due_day;
  insert into tds_entries(user_id,entry_date,fiscal_year,tds_type,payee_name,payee_pan,payee_id,expense_account_id,gross_amount,tds_rate,tds_amount,net_amount,
    payment_mode,reference,notes,status,due_date,voucher_id)
  values(uid,p_date,btrim(p_fiscal_year),btrim(p_tds_type),btrim(p_payee_name),nullif(btrim(p_payee_pan),''),p_payee_id,v_expense,round(p_gross,2),round(p_rate,4),v_tds,v_net,
    lower(p_mode),nullif(btrim(p_reference),''),nullif(btrim(p_notes),''),'deducted',v_due,v_voucher) returning id into v_id;
  update vouchers set source_document_type='tds_entry',source_document_id=v_id where id=v_voucher and user_id=uid;
  perform write_audit_log('create','tds_entries',v_id::text,null,jsonb_build_object('gross',p_gross,'tds',v_tds,'voucher_id',v_voucher));
  return v_id;
end; $$;

grant execute on function create_tds_entry(date,text,text,text,text,uuid,numeric,numeric,text,text,text,uuid) to authenticated;
revoke all on function create_tds_entry(date,text,text,text,text,uuid,numeric,numeric,text,text,text,uuid) from public, anon;

-- ------------------------------------------------------------
-- 2. Fix workspace scoping on the remaining functions. Logic is
-- otherwise byte-for-byte identical to what's live -- only the uid
-- source changes.
-- ------------------------------------------------------------

create or replace function create_fiscal_periods(p_fiscal_year text, p_periods jsonb)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare uid uuid:=get_workspace_owner(); r record; v_prev_to date; v_num integer:=0;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  if nullif(btrim(p_fiscal_year),'') is null then raise exception 'Fiscal year is required.'; end if;
  if p_periods is null or jsonb_typeof(p_periods)<>'array' or jsonb_array_length(p_periods)<>12 then raise exception 'Exactly 12 fiscal periods are required.'; end if;
  if exists(select 1 from fiscal_periods where user_id=uid and fiscal_year=p_fiscal_year) then raise exception 'Periods already exist for fiscal year %.',p_fiscal_year; end if;
  for r in select value,(value->>'from_date')::date from_date,(value->>'to_date')::date to_date from jsonb_array_elements(p_periods) order by (value->>'from_date')::date loop
    v_num:=v_num+1;
    if r.from_date is null or r.to_date is null or r.to_date<r.from_date then raise exception 'Period % has an invalid date range.',v_num; end if;
    if v_prev_to is not null and r.from_date<>v_prev_to+1 then raise exception 'Fiscal periods must be contiguous. Period % should start on %.',v_num,v_prev_to+1; end if;
    if exists(select 1 from fiscal_periods fp where fp.user_id=uid and r.from_date<=fp.to_date and r.to_date>=fp.from_date) then
      raise exception 'Period % overlaps an existing fiscal period.',v_num;
    end if;
    insert into fiscal_periods(user_id,fiscal_year,period_number,period_label,from_date,to_date)
    values(uid,p_fiscal_year,v_num,coalesce(nullif(btrim(r.value->>'label'),''),'Period '||v_num),r.from_date,r.to_date);
    v_prev_to:=r.to_date;
  end loop;
  perform write_audit_log('create','fiscal_periods',p_fiscal_year,null,jsonb_build_object('period_count',v_num));
  return v_num;
end; $$;

create or replace function list_fiscal_periods(p_fiscal_year text)
returns table(id uuid, fiscal_year text, period_number integer, period_label text, from_date date, to_date date, is_locked boolean, lock_reason text, locked_at timestamptz)
language sql
security definer
set search_path = public
as $$
  select id,fiscal_year,period_number,period_label,from_date,to_date,is_locked,lock_reason,locked_at
  from fiscal_periods where user_id=get_workspace_owner() and fiscal_year=p_fiscal_year order by period_number;
$$;

create or replace function list_vat_returns(p_fiscal_year text)
returns table(id uuid, fiscal_period_id uuid, period_label text, fiscal_year text, from_date date, to_date date, status text, snapshot jsonb, filing_reference text, notes text, prepared_at timestamptz, filed_at timestamptz)
language sql
security definer
set search_path = public
as $$
  select r.id,p.id,p.period_label,p.fiscal_year,p.from_date,p.to_date,r.status,r.snapshot,r.filing_reference,r.notes,r.prepared_at,r.filed_at
  from fiscal_periods p left join vat_returns r on r.fiscal_period_id=p.id and r.user_id=get_workspace_owner()
  where p.user_id=get_workspace_owner() and p.fiscal_year=$1 order by p.period_number;
$$;

create or replace function prepare_vat_return(p_period_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare uid uuid:=get_workspace_owner(); p fiscal_periods%rowtype; v_report jsonb; v_id uuid;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  select * into p from fiscal_periods where id=p_period_id and user_id=uid;
  if not found then raise exception 'Fiscal period not found.'; end if;
  v_report:=get_vat_report(p.from_date,p.to_date,p.fiscal_year);
  insert into vat_returns(user_id,fiscal_period_id,fiscal_year,from_date,to_date,status,snapshot,prepared_at)
  values(uid,p.id,p.fiscal_year,p.from_date,p.to_date,'draft',v_report,now())
  on conflict(user_id,fiscal_period_id) do update set snapshot=excluded.snapshot,prepared_at=now()
    where vat_returns.status='draft'
  returning id into v_id;
  if v_id is null then raise exception 'The VAT return is already filed.'; end if;
  perform write_audit_log('create_draft','vat_returns',v_id::text,null,jsonb_build_object('period_id',p.id,'reconciled',v_report->'reconciled'));
  return v_id;
end; $$;

create or replace function remit_tds(p_entry_ids uuid[], p_date date, p_fiscal_year text, p_period_label text, p_mode text, p_challan_no text, p_notes text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare uid uuid:=get_workspace_owner(); v_total numeric(14,2); v_count integer; v_id uuid; v_voucher uuid; v_tds uuid; v_cash uuid;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  if p_entry_ids is null or cardinality(p_entry_ids)=0 then raise exception 'Select at least one TDS entry.'; end if;
  if p_date is null or nullif(btrim(p_fiscal_year),'') is null or nullif(btrim(p_period_label),'') is null then raise exception 'Date, fiscal year and period are required.'; end if;
  if lower(p_mode) not in ('cash','bank') then raise exception 'Payment mode must be cash or bank.'; end if;
  with selected as (
    select * from tds_entries where user_id=uid and id=any(p_entry_ids) and status='deducted'
      and fiscal_year=btrim(p_fiscal_year) and entry_date<=p_date for update
  )
  select count(*),round(coalesce(sum(tds_amount),0),2) into v_count,v_total from selected;
  if v_count<>cardinality(p_entry_ids) then raise exception 'One or more selected entries are missing, already remitted, reversed, or dated after the remittance.'; end if;
  v_tds:=resolve_system_account('tds_payable'); v_cash:=resolve_system_account(lower(p_mode));
  v_voucher:=post_voucher('payment',p_fiscal_year,p_date,'TDS remittance - '||btrim(p_period_label),jsonb_build_array(
    jsonb_build_object('account_id',v_tds,'debit',v_total,'credit',0,'description','TDS liability remitted'),
    jsonb_build_object('account_id',v_cash,'debit',0,'credit',v_total,'description','Paid to tax authority')
  ));
  insert into tds_remittances(user_id,remittance_date,fiscal_year,period_label,total_tds,payment_mode,challan_no,notes,voucher_id)
  values(uid,p_date,btrim(p_fiscal_year),btrim(p_period_label),v_total,lower(p_mode),nullif(btrim(p_challan_no),''),nullif(btrim(p_notes),''),v_voucher) returning id into v_id;
  update tds_entries set status='remitted',remittance_id=v_id where user_id=uid and id=any(p_entry_ids);
  update vouchers set source_document_type='tds_remittance',source_document_id=v_id where id=v_voucher and user_id=uid;
  perform write_audit_log('remit','tds_remittances',v_id::text,null,jsonb_build_object('entry_count',v_count,'total_tds',v_total,'voucher_id',v_voucher));
  return v_id;
end; $$;

-- set_period_lock keeps locked_by as the real acting user (audit trail),
-- separate from uid (workspace scoping) -- following the same pattern
-- already correctly used elsewhere (e.g. get_my_role).
create or replace function set_period_lock(p_period_id uuid, p_locked boolean, p_reason text default null::text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare uid uuid:=get_workspace_owner(); actor uuid:=auth.uid(); p fiscal_periods%rowtype;
begin
  if actor is null then raise exception 'Not authenticated'; end if;
  select * into p from fiscal_periods where id=p_period_id and user_id=uid for update;
  if not found then raise exception 'Fiscal period not found.'; end if;
  if exists(select 1 from fiscal_year_closures where user_id=uid and fiscal_year=p.fiscal_year) then raise exception 'A closed fiscal year cannot be unlocked or changed.'; end if;
  if not p_locked and exists(select 1 from vat_returns where user_id=uid and fiscal_period_id=p.id and status='filed') then raise exception 'A period with a filed VAT return cannot be unlocked through the application.'; end if;
  update fiscal_periods set is_locked=p_locked,lock_reason=case when p_locked then coalesce(nullif(btrim(p_reason),''),'Period locked') else null end,
    locked_at=case when p_locked then now() else null end,locked_by=case when p_locked then actor else null end where id=p.id;
  perform write_audit_log(case when p_locked then 'lock' else 'unlock' end,'fiscal_periods',p.id::text,to_jsonb(p),jsonb_build_object('locked',p_locked,'reason',p_reason));
end; $$;

create or replace function get_tax_rates(p_as_of date default current_date)
returns table(id uuid, rate_type text, transaction_type text, label text, rate numeric, vat_treatment text, effective_from date, effective_to date, legal_reference text, is_custom boolean)
language sql
security definer
set search_path = public
as $$
  with ranked as (
    select r.*,
      row_number() over(
        partition by r.rate_type,r.transaction_type
        order by (r.user_id=get_workspace_owner()) desc,r.effective_from desc,r.created_at desc
      ) rn
    from tax_rates r
    where r.is_active=true
      and (r.user_id is null or r.user_id=get_workspace_owner())
      and r.effective_from<=coalesce(p_as_of,current_date)
      and (r.effective_to is null or r.effective_to>=coalesce(p_as_of,current_date))
  )
  select id,rate_type,transaction_type,label,rate,vat_treatment,effective_from,effective_to,legal_reference,
         user_id is not null
  from ranked where rn=1
  order by rate_type,transaction_type;
$$;

-- ------------------------------------------------------------
-- 3. VAT scope correction: direct IRD filing is out of scope for this
-- release. Retain file_vat_return in the database (harmless,
-- unreachable) but block all client access to it.
-- ------------------------------------------------------------
revoke all on function file_vat_return(uuid,text,text) from public, authenticated, anon;
