-- ============================================================
-- HisabKitab P2.15 -- Workspace-scoping fix, batch 8: TDS reversal.
--
-- Part of the larger workspace-scoping remediation (see memory:
-- workspace_scoping_gap.md). Fetched live and fixed with the minimal,
-- mechanical change: the uid variable's source only (auth.uid() ->
-- get_workspace_owner()). No other logic touched.
-- ============================================================

create or replace function reverse_tds_entry(p_entry_id uuid, p_reason text, p_date date default current_date)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare uid uuid:=get_workspace_owner(); e tds_entries%rowtype; v_cash uuid; v_tds uuid; v_voucher uuid;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  if nullif(btrim(p_reason),'') is null or length(btrim(p_reason))<3 then raise exception 'A reversal reason is required.'; end if;
  select * into e from tds_entries where id=p_entry_id and user_id=uid for update;
  if not found then raise exception 'TDS entry not found.'; end if;
  if e.status<>'deducted' then raise exception 'Only an unremitted TDS entry can be reversed.'; end if;
  if p_date<e.entry_date then raise exception 'Reversal date cannot precede the deduction.'; end if;
  v_cash:=resolve_system_account(e.payment_mode); v_tds:=resolve_system_account('tds_payable');
  v_voucher:=post_voucher('journal',e.fiscal_year,p_date,'Reversal of TDS deduction: '||btrim(p_reason),jsonb_build_array(
    jsonb_build_object('account_id',v_cash,'debit',e.net_amount,'credit',0,'description','Reverse net payment'),
    jsonb_build_object('account_id',v_tds,'debit',e.tds_amount,'credit',0,'description','Reverse TDS liability'),
    jsonb_build_object('account_id',e.expense_account_id,'debit',0,'credit',e.gross_amount,'description','Reverse expense')
  ));
  update tds_entries set status='reversed',reversal_voucher_id=v_voucher,reversal_reason=btrim(p_reason),reversed_at=now() where id=e.id;
  update vouchers set source_document_type='tds_entry_reversal',source_document_id=e.id,reverses_voucher_id=e.voucher_id where id=v_voucher and user_id=uid;
  update vouchers set reversed_by_voucher_id=v_voucher where id=e.voucher_id and user_id=uid;
  perform write_audit_log('reverse','tds_entries',e.id::text,to_jsonb(e),jsonb_build_object('reason',p_reason,'voucher_id',v_voucher));
  return v_voucher;
end; $$;
