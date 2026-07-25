-- ============================================================
-- HisabKitab P2.26 -- RBAC batch 4: credit/debit notes
-- (owner + accountant).
-- ============================================================

create or replace function create_credit_note(p_header jsonb, p_lines jsonb)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid:=get_workspace_owner();
  inv record; orig record; item record; l jsonb; move record;
  v_id uuid; v_line_id uuid; v_num integer; v_voucher uuid; v_party uuid;
  v_qty numeric(14,3); v_prev_qty numeric(14,3); v_amount numeric(14,2); v_vat numeric(14,2);
  v_subtotal numeric(14,2):=0; v_vat_total numeric(14,2):=0; v_total numeric(14,2):=0;
  v_inventory numeric(18,2):=0; v_available numeric(14,2); v_lines jsonb;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  perform assert_role(array['owner','accountant']);
  if nullif(p_header->>'invoice_id','') is null then raise exception 'A credit note must be linked to an invoice.'; end if;
  if nullif(trim(p_header->>'reason'),'') is null then raise exception 'Credit note reason is required.'; end if;
  if p_lines is null or jsonb_typeof(p_lines)<>'array' or jsonb_array_length(p_lines)=0 then raise exception 'At least one credit line is required.'; end if;
  if nullif(p_header->>'cn_date','') is null then raise exception 'Credit note date is required.'; end if;

  select * into inv from invoices where id=(p_header->>'invoice_id')::uuid and user_id=uid for update;
  if not found then raise exception 'Invoice not found.'; end if;
  if inv.document_status<>'posted' then raise exception 'Credit notes can only be issued against a posted invoice.'; end if;
  if inv.voucher_id is null then raise exception 'The original invoice has no posting voucher. Correct the legacy invoice before issuing a credit note.'; end if;
  if (p_header->>'cn_date')::date < inv.invoice_date then raise exception 'Credit note date cannot precede invoice date.'; end if;
  v_available:=round(inv.total-inv.credited_amount-inv.amount_paid,2);
  if v_available<=0.005 then raise exception 'No uncredited and unpaid invoice balance remains. Reverse/refund payments first.'; end if;
  select next_doc_number('credit_note',inv.fiscal_year) into v_num;
  if inv.party_id is not null then select account_id into v_party from parties where id=inv.party_id and user_id=uid; end if;
  if v_party is null then v_party:=resolve_system_account('ar_control'); end if;

  insert into credit_notes(user_id,cn_number,fiscal_year,cn_date,invoice_id,invoice_number,
    party_id,party_name,party_address,party_pan,reason,notes,document_status)
  values(uid,v_num,inv.fiscal_year,(p_header->>'cn_date')::date,inv.id,inv.invoice_number,
    inv.party_id,inv.party_name,inv.party_address,inv.party_pan,trim(p_header->>'reason'),nullif(trim(p_header->>'notes'),''),'posted')
  returning id into v_id;

  for l in select * from jsonb_array_elements(p_lines)
  loop
    if nullif(l->>'source_line_id','') is null then raise exception 'Every credit line must reference an original invoice line.'; end if;
    select * into orig from invoice_lines where id=(l->>'source_line_id')::uuid and invoice_id=inv.id;
    if not found then raise exception 'Original invoice line not found.'; end if;
    v_qty:=round(coalesce((l->>'quantity')::numeric,0),3);
    if v_qty<=0 then raise exception 'Credit quantity must be positive.'; end if;
    select coalesce(sum(cl.quantity),0) into v_prev_qty
    from credit_note_lines cl join credit_notes cn on cn.id=cl.credit_note_id
    where cl.source_line_id=orig.id and cn.document_status='posted';
    if v_prev_qty+v_qty>orig.quantity+0.0005 then
      raise exception 'Credit quantity exceeds remaining quantity for %.',orig.description;
    end if;
    v_amount:=round(v_qty*orig.rate,2);
    v_vat:=round(v_amount*orig.vat_rate/100,2);
    insert into credit_note_lines(credit_note_id,source_line_id,item_id,description,quantity,unit,
      rate,amount,vat_rate,vat_amount,line_total)
    values(v_id,orig.id,orig.item_id,orig.description,v_qty,orig.unit,orig.rate,v_amount,orig.vat_rate,v_vat,v_amount+v_vat)
    returning id into v_line_id;
    v_subtotal:=v_subtotal+v_amount; v_vat_total:=v_vat_total+v_vat;

    if orig.item_id is not null then
      select * into item from inventory_items where id=orig.item_id and user_id=uid and is_active=true for update;
      if found and coalesce(item.track_inventory,true) and coalesce(item.item_type,'goods')='goods' then
        if orig.inventory_unit_cost is null then
          raise exception 'Original invoice line % has no Stage 3 cost snapshot. Correct this legacy return through a reviewed journal.', orig.description;
        end if;
        select * into move from apply_inventory_movement(orig.item_id,v_qty,
          orig.inventory_unit_cost,
          (p_header->>'cn_date')::date,'sales_return','Credit Note #'||v_num,v_id,v_line_id,
          'Customer return against Invoice #'||inv.invoice_number);
        update credit_note_lines set inventory_unit_cost=move.applied_unit_cost,
          inventory_cost_amount=move.applied_total_cost where id=v_line_id;
        v_inventory:=v_inventory+move.applied_total_cost;
      end if;
    end if;
  end loop;
  v_total:=round(v_subtotal+v_vat_total,2);
  if v_total<=0.005 then raise exception 'Credit note total must be positive.'; end if;
  if v_total>v_available+0.005 then raise exception 'Credit note total % exceeds available unpaid balance %.',v_total,v_available; end if;

  v_lines:=jsonb_build_array(
    jsonb_build_object('account_id',resolve_system_account('sales'),'debit',v_subtotal,'credit',0,'description','Sales return'),
    jsonb_build_object('account_id',v_party,'debit',0,'credit',v_total,'description',inv.party_name)
  );
  if v_vat_total>0.005 then v_lines:=v_lines||jsonb_build_array(
    jsonb_build_object('account_id',resolve_system_account('vat_payable'),'debit',v_vat_total,'credit',0,'description','Output VAT reversed')
  ); end if;
  if v_inventory>0.005 then v_lines:=v_lines||jsonb_build_array(
    jsonb_build_object('account_id',resolve_system_account('inventory_asset'),'debit',v_inventory,'credit',0,'description','Returned inventory'),
    jsonb_build_object('account_id',resolve_system_account('cogs'),'debit',0,'credit',v_inventory,'description','COGS reversed')
  ); end if;

  v_voucher:=post_voucher('sales',inv.fiscal_year,(p_header->>'cn_date')::date,
    'Credit Note #'||v_num||' against Invoice #'||inv.invoice_number,v_lines);
  update vouchers set source_document_type='credit_note',source_document_id=v_id where id=v_voucher and user_id=uid;
  update inventory_movements set voucher_id=v_voucher where user_id=uid and source_type='sales_return' and reference_id=v_id and voucher_id is null;
  update credit_notes set subtotal=v_subtotal,vat_amount=v_vat_total,total=v_total,
    inventory_cost_amount=v_inventory,voucher_id=v_voucher,posted_at=now() where id=v_id;
  update invoices set credited_amount=round(credited_amount+v_total,2),
    net_total=greatest(round(total-(credited_amount+v_total),2),0),
    document_status=case when total-(credited_amount+v_total)<=0.005 then 'credited' else 'posted' end
  where id=inv.id and user_id=uid;
  perform refresh_document_payment_status('invoice',inv.id);
  perform write_audit_log('create','credit_notes',v_id::text,null,
    jsonb_build_object('invoice_id',inv.id,'total',v_total,'inventory_cost',v_inventory,'voucher_id',v_voucher));
  return v_id;
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
  perform assert_role(array['owner','accountant']);
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

