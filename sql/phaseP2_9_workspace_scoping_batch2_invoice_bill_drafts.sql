-- ============================================================
-- HisabKitab P2.9 -- Workspace-scoping fix, batch 2: Invoice/Bill
-- drafts and posting.
--
-- Part of the larger workspace-scoping remediation (see memory:
-- workspace_scoping_gap.md). Fetched live and fixed with the minimal,
-- mechanical change: the uid variable's source only (auth.uid() ->
-- get_workspace_owner()). No other logic touched.
-- ============================================================

create or replace function assert_owned_document(p_document_type text, p_document_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := get_workspace_owner();
  v_exists boolean := false;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  case p_document_type
    when 'invoice' then select exists(select 1 from invoices where id=p_document_id and user_id=uid) into v_exists;
    when 'bill' then select exists(select 1 from purchase_bills where id=p_document_id and user_id=uid) into v_exists;
    when 'credit_note' then select exists(select 1 from credit_notes where id=p_document_id and user_id=uid) into v_exists;
    when 'debit_note' then select exists(select 1 from debit_notes where id=p_document_id and user_id=uid) into v_exists;
    else raise exception 'Unsupported document type: %', p_document_type;
  end case;
  if not v_exists then raise exception 'Document not found.'; end if;
end;
$$;

create or replace function delete_document_draft(p_document_type text, p_document_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := get_workspace_owner();
  v_rows integer;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  if exists (
    select 1 from document_attachments
     where user_id=uid and document_type=p_document_type and document_id=p_document_id
  ) then
    raise exception 'Delete draft attachments before deleting the draft.';
  end if;
  if p_document_type='invoice' then
    delete from invoices where id=p_document_id and user_id=uid and document_status='draft';
  elsif p_document_type='bill' then
    delete from purchase_bills where id=p_document_id and user_id=uid and document_status='draft';
  else
    raise exception 'Unsupported draft type.';
  end if;
  get diagnostics v_rows = row_count;
  if v_rows=0 then raise exception 'Draft not found or already posted.'; end if;
  delete from document_internal_notes
   where user_id=uid and document_type=p_document_type and document_id=p_document_id;
  perform write_audit_log('delete_draft', p_document_type, p_document_id::text, null, null);
end;
$$;

create or replace function mark_invoice_printed(p_invoice_id uuid)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare uid uuid:=get_workspace_owner(); v_count integer;
begin
  update invoices set reprint_count=reprint_count+1,
    is_reprint=case when reprint_count+1>1 then true else is_reprint end
  where id=p_invoice_id and user_id=uid and document_status<>'draft'
  returning reprint_count into v_count;
  if v_count is null then raise exception 'Posted invoice not found.'; end if;
  return v_count;
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

create or replace function save_bill_draft(p_header jsonb, p_lines jsonb, p_bill_id uuid default null::uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare uid uuid:=get_workspace_owner(); v_id uuid:=p_bill_id; v_num integer; v_fy text;
  v_subtotal numeric(14,2); v_vat numeric(14,2); v_total numeric(14,2); v_existing record;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  if p_lines is null or jsonb_typeof(p_lines)<>'array' or jsonb_array_length(p_lines)=0 then raise exception 'At least one bill line is required.'; end if;
  v_fy:=nullif(trim(p_header->>'fiscal_year'),''); if v_fy is null then raise exception 'Fiscal year is required.'; end if;
  if nullif(p_header->>'bill_date','') is null then raise exception 'Bill date is required.'; end if;
  if nullif(p_header->>'due_date','') is not null and (p_header->>'due_date')::date<(p_header->>'bill_date')::date then raise exception 'Bill due date cannot precede bill date.'; end if;
  if nullif(trim(p_header->>'vendor_name'),'') is null then raise exception 'Vendor name is required.'; end if;
  if nullif(p_header->>'vendor_id','') is not null and not exists(select 1 from parties where id=(p_header->>'vendor_id')::uuid and user_id=uid) then raise exception 'Vendor does not belong to this business.'; end if;
  if exists(select 1 from jsonb_array_elements(p_lines) l where nullif(trim(l->>'description'),'') is null
    or coalesce((l->>'quantity')::numeric,0)<=0 or coalesce((l->>'rate')::numeric,0)<0
    or coalesce((l->>'vat_rate')::numeric,0)<0 or coalesce((l->>'vat_rate')::numeric,0)>100
    or coalesce(nullif(l->>'vat_treatment',''),case when coalesce((l->>'vat_rate')::numeric,0)>0 then 'standard' else 'exempt' end) not in ('standard','zero_rated','exempt','out_of_scope')
    or (coalesce(nullif(l->>'vat_treatment',''),case when coalesce((l->>'vat_rate')::numeric,0)>0 then 'standard' else 'exempt' end)='standard' and coalesce((l->>'vat_rate')::numeric,0)<=0)
    or (coalesce(nullif(l->>'vat_treatment',''),case when coalesce((l->>'vat_rate')::numeric,0)>0 then 'standard' else 'exempt' end)<>'standard' and abs(coalesce((l->>'vat_rate')::numeric,0))>0.0001)
  ) then raise exception 'Bill lines have an invalid amount or VAT treatment.'; end if;
  if exists(select 1 from jsonb_array_elements(p_lines) l left join inventory_items i on i.id=nullif(l->>'item_id','')::uuid and i.user_id=uid and i.is_active=true where nullif(l->>'item_id','') is not null and i.id is null) then raise exception 'One or more bill items do not belong to this business.'; end if;
  select coalesce(sum(round(coalesce((l->>'quantity')::numeric,1)*coalesce((l->>'rate')::numeric,0),2)),0),
    coalesce(sum(round(round(coalesce((l->>'quantity')::numeric,1)*coalesce((l->>'rate')::numeric,0),2)*coalesce((l->>'vat_rate')::numeric,0)/100,2)),0)
  into v_subtotal,v_vat from jsonb_array_elements(p_lines) l;
  v_total:=round(v_subtotal+v_vat,2); if v_total<=0 then raise exception 'Bill total must be positive.'; end if;
  if v_id is null then
    select next_doc_number('bill',v_fy) into v_num;
    insert into purchase_bills(user_id,bill_number,fiscal_year,bill_date,due_date,vendor_id,vendor_name,vendor_address,vendor_pan,vendor_bill_ref,
      subtotal,vat_amount,total,status,document_status,notes,amount_paid,outstanding_amount,credited_amount,net_total,payment_status_updated_at)
    values(uid,v_num,v_fy,(p_header->>'bill_date')::date,nullif(p_header->>'due_date','')::date,nullif(p_header->>'vendor_id','')::uuid,
      trim(p_header->>'vendor_name'),nullif(trim(p_header->>'vendor_address'),''),nullif(trim(p_header->>'vendor_pan'),''),nullif(trim(p_header->>'vendor_bill_ref'),''),
      v_subtotal,v_vat,v_total,'draft','draft',nullif(trim(p_header->>'notes'),''),0,v_total,0,v_total,now()) returning id into v_id;
  else
    select * into v_existing from purchase_bills where id=v_id and user_id=uid for update;
    if not found then raise exception 'Bill draft not found.'; end if;
    if v_existing.document_status<>'draft' then raise exception 'Only a draft bill can be edited.'; end if;
    if v_existing.fiscal_year<>v_fy then raise exception 'Fiscal year cannot change after a document number is assigned.'; end if;
    update purchase_bills set bill_date=(p_header->>'bill_date')::date,due_date=nullif(p_header->>'due_date','')::date,
      vendor_id=nullif(p_header->>'vendor_id','')::uuid,vendor_name=trim(p_header->>'vendor_name'),vendor_address=nullif(trim(p_header->>'vendor_address'),''),
      vendor_pan=nullif(trim(p_header->>'vendor_pan'),''),vendor_bill_ref=nullif(trim(p_header->>'vendor_bill_ref'),''),subtotal=v_subtotal,vat_amount=v_vat,total=v_total,
      net_total=v_total,outstanding_amount=v_total,notes=nullif(trim(p_header->>'notes'),''),payment_status_updated_at=now()
    where id=v_id and user_id=uid; delete from purchase_bill_lines where bill_id=v_id;
  end if;
  insert into purchase_bill_lines(bill_id,description,quantity,unit,rate,amount,vat_rate,vat_amount,line_total,item_id,hsn_code,vat_treatment)
  select v_id,trim(l->>'description'),round(coalesce((l->>'quantity')::numeric,1),3),coalesce(nullif(l->>'unit',''),'pcs'),
    round(coalesce((l->>'rate')::numeric,0),2),round(coalesce((l->>'quantity')::numeric,1)*coalesce((l->>'rate')::numeric,0),2),
    round(coalesce((l->>'vat_rate')::numeric,0),2),round(round(coalesce((l->>'quantity')::numeric,1)*coalesce((l->>'rate')::numeric,0),2)*coalesce((l->>'vat_rate')::numeric,0)/100,2),
    round(coalesce((l->>'quantity')::numeric,1)*coalesce((l->>'rate')::numeric,0),2)+round(round(coalesce((l->>'quantity')::numeric,1)*coalesce((l->>'rate')::numeric,0),2)*coalesce((l->>'vat_rate')::numeric,0)/100,2),
    nullif(l->>'item_id','')::uuid,nullif(l->>'hsn_code',''),coalesce(nullif(l->>'vat_treatment',''),case when coalesce((l->>'vat_rate')::numeric,0)>0 then 'standard' else 'exempt' end)
  from jsonb_array_elements(p_lines) l;
  perform write_audit_log(case when p_bill_id is null then 'create_draft' else 'update_draft' end,'purchase_bills',v_id::text,null,jsonb_build_object('total',v_total,'document_status','draft'));
  return v_id;
end; $$;

create or replace function save_invoice_draft(p_header jsonb, p_lines jsonb, p_invoice_id uuid default null::uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare uid uuid:=get_workspace_owner(); v_id uuid:=p_invoice_id; v_num integer; v_fy text;
  v_subtotal numeric(14,2); v_vat numeric(14,2); v_total numeric(14,2); v_existing record;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  if p_lines is null or jsonb_typeof(p_lines)<>'array' or jsonb_array_length(p_lines)=0 then raise exception 'At least one invoice line is required.'; end if;
  v_fy:=nullif(trim(p_header->>'fiscal_year'),'');
  if v_fy is null then raise exception 'Fiscal year is required.'; end if;
  if nullif(p_header->>'invoice_date','') is null then raise exception 'Invoice date is required.'; end if;
  if nullif(p_header->>'due_date','') is not null and (p_header->>'due_date')::date<(p_header->>'invoice_date')::date then raise exception 'Invoice due date cannot precede invoice date.'; end if;
  if nullif(trim(p_header->>'party_name'),'') is null then raise exception 'Customer name is required.'; end if;
  if nullif(p_header->>'party_id','') is not null and not exists(select 1 from parties where id=(p_header->>'party_id')::uuid and user_id=uid) then raise exception 'Customer does not belong to this business.'; end if;
  if exists(select 1 from jsonb_array_elements(p_lines) l where nullif(trim(l->>'description'),'') is null
    or coalesce((l->>'quantity')::numeric,0)<=0 or coalesce((l->>'rate')::numeric,0)<0
    or coalesce((l->>'vat_rate')::numeric,0)<0 or coalesce((l->>'vat_rate')::numeric,0)>100
    or coalesce(nullif(l->>'vat_treatment',''),case when coalesce((l->>'vat_rate')::numeric,0)>0 then 'standard' else 'exempt' end) not in ('standard','zero_rated','exempt','out_of_scope')
    or (coalesce(nullif(l->>'vat_treatment',''),case when coalesce((l->>'vat_rate')::numeric,0)>0 then 'standard' else 'exempt' end)='standard' and coalesce((l->>'vat_rate')::numeric,0)<=0)
    or (coalesce(nullif(l->>'vat_treatment',''),case when coalesce((l->>'vat_rate')::numeric,0)>0 then 'standard' else 'exempt' end)<>'standard' and abs(coalesce((l->>'vat_rate')::numeric,0))>0.0001)
  ) then raise exception 'Invoice lines have an invalid amount or VAT treatment.'; end if;
  if exists(select 1 from jsonb_array_elements(p_lines) l left join inventory_items i on i.id=nullif(l->>'item_id','')::uuid and i.user_id=uid and i.is_active=true where nullif(l->>'item_id','') is not null and i.id is null) then raise exception 'One or more invoice items do not belong to this business.'; end if;
  select coalesce(sum(round(coalesce((l->>'quantity')::numeric,1)*coalesce((l->>'rate')::numeric,0),2)),0),
    coalesce(sum(round(round(coalesce((l->>'quantity')::numeric,1)*coalesce((l->>'rate')::numeric,0),2)*coalesce((l->>'vat_rate')::numeric,0)/100,2)),0)
  into v_subtotal,v_vat from jsonb_array_elements(p_lines) l;
  v_total:=round(v_subtotal+v_vat,2); if v_total<=0 then raise exception 'Invoice total must be positive.'; end if;
  if v_id is null then
    select next_doc_number('invoice',v_fy) into v_num;
    insert into invoices(user_id,invoice_number,fiscal_year,invoice_date,due_date,party_id,party_name,party_address,party_pan,
      subtotal,vat_amount,total,status,document_status,notes,invoice_date_bs,due_date_bs,amount_paid,outstanding_amount,credited_amount,net_total,payment_status_updated_at)
    values(uid,v_num,v_fy,(p_header->>'invoice_date')::date,nullif(p_header->>'due_date','')::date,nullif(p_header->>'party_id','')::uuid,
      trim(p_header->>'party_name'),nullif(trim(p_header->>'party_address'),''),nullif(trim(p_header->>'party_pan'),''),v_subtotal,v_vat,v_total,
      'draft','draft',nullif(trim(p_header->>'notes'),''),coalesce(p_header->>'invoice_date_bs',''),coalesce(p_header->>'due_date_bs',''),0,v_total,0,v_total,now()) returning id into v_id;
  else
    select * into v_existing from invoices where id=v_id and user_id=uid for update;
    if not found then raise exception 'Invoice draft not found.'; end if;
    if v_existing.document_status<>'draft' then raise exception 'Only a draft invoice can be edited.'; end if;
    if v_existing.fiscal_year<>v_fy then raise exception 'Fiscal year cannot change after a document number is assigned.'; end if;
    update invoices set invoice_date=(p_header->>'invoice_date')::date,due_date=nullif(p_header->>'due_date','')::date,
      party_id=nullif(p_header->>'party_id','')::uuid,party_name=trim(p_header->>'party_name'),party_address=nullif(trim(p_header->>'party_address'),''),
      party_pan=nullif(trim(p_header->>'party_pan'),''),subtotal=v_subtotal,vat_amount=v_vat,total=v_total,net_total=v_total,outstanding_amount=v_total,
      notes=nullif(trim(p_header->>'notes'),''),invoice_date_bs=coalesce(p_header->>'invoice_date_bs',''),due_date_bs=coalesce(p_header->>'due_date_bs',''),payment_status_updated_at=now()
    where id=v_id and user_id=uid; delete from invoice_lines where invoice_id=v_id;
  end if;
  insert into invoice_lines(invoice_id,description,quantity,unit,rate,amount,vat_rate,vat_amount,line_total,item_id,hsn_code,vat_treatment)
  select v_id,trim(l->>'description'),round(coalesce((l->>'quantity')::numeric,1),3),coalesce(nullif(l->>'unit',''),'pcs'),
    round(coalesce((l->>'rate')::numeric,0),2),round(coalesce((l->>'quantity')::numeric,1)*coalesce((l->>'rate')::numeric,0),2),
    round(coalesce((l->>'vat_rate')::numeric,0),2),round(round(coalesce((l->>'quantity')::numeric,1)*coalesce((l->>'rate')::numeric,0),2)*coalesce((l->>'vat_rate')::numeric,0)/100,2),
    round(coalesce((l->>'quantity')::numeric,1)*coalesce((l->>'rate')::numeric,0),2)+round(round(coalesce((l->>'quantity')::numeric,1)*coalesce((l->>'rate')::numeric,0),2)*coalesce((l->>'vat_rate')::numeric,0)/100,2),
    nullif(l->>'item_id','')::uuid,nullif(l->>'hsn_code',''),coalesce(nullif(l->>'vat_treatment',''),case when coalesce((l->>'vat_rate')::numeric,0)>0 then 'standard' else 'exempt' end)
  from jsonb_array_elements(p_lines) l;
  perform write_audit_log(case when p_invoice_id is null then 'create_draft' else 'update_draft' end,'invoices',v_id::text,null,jsonb_build_object('total',v_total,'document_status','draft'));
  return v_id;
end; $$;
