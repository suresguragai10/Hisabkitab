-- ============================================================
-- HisabKitab P2.14 -- Workspace-scoping fix, batch 7: Fiscal year
-- close.
--
-- Part of the larger workspace-scoping remediation (see memory:
-- workspace_scoping_gap.md). Fetched live and fixed with the minimal,
-- mechanical change: the uid variable's source only (auth.uid() ->
-- get_workspace_owner()). No other logic touched. The
-- hisabkitab.period_lock_bypass mechanism stays consistent since
-- post_voucher (already fixed in batch 6) also scopes by
-- get_workspace_owner() -- both sides now agree on the same identity.
-- ============================================================

create or replace function preview_fiscal_year_close(p_fiscal_year text, p_next_fiscal_year text, p_closing_date date, p_opening_date date)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare uid uuid:=get_workspace_owner(); v_from date; v_to date; v_period_count integer; v_unlocked integer; v_drafts integer; v_next_period_count integer; v_next_from date; v_tb jsonb; v_stock jsonb; v_vat jsonb; v_pl jsonb; v_bs jsonb; v_existing boolean;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  select min(from_date),max(to_date),count(*),count(*) filter(where not is_locked) into v_from,v_to,v_period_count,v_unlocked
    from fiscal_periods where user_id=uid and fiscal_year=p_fiscal_year;
  select count(*),min(from_date) into v_next_period_count,v_next_from
    from fiscal_periods where user_id=uid and fiscal_year=p_next_fiscal_year;
  select count(*) into v_drafts from (
    select id from invoices where user_id=uid and fiscal_year=p_fiscal_year and document_status='draft'
    union all select id from purchase_bills where user_id=uid and fiscal_year=p_fiscal_year and document_status='draft'
  ) x;
  v_existing:=exists(select 1 from fiscal_year_closures where user_id=uid and fiscal_year=p_fiscal_year);
  if v_from is not null then
    v_tb:=get_trial_balance_report(p_closing_date); v_stock:=get_stock_valuation_report(p_closing_date);
    v_vat:=get_vat_report(v_from,least(v_to,p_closing_date),p_fiscal_year); v_pl:=get_profit_loss_report(v_from,least(v_to,p_closing_date),p_fiscal_year); v_bs:=get_balance_sheet_report(p_closing_date);
  else
    v_tb:='{}'::jsonb; v_stock:='{}'::jsonb; v_vat:='{}'::jsonb; v_pl:='{}'::jsonb; v_bs:='{}'::jsonb;
  end if;
  return jsonb_build_object('fiscal_year',p_fiscal_year,'next_fiscal_year',p_next_fiscal_year,'closing_date',p_closing_date,'opening_date',p_opening_date,
    'period_from',v_from,'period_to',v_to,'period_count',v_period_count,'unlocked_periods',v_unlocked,'draft_documents',v_drafts,'already_closed',v_existing,
    'next_period_count',v_next_period_count,'next_period_from',v_next_from,
    'closing_date_matches_period_end',p_closing_date=v_to,'opening_date_is_next_day',p_opening_date=v_to+1,
    'next_period_starts_on_opening_date',v_next_from=p_opening_date,
    'trial_balance',v_tb,'stock',v_stock,'vat',v_vat,'profit_loss',v_pl,'balance_sheet',v_bs,
    'can_close',v_period_count=12 and v_unlocked=0 and v_drafts=0 and not v_existing
      and v_next_period_count=12 and v_next_from=p_opening_date
      and p_closing_date=v_to and p_opening_date=v_to+1 and nullif(btrim(p_next_fiscal_year),'') is not null and p_next_fiscal_year<>p_fiscal_year
      and coalesce((v_tb->>'balanced')::boolean,false) and coalesce((v_stock->>'reconciled')::boolean,false)
      and coalesce((v_vat->>'reconciled')::boolean,false) and coalesce((v_bs->>'balanced')::boolean,false));
end; $$;

