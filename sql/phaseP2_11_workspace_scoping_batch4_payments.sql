-- ============================================================
-- HisabKitab P2.11 -- Workspace-scoping fix, batch 4: Payments.
--
-- Part of the larger workspace-scoping remediation (see memory:
-- workspace_scoping_gap.md). Fetched live and fixed with the minimal,
-- mechanical change: the uid variable's source only (auth.uid() ->
-- get_workspace_owner()). No other logic touched.
-- ============================================================

create or replace function record_document_payment(
  p_doc_type text, p_doc_id uuid, p_amount numeric, p_deposit_code text, p_date date,
  p_reference text default null::text, p_notes text default null::text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := get_workspace_owner();
  v_amount numeric(14,2):=round(coalesce(p_amount,0),2);
  v_deposit_code text:=lower(coalesce(p_deposit_code,''));
  v_cashbank uuid; v_party_acct uuid; v_voucher_id uuid; v_payment_id uuid;
  v_paid numeric(14,2); v_outstanding numeric(14,2); h record;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  if v_amount<=0 then raise exception 'Amount must be positive.'; end if;
  if p_date is null then raise exception 'Payment date is required.'; end if;
  if v_deposit_code not in ('cash','bank') then raise exception 'Payment mode must be cash or bank.'; end if;
  v_cashbank:=resolve_system_account(v_deposit_code);

  if p_doc_type='invoice' then
    select * into h from invoices where id=p_doc_id and user_id=uid for update;
    if not found then raise exception 'Invoice not found.'; end if;
    if h.document_status<>'posted' then raise exception 'Payments can only be recorded against a posted invoice.'; end if;
    select coalesce(sum(a.allocated_amount),0) into v_paid
    from payment_allocations a join document_payments p on p.id=a.payment_id
    where a.user_id=uid and a.invoice_id=p_doc_id and a.reversed_at is null and p.status<>'reversed';
    v_outstanding:=greatest(round(h.net_total-v_paid,2),0);
    if v_outstanding<=0.005 then raise exception 'Invoice is already fully settled.'; end if;
    if v_amount>v_outstanding+0.005 then raise exception 'Amount % exceeds outstanding balance %.',v_amount,v_outstanding; end if;
    if h.party_id is not null then select account_id into v_party_acct from parties where id=h.party_id and user_id=uid; end if;
    if v_party_acct is null then v_party_acct:=resolve_system_account('ar_control'); end if;
    v_voucher_id:=post_voucher('receipt',h.fiscal_year,p_date,'Receipt against Invoice #'||h.invoice_number,
      jsonb_build_array(
        jsonb_build_object('account_id',v_cashbank,'debit',v_amount,'credit',0,'description','Received'),
        jsonb_build_object('account_id',v_party_acct,'debit',0,'credit',v_amount,'description',h.party_name)
      ));
    insert into document_payments(user_id,payment_kind,payment_date,deposit_code,amount,voucher_id,reference,notes)
    values(uid,'receipt',p_date,v_deposit_code,v_amount,v_voucher_id,nullif(trim(p_reference),''),nullif(trim(p_notes),''))
    returning id into v_payment_id;
    insert into payment_allocations(user_id,payment_id,invoice_id,allocated_amount)
    values(uid,v_payment_id,p_doc_id,v_amount);
    update invoices set settlement_voucher_id=v_voucher_id where id=p_doc_id and user_id=uid;
    update vouchers set source_document_type='document_payment',source_document_id=v_payment_id where id=v_voucher_id and user_id=uid;
  elsif p_doc_type='bill' then
    select * into h from purchase_bills where id=p_doc_id and user_id=uid for update;
    if not found then raise exception 'Bill not found.'; end if;
    if h.document_status<>'posted' then raise exception 'Payments can only be recorded against a posted bill.'; end if;
    select coalesce(sum(a.allocated_amount),0) into v_paid
    from payment_allocations a join document_payments p on p.id=a.payment_id
    where a.user_id=uid and a.bill_id=p_doc_id and a.reversed_at is null and p.status<>'reversed';
    v_outstanding:=greatest(round(h.net_total-v_paid,2),0);
    if v_outstanding<=0.005 then raise exception 'Bill is already fully settled.'; end if;
    if v_amount>v_outstanding+0.005 then raise exception 'Amount % exceeds outstanding balance %.',v_amount,v_outstanding; end if;
    if h.vendor_id is not null then select account_id into v_party_acct from parties where id=h.vendor_id and user_id=uid; end if;
    if v_party_acct is null then v_party_acct:=resolve_system_account('ap_control'); end if;
    v_voucher_id:=post_voucher('payment',h.fiscal_year,p_date,'Payment against Bill #'||h.bill_number,
      jsonb_build_array(
        jsonb_build_object('account_id',v_party_acct,'debit',v_amount,'credit',0,'description',h.vendor_name),
        jsonb_build_object('account_id',v_cashbank,'debit',0,'credit',v_amount,'description','Paid')
      ));
    insert into document_payments(user_id,payment_kind,payment_date,deposit_code,amount,voucher_id,reference,notes)
    values(uid,'payment',p_date,v_deposit_code,v_amount,v_voucher_id,nullif(trim(p_reference),''),nullif(trim(p_notes),''))
    returning id into v_payment_id;
    insert into payment_allocations(user_id,payment_id,bill_id,allocated_amount)
    values(uid,v_payment_id,p_doc_id,v_amount);
    update purchase_bills set settlement_voucher_id=v_voucher_id where id=p_doc_id and user_id=uid;
    update vouchers set source_document_type='document_payment',source_document_id=v_payment_id where id=v_voucher_id and user_id=uid;
  else raise exception 'Unknown document type: %',p_doc_type; end if;

  perform refresh_document_payment_status(p_doc_type,p_doc_id);
  perform write_audit_log('create','document_payments',v_payment_id::text,null,
    jsonb_build_object('document_type',p_doc_type,'document_id',p_doc_id,'amount',v_amount,'voucher_id',v_voucher_id));
  return v_payment_id;
end;
$$;

create or replace function refresh_document_payment_status(p_doc_type text, p_doc_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := get_workspace_owner();
  v_total numeric(14,2);
  v_paid numeric(14,2);
  v_outstanding numeric(14,2);
  v_due date;
  v_lifecycle text;
  v_new_status text;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  if p_doc_type='invoice' then
    select net_total,due_date,document_status into v_total,v_due,v_lifecycle
    from invoices where id=p_doc_id and user_id=uid for update;
    if not found then raise exception 'Invoice not found.'; end if;
    select coalesce(sum(a.allocated_amount),0) into v_paid
    from payment_allocations a join document_payments p on p.id=a.payment_id
    where a.user_id=uid and a.invoice_id=p_doc_id and a.reversed_at is null and p.status<>'reversed';
  elsif p_doc_type='bill' then
    select net_total,due_date,document_status into v_total,v_due,v_lifecycle
    from purchase_bills where id=p_doc_id and user_id=uid for update;
    if not found then raise exception 'Bill not found.'; end if;
    select coalesce(sum(a.allocated_amount),0) into v_paid
    from payment_allocations a join document_payments p on p.id=a.payment_id
    where a.user_id=uid and a.bill_id=p_doc_id and a.reversed_at is null and p.status<>'reversed';
  else raise exception 'Unknown document type: %',p_doc_type; end if;

  v_paid := round(coalesce(v_paid,0),2);
  v_outstanding := greatest(round(v_total-v_paid,2),0);
  if v_lifecycle='draft' then v_new_status:='draft';
  elsif v_lifecycle='cancelled' then v_new_status:='cancelled';
  elsif v_lifecycle='credited' then v_new_status:='credited';
  elsif v_outstanding<=0.005 then v_new_status:='paid';
  elsif v_due is not null and v_due<current_date then v_new_status:='overdue';
  elsif v_paid>0.005 then v_new_status:='partial';
  else v_new_status:='open'; end if;

  if p_doc_type='invoice' then
    update invoices set amount_paid=v_paid,outstanding_amount=v_outstanding,status=v_new_status,payment_status_updated_at=now()
    where id=p_doc_id and user_id=uid;
  else
    update purchase_bills set amount_paid=v_paid,outstanding_amount=v_outstanding,status=v_new_status,payment_status_updated_at=now()
    where id=p_doc_id and user_id=uid;
  end if;
end;
$$;

create or replace function refresh_document_payment_statuses()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := get_workspace_owner();
  r record;
  v_count integer := 0;
begin
  if uid is null then raise exception 'Not authenticated'; end if;

  for r in select id from invoices where user_id = uid
  loop
    perform refresh_document_payment_status('invoice', r.id);
    v_count := v_count + 1;
  end loop;

  for r in select id from purchase_bills where user_id = uid
  loop
    perform refresh_document_payment_status('bill', r.id);
    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

create or replace function reverse_payment_allocation(p_allocation_id uuid, p_reason text, p_date date default current_date)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := get_workspace_owner();
  a record;
  h record;
  v_cashbank uuid;
  v_party_acct uuid;
  v_fiscal_year text;
  v_reversal_voucher_id uuid;
  v_active_count integer;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  if p_reason is null or length(trim(p_reason)) < 3 then
    raise exception 'A reversal reason of at least 3 characters is required.';
  end if;
  if p_date is null then raise exception 'Reversal date is required.'; end if;

  select pa.*, dp.payment_date, dp.deposit_code, dp.payment_kind,
         dp.status as payment_status, dp.voucher_id as original_voucher_id, dp.is_legacy
    into a
    from payment_allocations pa
    join document_payments dp on dp.id = pa.payment_id
   where pa.id = p_allocation_id and pa.user_id = uid
   for update of pa;

  if not found then raise exception 'Payment allocation not found.'; end if;
  if a.reversed_at is not null then raise exception 'Payment allocation is already reversed.'; end if;
  if a.original_voucher_id is null then
    raise exception 'This legacy payment has no posting voucher. Verify it and correct it through a reviewed journal instead of automatic reversal.';
  end if;
  if p_date < a.payment_date then
    raise exception 'Reversal date cannot be before the original payment date.';
  end if;

  v_cashbank := resolve_system_account(a.deposit_code);

  if a.invoice_id is not null then
    select * into h
      from invoices
     where id = a.invoice_id and user_id = uid
     for update;
    if not found then raise exception 'Invoice not found.'; end if;

    if h.party_id is not null then
      select account_id into v_party_acct
        from parties
       where id = h.party_id and user_id = uid;
    end if;
    if v_party_acct is null then v_party_acct := resolve_system_account('ar_control'); end if;
    v_fiscal_year := h.fiscal_year;

    v_reversal_voucher_id := post_voucher(
      'receipt', v_fiscal_year, p_date,
      'Reversal of receipt against Invoice #' || h.invoice_number || ': ' || trim(p_reason),
      jsonb_build_array(
        jsonb_build_object('account_id', v_party_acct, 'debit', a.allocated_amount, 'credit', 0, 'description', h.party_name),
        jsonb_build_object('account_id', v_cashbank, 'debit', 0, 'credit', a.allocated_amount, 'description', 'Receipt reversal')
      )
    );

  elsif a.bill_id is not null then
    select * into h
      from purchase_bills
     where id = a.bill_id and user_id = uid
     for update;
    if not found then raise exception 'Bill not found.'; end if;

    if h.vendor_id is not null then
      select account_id into v_party_acct
        from parties
       where id = h.vendor_id and user_id = uid;
    end if;
    if v_party_acct is null then v_party_acct := resolve_system_account('ap_control'); end if;
    v_fiscal_year := h.fiscal_year;

    v_reversal_voucher_id := post_voucher(
      'payment', v_fiscal_year, p_date,
      'Reversal of payment against Bill #' || h.bill_number || ': ' || trim(p_reason),
      jsonb_build_array(
        jsonb_build_object('account_id', v_cashbank, 'debit', a.allocated_amount, 'credit', 0, 'description', 'Payment reversal'),
        jsonb_build_object('account_id', v_party_acct, 'debit', 0, 'credit', a.allocated_amount, 'description', h.vendor_name)
      )
    );
  else
    raise exception 'Allocation has no linked document.';
  end if;

  update payment_allocations
     set reversed_at = now(),
         reversal_reason = trim(p_reason),
         reversal_voucher_id = v_reversal_voucher_id
   where id = p_allocation_id and user_id = uid;

  select count(*)::integer
    into v_active_count
    from payment_allocations
   where payment_id = a.payment_id and reversed_at is null;

  update document_payments
     set status = case when v_active_count = 0 then 'reversed' else 'partially_reversed' end
   where id = a.payment_id and user_id = uid;

  if a.invoice_id is not null then
    perform refresh_document_payment_status('invoice', a.invoice_id);
  else
    perform refresh_document_payment_status('bill', a.bill_id);
  end if;

  perform write_audit_log(
    'reverse', 'payment_allocations', p_allocation_id::text, null,
    jsonb_build_object(
      'reason', trim(p_reason),
      'amount', a.allocated_amount,
      'reversal_voucher_id', v_reversal_voucher_id
    )
  );

  return v_reversal_voucher_id;
end;
$$;

create or replace function get_payment_history(p_doc_type text, p_doc_id uuid)
returns table (
  id uuid, payment_id uuid, payment_date date, amount numeric, deposit_code text, payment_kind text,
  payment_status text, is_legacy boolean, reference text, notes text, voucher_id uuid,
  reversed_at timestamptz, reversal_reason text, reversal_voucher_id uuid, created_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := get_workspace_owner();
begin
  if uid is null then raise exception 'Not authenticated'; end if;

  if p_doc_type = 'invoice' then
    if not exists (select 1 from invoices where id = p_doc_id and user_id = uid) then
      raise exception 'Invoice not found.';
    end if;

    return query
      select a.id, p.id, p.payment_date, a.allocated_amount,
             p.deposit_code, p.payment_kind, p.status, p.is_legacy,
             p.reference, p.notes, p.voucher_id,
             a.reversed_at, a.reversal_reason, a.reversal_voucher_id,
             a.created_at
        from payment_allocations a
        join document_payments p on p.id = a.payment_id
       where a.user_id = uid and a.invoice_id = p_doc_id
       order by p.payment_date desc, a.created_at desc;

  elsif p_doc_type = 'bill' then
    if not exists (select 1 from purchase_bills where id = p_doc_id and user_id = uid) then
      raise exception 'Bill not found.';
    end if;

    return query
      select a.id, p.id, p.payment_date, a.allocated_amount,
             p.deposit_code, p.payment_kind, p.status, p.is_legacy,
             p.reference, p.notes, p.voucher_id,
             a.reversed_at, a.reversal_reason, a.reversal_voucher_id,
             a.created_at
        from payment_allocations a
        join document_payments p on p.id = a.payment_id
       where a.user_id = uid and a.bill_id = p_doc_id
       order by p.payment_date desc, a.created_at desc;
  else
    raise exception 'Unknown document type: %', p_doc_type;
  end if;
end;
$$;