create or replace function cancel_credit_note(p_credit_note_id uuid, p_reason text, p_date date default current_date)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid:=get_workspace_owner(); n record; inv record; l record; move record; party_acct uuid;
  v_inventory numeric(18,2):=0; v_voucher uuid; v_lines jsonb;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  perform assert_role(array['owner','accountant']);
  if nullif(trim(coalesce(p_reason,'')),'') is null then raise exception 'Cancellation reason is required.'; end if;
  select * into n from credit_notes where id=p_credit_note_id and user_id=uid for update;
  if not found or n.document_status<>'posted' then raise exception 'Posted credit note not found.'; end if;
  if n.voucher_id is null then raise exception 'Credit note has no posting voucher and cannot be automatically reversed.'; end if;
  select * into inv from invoices where id=n.invoice_id and user_id=uid for update;
  if inv.document_status='cancelled' then raise exception 'The original invoice is cancelled.'; end if;
  if p_date<n.cn_date then raise exception 'Cancellation date cannot precede credit note date.'; end if;
  if inv.party_id is not null then select account_id into party_acct from parties where id=inv.party_id and user_id=uid; end if;
  if party_acct is null then party_acct:=resolve_system_account('ar_control'); end if;
  for l in select * from credit_note_lines where credit_note_id=n.id and item_id is not null
  loop
    if l.inventory_cost_amount is not null then
      select * into move from apply_inventory_movement(l.item_id,-l.quantity,null,p_date,
        'sales_return_cancel','Credit note cancellation #'||n.cn_number,n.id,l.id,trim(p_reason));
      v_inventory:=v_inventory+move.applied_total_cost;
    end if;
  end loop;
  v_lines:=jsonb_build_array(
    jsonb_build_object('account_id',party_acct,'debit',n.total,'credit',0,'description',n.party_name),
    jsonb_build_object('account_id',resolve_system_account('sales'),'debit',0,'credit',n.subtotal,'description','Sales return cancelled')
  );
  if n.vat_amount>0.005 then v_lines:=v_lines||jsonb_build_array(
    jsonb_build_object('account_id',resolve_system_account('vat_payable'),'debit',0,'credit',n.vat_amount,'description','Output VAT restored')
  ); end if;
  if v_inventory>0.005 then v_lines:=v_lines||jsonb_build_array(
    jsonb_build_object('account_id',resolve_system_account('cogs'),'debit',v_inventory,'credit',0,'description','COGS restored'),
    jsonb_build_object('account_id',resolve_system_account('inventory_asset'),'debit',0,'credit',v_inventory,'description','Returned stock reissued')
  ); end if;
  v_voucher:=post_voucher('sales',n.fiscal_year,p_date,'Cancellation of Credit Note #'||n.cn_number||': '||trim(p_reason),v_lines);
  update vouchers set source_document_type='credit_note_cancellation',source_document_id=n.id,
    reversal_of_voucher_id=n.voucher_id,reversal_reason=trim(p_reason) where id=v_voucher and user_id=uid;
  update inventory_movements set voucher_id=v_voucher where user_id=uid and source_type='sales_return_cancel' and reference_id=n.id and voucher_id is null;
  update credit_notes set document_status='cancelled',cancelled_at=now(),cancellation_reason=left(trim(p_reason),500),cancellation_voucher_id=v_voucher where id=n.id;
  update invoices set credited_amount=greatest(round(credited_amount-n.total,2),0),
    net_total=least(total,round(total-greatest(credited_amount-n.total,0),2)),document_status='posted'
  where id=inv.id and user_id=uid;
  perform refresh_document_payment_status('invoice',inv.id);
  perform write_audit_log('cancel','credit_notes',n.id::text,null,jsonb_build_object('reason',trim(p_reason),'reversal_voucher_id',v_voucher));
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
  perform assert_role(array['owner','accountant']);
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
