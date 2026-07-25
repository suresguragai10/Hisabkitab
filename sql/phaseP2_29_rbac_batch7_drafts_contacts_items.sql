-- ============================================================
-- HisabKitab P2.29 -- RBAC batch 7 (final): drafts, contacts, items,
-- attachments.
--
-- Staff can create/edit invoice+bill drafts and create new
-- contacts/items (needed for day-to-day operational work), plus
-- attachments/notes. Editing an EXISTING contact or item, and
-- category management, stays owner+accountant (closer to a
-- structural/data-integrity change than routine drafting).
-- ============================================================

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
  perform assert_role(array['owner','accountant','staff']);
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
  perform assert_role(array['owner','accountant','staff']);
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
  perform assert_role(array['owner','accountant','staff']);
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
  perform assert_role(array['owner','accountant','staff']);
  update invoices set reprint_count=reprint_count+1,
    is_reprint=case when reprint_count+1>1 then true else is_reprint end
  where id=p_invoice_id and user_id=uid and document_status<>'draft'
  returning reprint_count into v_count;
  if v_count is null then raise exception 'Posted invoice not found.'; end if;
  return v_count;
end;
$$;

create or replace function create_contact(
  p_name text, p_name_np text default null, p_is_customer boolean default true, p_is_vendor boolean default false,
  p_contact_person text default null, p_phone text default null, p_email text default null,
  p_billing_address text default null, p_shipping_address text default null,
  p_pan_number text default null, p_vat_number text default null, p_payment_terms_days integer default null,
  p_tds_applicable boolean default false, p_tds_rate numeric default null, p_notes text default null,
  p_opening_balance numeric default 0, p_opening_balance_type text default 'debit'
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare uid uuid:=get_workspace_owner(); v_acct uuid; v_payable_acct uuid; v_party uuid; v_type text; v_code text;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  perform assert_role(array['owner','accountant','staff']);
  if p_name is null or btrim(p_name)='' then raise exception 'Contact name is required.'; end if;
  if not (p_is_customer or p_is_vendor) then raise exception 'Contact must be a customer or vendor.'; end if;
  if abs(coalesce(p_opening_balance,0))>0.005 then
    raise exception 'Create the contact first, then post its opening balance through Chart of Accounts > Opening Journal.';
  end if;

  if p_is_customer then
    v_code:=next_structured_account_code(uid,'current_asset','AR');
    insert into accounts(user_id,name,account_code,account_type,group_name,report_class,account_subtype,normal_balance,cash_flow_category,is_party_account,allow_manual_posting,opening_balance,opening_balance_type)
    values(uid,btrim(p_name),v_code,'asset','Current Asset','current_asset','receivable','debit','operating',true,true,0,'debit') returning id into v_acct;
  else
    v_code:=next_structured_account_code(uid,'current_liability','AP');
    insert into accounts(user_id,name,account_code,account_type,group_name,report_class,account_subtype,normal_balance,cash_flow_category,is_party_account,allow_manual_posting,opening_balance,opening_balance_type)
    values(uid,btrim(p_name),v_code,'liability','Current Liability','current_liability','payable','credit','operating',true,true,0,'credit') returning id into v_acct;
  end if;

  if p_is_customer and p_is_vendor then
    v_code:=next_structured_account_code(uid,'current_liability','AP');
    insert into accounts(user_id,name,account_code,account_type,group_name,report_class,account_subtype,normal_balance,cash_flow_category,is_party_account,allow_manual_posting,opening_balance,opening_balance_type)
    values(uid,btrim(p_name),v_code,'liability','Current Liability','current_liability','payable','credit','operating',true,true,0,'credit') returning id into v_payable_acct;
  end if;

  v_type:=case when p_is_customer and p_is_vendor then 'both' when p_is_customer then 'customer' else 'vendor' end;
  insert into parties(user_id,account_id,payable_account_id,party_type,name_np,contact_person,is_customer,is_vendor,phone,email,address,billing_address,shipping_address,pan_vat_number,pan_number,vat_number,payment_terms_days,tds_applicable,tds_rate,notes,is_active)
  values(uid,v_acct,v_payable_acct,v_type,p_name_np,p_contact_person,p_is_customer,p_is_vendor,p_phone,p_email,p_billing_address,p_billing_address,p_shipping_address,p_pan_number,p_pan_number,p_vat_number,p_payment_terms_days,coalesce(p_tds_applicable,false),p_tds_rate,p_notes,true)
  returning id into v_party;
  perform write_audit_log('create','parties',v_party::text,null,jsonb_build_object('name',p_name,'account_code',v_code));
  return v_party;
end;
$$;

create or replace function update_contact(
  p_id uuid, p_name text, p_name_np text default null, p_is_customer boolean default null, p_is_vendor boolean default null,
  p_contact_person text default null, p_phone text default null, p_email text default null,
  p_billing_address text default null, p_shipping_address text default null,
  p_pan_number text default null, p_vat_number text default null, p_payment_terms_days integer default null,
  p_tds_applicable boolean default null, p_tds_rate numeric default null, p_notes text default null,
  p_is_active boolean default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := get_workspace_owner();
  v_acct uuid;
  v_payable_acct uuid;
  v_is_both boolean;
  v_code text;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  perform assert_role(array['owner','accountant']);

  update parties set
    name_np            = coalesce(p_name_np, name_np),
    is_customer        = coalesce(p_is_customer, is_customer),
    is_vendor          = coalesce(p_is_vendor, is_vendor),
    contact_person     = coalesce(p_contact_person, contact_person),
    phone              = coalesce(p_phone, phone),
    email              = coalesce(p_email, email),
    billing_address    = coalesce(p_billing_address, billing_address),
    address            = coalesce(p_billing_address, address),
    shipping_address   = coalesce(p_shipping_address, shipping_address),
    pan_number         = coalesce(p_pan_number, pan_number),
    pan_vat_number     = coalesce(p_pan_number, pan_vat_number),
    vat_number         = coalesce(p_vat_number, vat_number),
    payment_terms_days = coalesce(p_payment_terms_days, payment_terms_days),
    tds_applicable     = coalesce(p_tds_applicable, tds_applicable),
    tds_rate           = coalesce(p_tds_rate, tds_rate),
    notes              = coalesce(p_notes, notes),
    is_active          = coalesce(p_is_active, is_active),
    party_type         = case
      when coalesce(p_is_customer, is_customer) and coalesce(p_is_vendor, is_vendor) then 'both'
      when coalesce(p_is_customer, is_customer) then 'customer'
      else 'vendor'
    end,
    updated_at         = now()
  where id = p_id and user_id = uid
  returning account_id, payable_account_id, (party_type = 'both') into v_acct, v_payable_acct, v_is_both;

  if v_acct is not null then
    update accounts set name = p_name where id = v_acct and user_id = uid;
  end if;

  if v_is_both and v_payable_acct is null then
    v_code := next_structured_account_code(uid, 'current_liability', 'AP');
    insert into accounts(user_id,name,account_code,account_type,group_name,report_class,account_subtype,normal_balance,cash_flow_category,is_party_account,allow_manual_posting,opening_balance,opening_balance_type)
    values(uid, p_name, v_code, 'liability','Current Liability','current_liability','payable','credit','operating',true,true,0,'credit')
    returning id into v_payable_acct;
    update parties set payable_account_id = v_payable_acct where id = p_id and user_id = uid;
  end if;

  perform write_audit_log('update','parties', p_id::text, null, jsonb_build_object('name', p_name));
end;
$$;

create or replace function create_item(
  p_name text, p_name_np text default null::text, p_sku text default null::text, p_hsn_code text default null::text,
  p_brand text default null::text, p_category_id uuid default null::uuid, p_item_type text default 'goods'::text,
  p_unit text default 'pcs'::text, p_sales_price numeric default 0, p_sales_tax_rate numeric default 13,
  p_sales_account_id uuid default null::uuid, p_purchase_price numeric default 0, p_purchase_tax_rate numeric default 13,
  p_purchase_account_id uuid default null::uuid, p_preferred_vendor_id uuid default null::uuid,
  p_track_inventory boolean default true, p_opening_stock numeric default 0, p_opening_stock_value numeric default 0,
  p_reorder_level numeric default 0, p_description text default null::text, p_opening_date date default current_date,
  p_fiscal_year text default null::text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := get_workspace_owner();
  v_id uuid;
  v_sales_acct uuid := p_sales_account_id;
  v_purch_acct uuid := p_purchase_account_id;
  v_track boolean := coalesce(p_track_inventory, true) and coalesce(p_item_type, 'goods') = 'goods';
  v_open_qty numeric(14,3) := round(greatest(coalesce(p_opening_stock, 0), 0), 3);
  v_open_value numeric(18,2);
  v_open_cost numeric(18,6);
  v_move record;
  v_voucher_id uuid;
  v_fy text := nullif(trim(coalesce(p_fiscal_year, '')), '');
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  perform assert_role(array['owner','accountant','staff']);
  if nullif(trim(coalesce(p_name, '')), '') is null then raise exception 'Item name is required.'; end if;
  if not v_track and v_open_qty > 0 then raise exception 'Opening stock is allowed only for tracked goods.'; end if;

  if p_category_id is not null and not exists (
    select 1 from item_categories where id = p_category_id and user_id = uid
  ) then raise exception 'Category does not belong to this business.'; end if;
  if p_preferred_vendor_id is not null and not exists (
    select 1 from parties where id = p_preferred_vendor_id and user_id = uid
  ) then raise exception 'Preferred vendor does not belong to this business.'; end if;

  if v_sales_acct is null then v_sales_acct := resolve_system_account('sales'); end if;
  if v_purch_acct is null then v_purch_acct := resolve_system_account('purchase'); end if;

  v_open_value := case
    when v_open_qty <= 0 then 0
    when coalesce(p_opening_stock_value, 0) > 0 then round(p_opening_stock_value, 2)
    else round(v_open_qty * greatest(coalesce(p_purchase_price, 0), 0), 2)
  end;
  v_open_cost := case when v_open_qty > 0 then round(v_open_value / v_open_qty, 6)
                      else round(greatest(coalesce(p_purchase_price, 0), 0), 6) end;

  insert into inventory_items (
    user_id, name, name_np, sku, hsn_code, brand, category_id,
    category, item_type, unit,
    selling_price, sales_tax_rate, sales_account_id,
    cost_price, average_cost, inventory_value, valuation_method,
    purchase_tax_rate, purchase_account_id,
    preferred_vendor_id, track_inventory,
    opening_stock, opening_stock_value, current_stock,
    reorder_level, description, is_active,
    valuation_start_date, valuation_updated_at
  ) values (
    uid, trim(p_name), p_name_np, p_sku, p_hsn_code, p_brand, p_category_id,
    coalesce((select name from item_categories where id = p_category_id and user_id = uid), 'General'),
    coalesce(p_item_type, 'goods'), coalesce(p_unit, 'pcs'),
    greatest(coalesce(p_sales_price, 0), 0), coalesce(p_sales_tax_rate, 13), v_sales_acct,
    round(v_open_cost, 2), v_open_cost, 0, 'weighted_average',
    coalesce(p_purchase_tax_rate, 13), v_purch_acct,
    p_preferred_vendor_id, v_track,
    v_open_qty, v_open_value, 0,
    greatest(coalesce(p_reorder_level, 0), 0), p_description, true,
    coalesce(p_opening_date, current_date), now()
  ) returning id into v_id;

  if v_track and v_open_qty > 0 then
    if v_fy is null then raise exception 'Fiscal year is required when opening stock is entered.'; end if;

    select * into v_move
      from apply_inventory_movement(
        v_id, v_open_qty, v_open_cost,
        coalesce(p_opening_date, current_date),
        'opening', 'Opening stock - ' || trim(p_name),
        v_id, null, 'Opening stock entered with item creation.'
      );

    if v_move.applied_total_cost > 0.005 then
      v_voucher_id := post_voucher(
        'journal', v_fy, coalesce(p_opening_date, current_date),
        'Opening stock - ' || trim(p_name),
        jsonb_build_array(
          jsonb_build_object(
            'account_id', resolve_system_account('inventory_asset'),
            'debit', v_move.applied_total_cost, 'credit', 0,
            'description', trim(p_name)
          ),
          jsonb_build_object(
            'account_id', resolve_system_account('inventory_opening'),
            'debit', 0, 'credit', v_move.applied_total_cost,
            'description', 'Opening inventory equity'
          )
        )
      );
      update inventory_movements set voucher_id = v_voucher_id where id = v_move.movement_id;
    end if;
  end if;

  perform write_audit_log(
    'create', 'inventory_items', v_id::text, null,
    jsonb_build_object(
      'name', trim(p_name),
      'category_id', p_category_id,
      'sku', p_sku,
      'opening_stock', v_open_qty,
      'opening_value', v_open_value,
      'opening_voucher_id', v_voucher_id
    )
  );
  return v_id;
end;
$$;

create or replace function update_item(
  p_id uuid, p_name text default null::text, p_name_np text default null::text, p_sku text default null::text,
  p_hsn_code text default null::text, p_brand text default null::text, p_category_id uuid default null::uuid,
  p_item_type text default null::text, p_unit text default null::text, p_sales_price numeric default null::numeric,
  p_sales_tax_rate numeric default null::numeric, p_sales_account_id uuid default null::uuid,
  p_purchase_price numeric default null::numeric, p_purchase_tax_rate numeric default null::numeric,
  p_purchase_account_id uuid default null::uuid, p_preferred_vendor_id uuid default null::uuid,
  p_track_inventory boolean default null::boolean, p_reorder_level numeric default null::numeric,
  p_description text default null::text, p_is_active boolean default null::boolean
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := get_workspace_owner();
  i record;
  v_new_track boolean;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  perform assert_role(array['owner','accountant']);

  select * into i from inventory_items where id = p_id and user_id = uid for update;
  if not found then raise exception 'Item not found.'; end if;

  v_new_track := coalesce(p_track_inventory, i.track_inventory);
  if abs(i.current_stock) > 0.0005 and not v_new_track then
    raise exception 'Tracked inventory cannot be disabled while stock is on hand.';
  end if;
  if abs(i.current_stock) > 0.0005
     and p_purchase_price is not null
     and abs(round(p_purchase_price, 2) - round(i.cost_price, 2)) > 0.005 then
    raise exception 'Average cost is database-managed while stock is on hand. Use an inventory adjustment instead.';
  end if;

  update inventory_items set
    name = coalesce(p_name, name),
    name_np = coalesce(p_name_np, name_np),
    sku = coalesce(p_sku, sku),
    hsn_code = coalesce(p_hsn_code, hsn_code),
    brand = coalesce(p_brand, brand),
    category_id = coalesce(p_category_id, category_id),
    category = coalesce((select name from item_categories where id = coalesce(p_category_id, category_id) and user_id = uid), category),
    item_type = coalesce(p_item_type, item_type),
    unit = coalesce(p_unit, unit),
    selling_price = coalesce(p_sales_price, selling_price),
    sales_tax_rate = coalesce(p_sales_tax_rate, sales_tax_rate),
    sales_account_id = coalesce(p_sales_account_id, sales_account_id),
    cost_price = case when abs(current_stock) <= 0.0005 then coalesce(p_purchase_price, cost_price) else cost_price end,
    average_cost = case when abs(current_stock) <= 0.0005 then coalesce(p_purchase_price, average_cost) else average_cost end,
    purchase_tax_rate = coalesce(p_purchase_tax_rate, purchase_tax_rate),
    purchase_account_id = coalesce(p_purchase_account_id, purchase_account_id),
    preferred_vendor_id = coalesce(p_preferred_vendor_id, preferred_vendor_id),
    track_inventory = v_new_track,
    reorder_level = coalesce(p_reorder_level, reorder_level),
    description = coalesce(p_description, description),
    is_active = coalesce(p_is_active, is_active),
    updated_at = now()
  where id = p_id and user_id = uid;

  perform write_audit_log('update', 'inventory_items', p_id::text, null,
    jsonb_build_object('name', p_name));
end;
$$;

create or replace function create_item_category(p_name text, p_name_np text default null::text, p_parent_id uuid default null::uuid, p_notes text default null::text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := get_workspace_owner();
  v_id uuid;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  perform assert_role(array['owner','accountant']);

  insert into item_categories (user_id, name, name_np, parent_id, notes)
  values (uid, p_name, p_name_np, p_parent_id, p_notes)
  on conflict (user_id, name) do update
    set name_np = excluded.name_np, notes = excluded.notes, updated_at = now()
  returning id into v_id;

  return v_id;
end;
$$;

create or replace function update_item_category(p_id uuid, p_name text default null::text, p_name_np text default null::text, p_parent_id uuid default null::uuid, p_sort_order integer default null::integer, p_notes text default null::text, p_is_active boolean default null::boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := get_workspace_owner();
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  perform assert_role(array['owner','accountant']);

  if not exists (select 1 from item_categories where id = p_id and user_id = uid) then
    raise exception 'Item category not found.';
  end if;

  update item_categories
     set name       = coalesce(p_name, name),
         name_np    = coalesce(p_name_np, name_np),
         parent_id  = coalesce(p_parent_id, parent_id),
         sort_order = coalesce(p_sort_order, sort_order),
         notes      = coalesce(p_notes, notes),
         is_active  = coalesce(p_is_active, is_active),
         updated_at = now()
   where id = p_id and user_id = uid;
end;
$$;

create or replace function add_document_internal_note(p_document_type text, p_document_id uuid, p_note_text text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := get_workspace_owner();
  v_id uuid;
begin
  perform assert_role(array['owner','accountant','staff']);
  if nullif(trim(coalesce(p_note_text,'')), '') is null then
    raise exception 'Internal note cannot be blank.';
  end if;
  perform assert_owned_document(p_document_type, p_document_id);
  insert into document_internal_notes(user_id, document_type, document_id, note_text)
  values(uid, p_document_type, p_document_id, left(trim(p_note_text), 4000))
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function delete_document_attachment(p_attachment_id uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := get_workspace_owner();
  v_path text;
begin
  perform assert_role(array['owner','accountant','staff']);
  delete from document_attachments
   where id = p_attachment_id and user_id = uid
   returning storage_path into v_path;
  if v_path is null then raise exception 'Attachment not found.'; end if;
  return v_path;
end;
$$;

create or replace function register_document_attachment(p_document_type text, p_document_id uuid, p_storage_path text, p_file_name text, p_mime_type text default null::text, p_size_bytes bigint default null::bigint)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  owner uuid := get_workspace_owner();
  actor uuid := auth.uid();
  v_id uuid;
begin
  perform assert_role(array['owner','accountant','staff']);
  perform assert_owned_document(p_document_type, p_document_id);
  if p_storage_path is null or split_part(p_storage_path, '/', 1) <> actor::text then
    raise exception 'Attachment path must be inside the signed-in owner folder.';
  end if;
  if p_size_bytes is not null and (p_size_bytes < 0 or p_size_bytes > 20971520) then
    raise exception 'Attachment size must not exceed 20 MB.';
  end if;
  insert into document_attachments(
    user_id, document_type, document_id, storage_path,
    file_name, mime_type, size_bytes
  ) values (
    owner, p_document_type, p_document_id, p_storage_path,
    left(coalesce(nullif(trim(p_file_name),''),'attachment'), 255),
    nullif(trim(p_mime_type),''), p_size_bytes
  ) returning id into v_id;
  return v_id;
end;
$$;
