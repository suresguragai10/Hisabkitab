-- ============================================================
-- HisabKitab P2.21 -- Close the remaining "both" party vendor-account
-- gap.
--
-- phaseP2_5 (earlier this project) fixed post_bill_draft to use
-- coalesce(payable_account_id, account_id) for a vendor's account --
-- required for party_type='both' parties, which have a SEPARATE
-- payable_account_id distinct from their (receivable) account_id.
-- But that fix was never applied to the other 5 functions that also
-- look up a vendor's account for posting. Confirmed live 2026-07-25:
-- a real bill payment for a "both" party ("New Mata Rani") was
-- misposted to their receivable account instead of their payable
-- account by record_document_payment, corrupting both account
-- balances (corrected separately via a manual reclassification
-- journal, voucher 957a71f9-a31c-473a-8b41-53fb178ede8e).
--
-- Found by a whitespace-tolerant live-DB regex search for every
-- "select account_id into ... from parties" lookup, then separating
-- customer-side (party_id -- correct as-is, account_id is always the
-- receivable account regardless of party_type) from vendor-side
-- (vendor_id -- needs the coalesce, since a plain vendor's account_id
-- IS the payable account, but a "both" party's account_id is the
-- receivable side instead).
--
-- Only the vendor_id lookup line changes in each function below --
-- everything else is byte-for-byte identical to what's live.
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
    if h.vendor_id is not null then select coalesce(payable_account_id, account_id) into v_party_acct from parties where id=h.vendor_id and user_id=uid; end if;
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
      select coalesce(payable_account_id, account_id) into v_party_acct
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

create or replace function cancel_bill_document(p_bill_id uuid, p_reason text, p_date date default current_date)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid:=get_workspace_owner(); h record; l record; move record; party_acct uuid;
  v_inventory numeric(18,2):=0; v_expense numeric(18,2):=0; v_difference numeric(18,2); v_voucher uuid; v_lines jsonb;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  if nullif(trim(coalesce(p_reason,'')),'') is null then raise exception 'Cancellation reason is required.'; end if;
  select * into h from purchase_bills where id=p_bill_id and user_id=uid for update;
  if not found then raise exception 'Bill not found.'; end if;
  if h.document_status<>'posted' then raise exception 'Only a posted bill can be cancelled.'; end if;
  if h.voucher_id is null then raise exception 'Bill has no posting voucher and cannot be automatically reversed.'; end if;
  if h.amount_paid>0.005 then raise exception 'Reverse all payments before cancelling this bill.'; end if;
  if h.credited_amount>0.005 then raise exception 'Cancel linked debit notes before cancelling this bill.'; end if;
  if p_date<h.bill_date then raise exception 'Cancellation date cannot precede bill date.'; end if;
  if h.vendor_id is not null then select coalesce(payable_account_id, account_id) into party_acct from parties where id=h.vendor_id and user_id=uid; end if;
  if party_acct is null then party_acct:=resolve_system_account('ap_control'); end if;

  for l in select bl.*, i.track_inventory, i.item_type from purchase_bill_lines bl
    left join inventory_items i on i.id=bl.item_id and i.user_id=uid
    where bl.bill_id=h.id
  loop
    if l.item_id is not null and coalesce(l.track_inventory,true) and coalesce(l.item_type,'goods')='goods' then
      if l.inventory_cost_amount is null or l.inventory_unit_cost is null then
        raise exception 'Bill contains legacy inventory lines without cost snapshots. Use a reviewed correction instead of automatic cancellation.';
      end if;
      select * into move from apply_inventory_movement(l.item_id,-l.quantity,null,p_date,
        'purchase_cancel','Bill cancellation #'||h.bill_number,h.id,l.id,trim(p_reason));
      v_inventory:=v_inventory+move.applied_total_cost;
    else v_expense:=v_expense+l.amount; end if;
  end loop;
  v_difference:=round(h.subtotal-v_inventory-v_expense,2);
  v_lines:=jsonb_build_array(
    jsonb_build_object('account_id',party_acct,'debit',h.total,'credit',0,'description',h.vendor_name)
  );
  if h.vat_amount>0.005 then v_lines:=v_lines||jsonb_build_array(
    jsonb_build_object('account_id',resolve_system_account('vat_receivable'),'debit',0,'credit',h.vat_amount,'description','Input VAT reversed')
  ); end if;
  if v_inventory>0.005 then v_lines:=v_lines||jsonb_build_array(
    jsonb_build_object('account_id',resolve_system_account('inventory_asset'),'debit',0,'credit',v_inventory,'description','Cancelled purchase stock removed')
  ); end if;
  if v_expense>0.005 then v_lines:=v_lines||jsonb_build_array(
    jsonb_build_object('account_id',resolve_system_account('purchase'),'debit',0,'credit',v_expense,'description','Purchase expense reversed')
  ); end if;
  if v_difference>0.005 then v_lines:=v_lines||jsonb_build_array(
    jsonb_build_object('account_id',resolve_system_account('purchase_return'),'debit',0,'credit',v_difference,'description','Cancellation valuation difference')
  ); elsif v_difference < -0.005 then v_lines:=v_lines||jsonb_build_array(
    jsonb_build_object('account_id',resolve_system_account('purchase_return'),'debit',abs(v_difference),'credit',0,'description','Cancellation valuation difference')
  ); end if;
  v_voucher:=post_voucher('purchase',h.fiscal_year,p_date,'Cancellation of Bill #'||h.bill_number||': '||trim(p_reason),v_lines);
  update vouchers set source_document_type='bill_cancellation',source_document_id=h.id,
    reversal_of_voucher_id=h.voucher_id,reversal_reason=trim(p_reason) where id=v_voucher and user_id=uid;
  update inventory_movements set voucher_id=v_voucher where user_id=uid and source_type='purchase_cancel' and reference_id=h.id and voucher_id is null;
  update purchase_bills set document_status='cancelled',status='cancelled',cancelled_at=now(),
    cancellation_reason=left(trim(p_reason),500),cancellation_voucher_id=v_voucher,
    outstanding_amount=0,payment_status_updated_at=now() where id=h.id and user_id=uid;
  perform write_audit_log('cancel','purchase_bills',h.id::text,null,jsonb_build_object('reason',trim(p_reason),'reversal_voucher_id',v_voucher));
  return v_voucher;
