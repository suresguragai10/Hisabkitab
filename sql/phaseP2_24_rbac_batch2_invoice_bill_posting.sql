-- ============================================================
-- HisabKitab P2.24 -- RBAC batch 2: posting/cancelling invoices and
-- bills (owner + accountant).
-- ============================================================

create or replace function post_invoice_draft(p_invoice_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := get_workspace_owner();
  h record;
  l record;
  item record;
  debtor_acct uuid;
  v_voucher_id uuid;
  v_cogs numeric(18,2) := 0;
  v_move record;
  v_lines jsonb;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  perform assert_role(array['owner','accountant']);
  select * into h from invoices
   where id=p_invoice_id and user_id=uid for update;
  if not found then raise exception 'Invoice draft not found.'; end if;
  if h.document_status <> 'draft' then raise exception 'Only a draft invoice can be posted.'; end if;
  if h.voucher_id is not null then raise exception 'Draft invoice already has a posting voucher.'; end if;
  if h.total <= 0 then raise exception 'Invoice total must be positive.'; end if;
  if not exists(select 1 from invoice_lines where invoice_id=h.id) then raise exception 'Invoice has no lines.'; end if;

  if h.party_id is not null then
    select account_id into debtor_acct from parties where id=h.party_id and user_id=uid;
    if debtor_acct is null then raise exception 'Customer does not belong to this business.'; end if;
  else debtor_acct := resolve_system_account('ar_control'); end if;

  for l in select * from invoice_lines where invoice_id=h.id order by id
  loop
    if l.item_id is not null then
      select * into item from inventory_items
       where id=l.item_id and user_id=uid and is_active=true for update;
      if not found then raise exception 'Invoice item does not belong to this business.'; end if;
      if coalesce(item.track_inventory,true) and coalesce(item.item_type,'goods')='goods' then
        select * into v_move from apply_inventory_movement(
          l.item_id, -l.quantity, null, h.invoice_date,
          'sale', 'Invoice #'||h.invoice_number, h.id, l.id,
          'Automatic stock issue and COGS for posted invoice.'
        );
        update invoice_lines set
          inventory_unit_cost=v_move.applied_unit_cost,
          inventory_cost_amount=v_move.applied_total_cost
        where id=l.id;
        v_cogs := v_cogs + v_move.applied_total_cost;
      end if;
    end if;
  end loop;

  v_lines := jsonb_build_array(
    jsonb_build_object('account_id',debtor_acct,'debit',h.total,'credit',0,'description',h.party_name),
    jsonb_build_object('account_id',resolve_system_account('sales'),'debit',0,'credit',h.subtotal,'description','Sales')
  );
  if h.vat_amount > 0.005 then
    v_lines := v_lines || jsonb_build_array(
      jsonb_build_object('account_id',resolve_system_account('vat_payable'),'debit',0,'credit',h.vat_amount,'description','Output VAT')
    );
  end if;
  if v_cogs > 0.005 then
    v_lines := v_lines || jsonb_build_array(
      jsonb_build_object('account_id',resolve_system_account('cogs'),'debit',v_cogs,'credit',0,'description','Cost of goods sold'),
      jsonb_build_object('account_id',resolve_system_account('inventory_asset'),'debit',0,'credit',v_cogs,'description','Inventory issued')
    );
  end if;

  v_voucher_id := post_voucher('sales',h.fiscal_year,h.invoice_date,
    'Sales Invoice #'||h.invoice_number,v_lines);
  update vouchers set source_document_type='invoice', source_document_id=h.id
   where id=v_voucher_id and user_id=uid;
  update inventory_movements set voucher_id=v_voucher_id
   where user_id=uid and source_type='sale' and reference_id=h.id and voucher_id is null;
  update invoices set
    voucher_id=v_voucher_id, cogs_amount=round(v_cogs,2),
    document_status='posted', posted_at=now(), status='open',
    net_total=total, outstanding_amount=total, payment_status_updated_at=now()
  where id=h.id and user_id=uid;
  perform write_audit_log('post','invoices',h.id::text,null,
    jsonb_build_object('voucher_id',v_voucher_id,'cogs',v_cogs));
  return h.id;
end;
$$;

create or replace function post_bill_draft(p_bill_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := get_workspace_owner();
  h record;
  l record;
  item record;
  creditor_acct uuid;
  v_voucher_id uuid;
  v_inventory numeric(18,2) := 0;
  v_expense numeric(18,2) := 0;
  v_move record;
  v_lines jsonb;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  perform assert_role(array['owner','accountant']);
  select * into h from purchase_bills
   where id=p_bill_id and user_id=uid for update;
  if not found then raise exception 'Bill draft not found.'; end if;
  if h.document_status <> 'draft' then raise exception 'Only a draft bill can be posted.'; end if;
  if h.voucher_id is not null then raise exception 'Draft bill already has a posting voucher.'; end if;
  if h.total <= 0 then raise exception 'Bill total must be positive.'; end if;
  if not exists(select 1 from purchase_bill_lines where bill_id=h.id) then raise exception 'Bill has no lines.'; end if;

  if h.vendor_id is not null then
    select coalesce(payable_account_id, account_id) into creditor_acct from parties where id=h.vendor_id and user_id=uid;
    if creditor_acct is null then raise exception 'Vendor does not belong to this business.'; end if;
  else creditor_acct := resolve_system_account('ap_control'); end if;

  for l in select * from purchase_bill_lines where bill_id=h.id order by id
  loop
    if l.item_id is not null then
      select * into item from inventory_items
       where id=l.item_id and user_id=uid and is_active=true for update;
      if not found then raise exception 'Purchase item does not belong to this business.'; end if;
      if coalesce(item.track_inventory,true) and coalesce(item.item_type,'goods')='goods' then
        select * into v_move from apply_inventory_movement(
          l.item_id, l.quantity, round(l.amount/l.quantity,6), h.bill_date,
          'purchase', 'Bill #'||h.bill_number, h.id, l.id,
          'Automatic stock receipt for posted purchase bill.'
        );
        update purchase_bill_lines set
          inventory_unit_cost=v_move.applied_unit_cost,
          inventory_cost_amount=v_move.applied_total_cost
        where id=l.id;
        v_inventory := v_inventory + v_move.applied_total_cost;
      else v_expense := v_expense + l.amount; end if;
    else v_expense := v_expense + l.amount; end if;
  end loop;
  v_expense := greatest(round(h.subtotal-v_inventory,2),0);

  v_lines := jsonb_build_array(
    jsonb_build_object('account_id',creditor_acct,'debit',0,'credit',h.total,'description',h.vendor_name)
  );
  if v_inventory > 0.005 then v_lines := v_lines || jsonb_build_array(
    jsonb_build_object('account_id',resolve_system_account('inventory_asset'),'debit',v_inventory,'credit',0,'description','Tracked inventory purchased')
  ); end if;
  if v_expense > 0.005 then v_lines := v_lines || jsonb_build_array(
    jsonb_build_object('account_id',resolve_system_account('purchase'),'debit',v_expense,'credit',0,'description','Non-inventory purchases')
  ); end if;
  if h.vat_amount > 0.005 then v_lines := v_lines || jsonb_build_array(
    jsonb_build_object('account_id',resolve_system_account('vat_receivable'),'debit',h.vat_amount,'credit',0,'description','Input VAT')
  ); end if;

  v_voucher_id := post_voucher('purchase',h.fiscal_year,h.bill_date,
    'Purchase Bill #'||h.bill_number,v_lines);
  update vouchers set source_document_type='purchase_bill', source_document_id=h.id
   where id=v_voucher_id and user_id=uid;
  update inventory_movements set voucher_id=v_voucher_id
   where user_id=uid and source_type='purchase' and reference_id=h.id and voucher_id is null;
  update purchase_bills set
    voucher_id=v_voucher_id, inventory_amount=round(v_inventory,2), expense_amount=round(v_expense,2),
    document_status='posted', posted_at=now(), status='open',
    net_total=total, outstanding_amount=total, payment_status_updated_at=now()
  where id=h.id and user_id=uid;
  perform write_audit_log('post','purchase_bills',h.id::text,null,
    jsonb_build_object('voucher_id',v_voucher_id,'inventory',v_inventory,'expense',v_expense));
  return h.id;
end;
$$;

create or replace function cancel_invoice_document(p_invoice_id uuid, p_reason text, p_date date default current_date)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid:=get_workspace_owner(); h record; l record; move record; party_acct uuid;
  v_inventory numeric(18,2):=0; v_voucher uuid; v_lines jsonb;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  perform assert_role(array['owner','accountant']);
  if nullif(trim(coalesce(p_reason,'')),'') is null then raise exception 'Cancellation reason is required.'; end if;
  select * into h from invoices where id=p_invoice_id and user_id=uid for update;
  if not found then raise exception 'Invoice not found.'; end if;
  if h.document_status<>'posted' then raise exception 'Only a posted invoice can be cancelled.'; end if;
  if h.voucher_id is null then raise exception 'Invoice has no posting voucher and cannot be automatically reversed.'; end if;
  if h.amount_paid>0.005 then raise exception 'Reverse all receipts before cancelling this invoice.'; end if;
  if h.credited_amount>0.005 then raise exception 'Cancel linked credit notes before cancelling this invoice.'; end if;
  if p_date<h.invoice_date then raise exception 'Cancellation date cannot precede invoice date.'; end if;
  if h.party_id is not null then select account_id into party_acct from parties where id=h.party_id and user_id=uid; end if;
  if party_acct is null then party_acct:=resolve_system_account('ar_control'); end if;

  for l in select il.*, i.track_inventory, i.item_type from invoice_lines il
    join inventory_items i on i.id=il.item_id and i.user_id=uid
    where il.invoice_id=h.id and il.item_id is not null
  loop
    if coalesce(l.track_inventory,true) and coalesce(l.item_type,'goods')='goods' then
      if l.inventory_cost_amount is null or l.inventory_unit_cost is null then
        raise exception 'Invoice contains legacy inventory lines without cost snapshots. Use a reviewed correction instead of automatic cancellation.';
      end if;
      select * into move from apply_inventory_movement(l.item_id,l.quantity,l.inventory_unit_cost,p_date,
        'sale_cancel','Invoice cancellation #'||h.invoice_number,h.id,l.id,trim(p_reason));
      v_inventory:=v_inventory+move.applied_total_cost;
    end if;
  end loop;
  v_lines:=jsonb_build_array(
    jsonb_build_object('account_id',resolve_system_account('sales'),'debit',h.subtotal,'credit',0,'description','Cancelled sales'),
    jsonb_build_object('account_id',party_acct,'debit',0,'credit',h.total,'description',h.party_name)
  );
  if h.vat_amount>0.005 then v_lines:=v_lines||jsonb_build_array(
    jsonb_build_object('account_id',resolve_system_account('vat_payable'),'debit',h.vat_amount,'credit',0,'description','Output VAT reversed')
  ); end if;
  if v_inventory>0.005 then v_lines:=v_lines||jsonb_build_array(
    jsonb_build_object('account_id',resolve_system_account('inventory_asset'),'debit',v_inventory,'credit',0,'description','Cancelled sale stock restored'),
    jsonb_build_object('account_id',resolve_system_account('cogs'),'debit',0,'credit',v_inventory,'description','Cancelled COGS')
  ); end if;
  v_voucher:=post_voucher('sales',h.fiscal_year,p_date,'Cancellation of Invoice #'||h.invoice_number||': '||trim(p_reason),v_lines);
  update vouchers set source_document_type='invoice_cancellation',source_document_id=h.id,
    reversal_of_voucher_id=h.voucher_id,reversal_reason=trim(p_reason) where id=v_voucher and user_id=uid;
  update inventory_movements set voucher_id=v_voucher where user_id=uid and source_type='sale_cancel' and reference_id=h.id and voucher_id is null;
  update invoices set document_status='cancelled',status='cancelled',cancelled_at=now(),
    cancellation_reason=left(trim(p_reason),500),cancellation_voucher_id=v_voucher,
    outstanding_amount=0,payment_status_updated_at=now() where id=h.id and user_id=uid;
  perform write_audit_log('cancel','invoices',h.id::text,null,jsonb_build_object('reason',trim(p_reason),'reversal_voucher_id',v_voucher));
  return v_voucher;
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
  perform assert_role(array['owner','accountant']);
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