create or replace function close_fiscal_year(p_fiscal_year text, p_next_fiscal_year text, p_closing_date date, p_opening_date date, p_notes text default null::text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare uid uuid:=get_workspace_owner(); v_preview jsonb; v_retained uuid; v_close_lines jsonb; v_open_lines jsonb; v_net numeric; v_closing_voucher uuid; v_opening_voucher uuid; v_id uuid;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  if p_opening_date<=p_closing_date then raise exception 'Opening date must be after the closing date.'; end if;
  perform pg_advisory_xact_lock(hashtextextended(uid::text||':year-close:'||p_fiscal_year,0));
  v_preview:=preview_fiscal_year_close(p_fiscal_year,p_next_fiscal_year,p_closing_date,p_opening_date);
  if not coalesce((v_preview->>'can_close')::boolean,false) then raise exception 'Year-end close preconditions are not satisfied. Review the preview.'; end if;
  if exists(select 1 from opening_journals where user_id=uid and fiscal_year=p_next_fiscal_year) then raise exception 'An opening journal already exists for fiscal year %.',p_next_fiscal_year; end if;
  v_retained:=resolve_system_account('retained_earnings');
  with balances as (
    select a.id,a.name,round(sum(vl.debit-vl.credit),2) balance
    from accounts a join voucher_lines vl on vl.account_id=a.id join vouchers v on v.id=vl.voucher_id
    where a.user_id=uid and v.user_id=uid and v.is_void=false and v.fiscal_year=p_fiscal_year and v.voucher_date<=p_closing_date
      and coalesce(v.source_document_type,'')<>'year_end_closing'
      and a.report_class in ('revenue','other_income','cost_of_sales','operating_expense','other_expense')
    group by a.id,a.name having abs(sum(vl.debit-vl.credit))>0.005
  ), base_lines as (
    select jsonb_build_object('account_id',id,'debit',case when balance<0 then -balance else 0 end,'credit',case when balance>0 then balance else 0 end,'description','Close '||name) line,
      balance from balances
  )
  select coalesce(jsonb_agg(line),'[]'::jsonb),coalesce(sum(balance),0) into v_close_lines,v_net from base_lines;
  if jsonb_array_length(v_close_lines)>0 then
    v_close_lines:=v_close_lines||jsonb_build_array(jsonb_build_object('account_id',v_retained,'debit',case when v_net>0 then v_net else 0 end,
      'credit',case when v_net<0 then -v_net else 0 end,'description',case when v_net<0 then 'Transfer net profit' else 'Transfer net loss' end));
    perform set_config('hisabkitab.period_lock_bypass',uid::text,true);
    v_closing_voucher:=post_voucher('journal',p_fiscal_year,p_closing_date,'Year-end closing for '||p_fiscal_year,v_close_lines);
  end if;
  with activity as (select * from report_account_activity(null,p_closing_date,null)), lines as (
    select jsonb_build_object('account_id',account_id,'debit',case when closing_balance>0 then closing_balance else 0 end,
      'credit',case when closing_balance<0 then -closing_balance else 0 end,'description','Balance carried forward') line
    from activity where report_class in ('current_asset','non_current_asset','current_liability','non_current_liability','equity') and abs(closing_balance)>0.005
  ) select coalesce(jsonb_agg(line),'[]'::jsonb) into v_open_lines from lines;
  if jsonb_array_length(v_open_lines)<2 then raise exception 'There are not enough balance-sheet balances to carry forward.'; end if;
  perform set_config('hisabkitab.period_lock_bypass','',true);
  v_opening_voucher:=post_opening_journal(p_next_fiscal_year,p_opening_date,v_open_lines,'Year-end carry-forward from '||p_fiscal_year);
  insert into fiscal_year_closures(user_id,fiscal_year,next_fiscal_year,closing_date,opening_date,retained_earnings_account_id,closing_voucher_id,opening_voucher_id,snapshot,notes)
  values(uid,p_fiscal_year,p_next_fiscal_year,p_closing_date,p_opening_date,v_retained,v_closing_voucher,v_opening_voucher,v_preview,nullif(btrim(p_notes),'')) returning id into v_id;
  if v_closing_voucher is not null then
    perform set_config('hisabkitab.period_lock_bypass',uid::text,true);
    update vouchers set source_document_type='year_end_closing',source_document_id=v_id where id=v_closing_voucher and user_id=uid;
    perform set_config('hisabkitab.period_lock_bypass','',true);
  end if;
  update vouchers set source_document_type='year_end_opening',source_document_id=v_id where id=v_opening_voucher and user_id=uid;
  update fiscal_periods set is_locked=true,lock_reason='Fiscal year closed',locked_at=coalesce(locked_at,now()),locked_by=coalesce(locked_by,uid) where user_id=uid and fiscal_year=p_fiscal_year;
  perform write_audit_log('close','fiscal_year_closures',v_id::text,null,jsonb_build_object('fiscal_year',p_fiscal_year,'closing_voucher_id',v_closing_voucher,'opening_voucher_id',v_opening_voucher));
  return v_id;
end; $$;