end;
$$;

create or replace function cancel_debit_note(p_debit_note_id uuid, p_reason text, p_date date default current_date)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid:=get_workspace_owner(); n record; bill record; l record; move record; party_acct uuid;
  v_inventory numeric(18,2):=0; v_voucher uuid; v_lines jsonb; v_difference numeric(18,2);
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  if nullif(trim(coalesce(p_reason,'')),'') is null then raise exception 'Cancellation reason is required.'; end if;
  select * into n from debit_notes where id=p_debit_note_id and user_id=uid for update;
  if not found or n.document_status<>'posted' then raise exception 'Posted debit note not found.'; end if;
  if n.voucher_id is null then raise exception 'Debit note has no posting voucher and cannot be automatically reversed.'; end if;
  select * into bill from purchase_bills where id=n.bill_id and user_id=uid for update;
  if bill.document_status='cancelled' then raise exception 'The original bill is cancelled.'; end if;
  if p_date<n.dn_date then raise exception 'Cancellation date cannot precede debit note date.'; end if;
  if bill.vendor_id is not null then select coalesce(payable_account_id, account_id) into party_acct from parties where id=bill.vendor_id and user_id=uid; end if;
  if party_acct is null then party_acct:=resolve_system_account('ap_control'); end if;
  for l in select * from debit_note_lines where debit_note_id=n.id and item_id is not null
  loop
    if l.inventory_cost_amount is not null then
      select * into move from apply_inventory_movement(l.item_id,l.quantity,l.inventory_unit_cost,p_date,
        'purchase_return_cancel','Debit note cancellation #'||n.dn_number,n.id,l.id,trim(p_reason));
      v_inventory:=v_inventory+move.applied_total_cost;
    end if;
  end loop;
  v_difference:=round(n.subtotal-v_inventory-n.expense_reversal_amount,2);
  v_lines:=jsonb_build_array(
    jsonb_build_object('account_id',party_acct,'debit',0,'credit',n.total,'description',n.vendor_name)
  );
  if n.vat_amount>0.005 then v_lines:=v_lines||jsonb_build_array(
    jsonb_build_object('account_id',resolve_system_account('vat_receivable'),'debit',n.vat_amount,'credit',0,'description','Input VAT restored')
  ); end if;
  if v_inventory>0.005 then v_lines:=v_lines||jsonb_build_array(
    jsonb_build_object('account_id',resolve_system_account('inventory_asset'),'debit',v_inventory,'credit',0,'description','Returned stock restored')
  ); end if;
  if n.expense_reversal_amount>0.005 then v_lines:=v_lines||jsonb_build_array(
    jsonb_build_object('account_id',resolve_system_account('purchase'),'debit',n.expense_reversal_amount,'credit',0,'description','Purchase expense restored')
  ); end if;
  if v_difference>0.005 then v_lines:=v_lines||jsonb_build_array(
    jsonb_build_object('account_id',resolve_system_account('purchase_return'),'debit',v_difference,'credit',0,'description','Return difference reversed')
  ); elsif v_difference < -0.005 then v_lines:=v_lines||jsonb_build_array(
    jsonb_build_object('account_id',resolve_system_account('purchase_return'),'debit',0,'credit',abs(v_difference),'description','Return difference reversed')
  ); end if;
  v_voucher:=post_voucher('purchase',n.fiscal_year,p_date,'Cancellation of Debit Note #'||n.dn_number||': '||trim(p_reason),v_lines);
  update vouchers set source_document_type='debit_note_cancellation',source_document_id=n.id,
    reversal_of_voucher_id=n.voucher_id,reversal_reason=trim(p_reason) where id=v_voucher and user_id=uid;
  update inventory_movements set voucher_id=v_voucher where user_id=uid and source_type='purchase_return_cancel' and reference_id=n.id and voucher_id is null;
  update debit_notes set document_status='cancelled',cancelled_at=now(),cancellation_reason=left(trim(p_reason),500),cancellation_voucher_id=v_voucher where id=n.id;
  update purchase_bills set credited_amount=greatest(round(credited_amount-n.total,2),0),
    net_total=least(total,round(total-greatest(credited_amount-n.total,0),2)),document_status='posted'
  where id=bill.id and user_id=uid;
  perform refresh_document_payment_status('bill',bill.id);
  perform write_audit_log('cancel','debit_notes',n.id::text,null,jsonb_build_object('reason',trim(p_reason),'reversal_voucher_id',v_voucher));
  return v_voucher;
