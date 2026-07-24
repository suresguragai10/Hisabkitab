-- ============================================================
-- HisabKitab P2.5 — Give "both" (customer + vendor) parties two
-- separate accounts instead of one misclassified account.
--
-- create_contact() only ever created ONE account per party, chosen
-- by an if/else on p_is_customer -- so a "both" party always got a
-- receivable-classified account, even for the vendor side. Both
-- post_invoice_draft() and post_bill_draft() post to
-- parties.account_id, so every purchase from a "both" party credited
-- what's structurally a receivable/asset account instead of a
-- genuine payable/liability account. Confirmed live on "Sures"
-- (party_type='both'): its purchase bills credited a receivable
-- account, not a payable one.
--
-- Fix: add parties.payable_account_id. create_contact() now creates
-- both accounts for a "both" party; update_contact() auto-creates
-- the missing payable account if a party becomes "both" later;
-- post_bill_draft() now prefers payable_account_id (falling back to
-- account_id for plain vendors, so their existing behavior is
-- unchanged). post_invoice_draft() needs no change -- account_id
-- stays the receivable side regardless.
-- ============================================================

alter table parties add column if not exists payable_account_id uuid references accounts(id);

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
declare uid uuid:=auth.uid(); v_acct uuid; v_payable_acct uuid; v_party uuid; v_type text; v_code text;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
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

  -- A "both" party needs its own separate payable account too --
  -- customer and vendor balances must never share one ledger account.
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
  uid uuid := auth.uid();
  v_acct uuid;
  v_payable_acct uuid;
  v_is_both boolean;
  v_code text;
begin
  if uid is null then raise exception 'Not authenticated'; end if;

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

  -- A customer-only or vendor-only party that just became "both" needs
  -- its second account created now, the same as if it had been "both"
  -- from the start.
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

create or replace function post_bill_draft(p_bill_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
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
    -- Prefer the party's dedicated payable account (set for "both"
    -- customer+vendor parties); falls back to account_id for plain
    -- vendors, where that has always correctly been the payable account.
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