end;
$$;

create or replace function create_debit_note(p_header jsonb, p_lines jsonb)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid:=get_workspace_owner();
  bill record; orig record; item record; l jsonb; move record;
  v_id uuid; v_line_id uuid; v_num integer; v_voucher uuid; v_party uuid;
  v_qty numeric(14,3); v_prev_qty numeric(14,3); v_amount numeric(14,2); v_vat numeric(14,2);
  v_subtotal numeric(14,2):=0; v_vat_total numeric(14,2):=0; v_total numeric(14,2):=0;
  v_inventory numeric(18,2):=0; v_expense numeric(18,2):=0; v_difference numeric(18,2):=0;
  v_available numeric(14,2); v_lines jsonb;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  if nullif(p_header->>'bill_id','') is null then raise exception 'A debit note must be linked to a purchase bill.'; end if;
  if nullif(trim(p_header->>'reason'),'') is null then raise exception 'Debit note reason is required.'; end if;
  if p_lines is null or jsonb_typeof(p_lines)<>'array' or jsonb_array_length(p_lines)=0 then raise exception 'At least one debit line is required.'; end if;
  if nullif(p_header->>'dn_date','') is null then raise exception 'Debit note date is required.'; end if;

  select * into bill from purchase_bills where id=(p_header->>'bill_id')::uuid and user_id=uid for update;
  if not found then raise exception 'Purchase bill not found.'; end if;
  if bill.document_status<>'posted' then raise exception 'Debit notes can only be issued against a posted bill.'; end if;
  if bill.voucher_id is null then raise exception 'The original bill has no posting voucher. Correct the legacy bill before issuing a debit note.'; end if;
  if (p_header->>'dn_date')::date < bill.bill_date then raise exception 'Debit note date cannot precede bill date.'; end if;
  v_available:=round(bill.total-bill.credited_amount-bill.amount_paid,2);
  if v_available<=0.005 then raise exception 'No uncredited and unpaid bill balance remains. Reverse/refund payments first.'; end if;
  select next_doc_number('debit_note',bill.fiscal_year) into v_num;
  if bill.vendor_id is not null then select coalesce(payable_account_id, account_id) into v_party from parties where id=bill.vendor_id and user_id=uid; end if;
  if v_party is null then v_party:=resolve_system_account('ap_control'); end if;

  insert into debit_notes(user_id,dn_number,fiscal_year,dn_date,bill_id,bill_number,
    vendor_id,vendor_name,vendor_address,vendor_pan,reason,notes,document_status)
  values(uid,v_num,bill.fiscal_year,(p_header->>'dn_date')::date,bill.id,bill.bill_number,
    bill.vendor_id,bill.vendor_name,bill.vendor_address,bill.vendor_pan,trim(p_header->>'reason'),nullif(trim(p_header->>'notes'),''),'posted')
  returning id into v_id;

  for l in select * from jsonb_array_elements(p_lines)
  loop
    if nullif(l->>'source_line_id','') is null then raise exception 'Every debit line must reference an original bill line.'; end if;
    select * into orig from purchase_bill_lines where id=(l->>'source_line_id')::uuid and bill_id=bill.id;
    if not found then raise exception 'Original purchase line not found.'; end if;
    v_qty:=round(coalesce((l->>'quantity')::numeric,0),3);
    if v_qty<=0 then raise exception 'Debit note quantity must be positive.'; end if;
    select coalesce(sum(dl.quantity),0) into v_prev_qty
    from debit_note_lines dl join debit_notes dn on dn.id=dl.debit_note_id
    where dl.source_line_id=orig.id and dn.document_status='posted';
    if v_prev_qty+v_qty>orig.quantity+0.0005 then
      raise exception 'Return quantity exceeds remaining quantity for %.',orig.description;
    end if;
    v_amount:=round(v_qty*orig.rate,2);
    v_vat:=round(v_amount*orig.vat_rate/100,2);
    insert into debit_note_lines(debit_note_id,source_line_id,item_id,description,quantity,unit,
      rate,amount,vat_rate,vat_amount,line_total)
    values(v_id,orig.id,orig.item_id,orig.description,v_qty,orig.unit,orig.rate,v_amount,orig.vat_rate,v_vat,v_amount+v_vat)
    returning id into v_line_id;
    v_subtotal:=v_subtotal+v_amount; v_vat_total:=v_vat_total+v_vat;

    if orig.item_id is not null then
      select * into item from inventory_items where id=orig.item_id and user_id=uid and is_active=true for update;
      if found and coalesce(item.track_inventory,true) and coalesce(item.item_type,'goods')='goods' then
        if orig.inventory_unit_cost is null then
          raise exception 'Original purchase line % has no Stage 3 cost snapshot. Correct this legacy return through a reviewed journal.', orig.description;
        end if;
        select * into move from apply_inventory_movement(orig.item_id,-v_qty,null,
          (p_header->>'dn_date')::date,'purchase_return','Debit Note #'||v_num,v_id,v_line_id,
          'Return to vendor against Bill #'||bill.bill_number);
        update debit_note_lines set inventory_unit_cost=move.applied_unit_cost,
          inventory_cost_amount=move.applied_total_cost where id=v_line_id;
        v_inventory:=v_inventory+move.applied_total_cost;
      else v_expense:=v_expense+v_amount; end if;
    else v_expense:=v_expense+v_amount; end if;
  end loop;
  v_total:=round(v_subtotal+v_vat_total,2);
  if v_total<=0.005 then raise exception 'Debit note total must be positive.'; end if;
  if v_total>v_available+0.005 then raise exception 'Debit note total % exceeds available unpaid balance %.',v_total,v_available; end if;
  v_difference:=round(v_subtotal-v_inventory-v_expense,2);

  v_lines:=jsonb_build_array(
    jsonb_build_object('account_id',v_party,'debit',v_total,'credit',0,'description',bill.vendor_name)
  );
  if v_vat_total>0.005 then v_lines:=v_lines||jsonb_build_array(
    jsonb_build_object('account_id',resolve_system_account('vat_receivable'),'debit',0,'credit',v_vat_total,'description','Input VAT reversed')
  ); end if;
  if v_inventory>0.005 then v_lines:=v_lines||jsonb_build_array(
    jsonb_build_object('account_id',resolve_system_account('inventory_asset'),'debit',0,'credit',v_inventory,'description','Inventory returned to vendor')
  ); end if;
  if v_expense>0.005 then v_lines:=v_lines||jsonb_build_array(
    jsonb_build_object('account_id',resolve_system_account('purchase'),'debit',0,'credit',v_expense,'description','Purchase expense reversed')
  ); end if;
  if v_difference>0.005 then v_lines:=v_lines||jsonb_build_array(
    jsonb_build_object('account_id',resolve_system_account('purchase_return'),'debit',0,'credit',v_difference,'description','Purchase return valuation difference')
  ); elsif v_difference < -0.005 then v_lines:=v_lines||jsonb_build_array(
    jsonb_build_object('account_id',resolve_system_account('purchase_return'),'debit',abs(v_difference),'credit',0,'description','Purchase return valuation difference')
  ); end if;

  v_voucher:=post_voucher('purchase',bill.fiscal_year,(p_header->>'dn_date')::date,
    'Debit Note #'||v_num||' against Bill #'||bill.bill_number,v_lines);
  update vouchers set source_document_type='debit_note',source_document_id=v_id where id=v_voucher and user_id=uid;
  update inventory_movements set voucher_id=v_voucher where user_id=uid and source_type='purchase_return' and reference_id=v_id and voucher_id is null;
  update debit_notes set subtotal=v_subtotal,vat_amount=v_vat_total,total=v_total,
    inventory_cost_amount=v_inventory,expense_reversal_amount=v_expense,
    valuation_difference=v_difference,voucher_id=v_voucher,posted_at=now() where id=v_id;
  update purchase_bills set credited_amount=round(credited_amount+v_total,2),
    net_total=greatest(round(total-(credited_amount+v_total),2),0),
    document_status=case when total-(credited_amount+v_total)<=0.005 then 'credited' else 'posted' end
  where id=bill.id and user_id=uid;
  perform refresh_document_payment_status('bill',bill.id);
  perform write_audit_log('create','debit_notes',v_id::text,null,
    jsonb_build_object('bill_id',bill.id,'total',v_total,'inventory_cost',v_inventory,'valuation_difference',v_difference,'voucher_id',v_voucher));
  return v_id;
end;
$$;

create or replace function backfill_post_existing()
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := get_workspace_owner();
  r record;
  debtor_acct uuid;
  creditor_acct uuid;
  v_id uuid;
  n_inv integer := 0;
  n_bill integer := 0;
begin
  if uid is null then raise exception 'Not authenticated'; end if;

  for r in select * from invoices
            where user_id = uid and voucher_id is null and status <> 'cancelled'
  loop
    debtor_acct := null;
    if r.party_id is not null then
      select account_id into debtor_acct from parties where id = r.party_id and user_id = uid;
    end if;
    if debtor_acct is null then debtor_acct := resolve_system_account('ar_control'); end if;

    v_id := post_voucher('sales', r.fiscal_year, r.invoice_date,
      'Sales Invoice #' || r.invoice_number,
      jsonb_build_array(
        jsonb_build_object('account_id', debtor_acct, 'debit', r.total, 'credit', 0, 'description', r.party_name),
        jsonb_build_object('account_id', resolve_system_account('sales'), 'debit', 0, 'credit', r.subtotal, 'description', 'Sales'),
        jsonb_build_object('account_id', resolve_system_account('vat_payable'), 'debit', 0, 'credit', r.vat_amount, 'description', 'Output VAT 13%')
      ));
    update invoices set voucher_id = v_id where id = r.id;
    n_inv := n_inv + 1;
  end loop;

  for r in select * from purchase_bills
            where user_id = uid and voucher_id is null and status <> 'cancelled'
  loop
    creditor_acct := null;
    if r.vendor_id is not null then
      select coalesce(payable_account_id, account_id) into creditor_acct from parties where id = r.vendor_id and user_id = uid;
    end if;
    if creditor_acct is null then creditor_acct := resolve_system_account('ap_control'); end if;

    v_id := post_voucher('purchase', r.fiscal_year, r.bill_date,
      'Purchase Bill #' || r.bill_number,
      jsonb_build_array(
        jsonb_build_object('account_id', resolve_system_account('purchase'), 'debit', r.subtotal, 'credit', 0, 'description', 'Purchase'),
        jsonb_build_object('account_id', resolve_system_account('vat_receivable'), 'debit', r.vat_amount, 'credit', 0, 'description', 'Input VAT 13%'),
        jsonb_build_object('account_id', creditor_acct, 'debit', 0, 'credit', r.total, 'description', r.vendor_name)
      ));
    update purchase_bills set voucher_id = v_id where id = r.id;
    n_bill := n_bill + 1;
  end loop;

  return format('Backfilled %s invoice(s) and %s bill(s).', n_inv, n_bill);
end;
$$;
