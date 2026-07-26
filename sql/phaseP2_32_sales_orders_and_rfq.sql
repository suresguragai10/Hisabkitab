-- ============================================================
-- HisabKitab P2.32 -- Sales Orders and RFQ/Purchase Quotations.
--
-- Design decisions confirmed with the user 2026-07-26:
--   * Sales Order = a pre-invoice commitment. Its own document
--     (own numbering/history, status draft->confirmed->converted or
--     cancelled). Converting copies its lines into a real invoice
--     DRAFT (not an auto-post) -- this reuses the existing, already
--     audited save_invoice_draft/post_invoice_draft path instead of
--     duplicating posting logic, so COGS/VAT/period-lock/RBAC all
--     still apply exactly as they do for a manually created invoice.
--   * RFQ (Purchase Quotation) mirrors Sales Order on the purchase
--     side: draft->sent->converted or cancelled, converts into a
--     purchase_bill DRAFT the same way.
--   * Sales Orders reserve stock: confirming one increments a new
--     inventory_items.committed_stock column (tracked-goods lines
--     only) so two orders can't oversell the same units.
--     Available-to-sell = current_stock - committed_stock. The
--     commitment is released the moment the order is converted or
--     cancelled -- it must never coexist with the real stock
--     decrement that happens later when the resulting invoice is
--     actually posted, or stock would be double-counted.
--   * RFQs do NOT reserve anything -- an RFQ is a request for future
--     purchases, not a claim on existing stock, so there's no
--     symmetric "commitment" on that side.
--   * Neither document type touches vouchers/accounts/GL at all --
--     that only happens once/if the resulting invoice or bill is
--     actually posted, same as any other draft.
-- ============================================================

alter table inventory_items add column if not exists committed_stock numeric(14,3) not null default 0;

create table if not exists sales_orders (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  order_number integer not null,
  fiscal_year text not null,
  order_date date not null,
  order_date_bs text,
  expected_date date,
  party_id uuid references parties(id),
  party_name text not null,
  party_address text,
  party_pan text,
  subtotal numeric(14,2) not null default 0,
  vat_amount numeric(14,2) not null default 0,
  total numeric(14,2) not null default 0,
  status text not null default 'draft' check (status in ('draft','confirmed','converted','cancelled')),
  stock_committed boolean not null default false,
  notes text,
  invoice_id uuid references invoices(id),
  confirmed_at timestamptz,
  converted_at timestamptz,
  cancelled_at timestamptz,
  cancellation_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists sales_order_lines (
  id uuid primary key default gen_random_uuid(),
  sales_order_id uuid not null references sales_orders(id) on delete cascade,
  item_id uuid references inventory_items(id),
  description text not null,
  quantity numeric(10,3) not null default 1,
  unit text default 'pcs',
  rate numeric(14,2) not null default 0,
  amount numeric(14,2) not null default 0,
  vat_rate numeric(5,2) not null default 13,
  vat_amount numeric(14,2) not null default 0,
  line_total numeric(14,2) not null default 0,
  hsn_code text,
  vat_treatment text not null default 'standard' check (vat_treatment in ('standard','zero_rated','exempt','out_of_scope'))
);

create table if not exists purchase_quotations (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  rfq_number integer not null,
  fiscal_year text not null,
  rfq_date date not null,
  rfq_date_bs text,
  expected_date date,
  vendor_id uuid references parties(id),
  vendor_name text not null,
  vendor_address text,
  vendor_pan text,
  subtotal numeric(14,2) not null default 0,
  vat_amount numeric(14,2) not null default 0,
  total numeric(14,2) not null default 0,
  status text not null default 'draft' check (status in ('draft','sent','converted','cancelled')),
  notes text,
  bill_id uuid references purchase_bills(id),
  sent_at timestamptz,
  converted_at timestamptz,
  cancelled_at timestamptz,
  cancellation_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists purchase_quotation_lines (
  id uuid primary key default gen_random_uuid(),
  purchase_quotation_id uuid not null references purchase_quotations(id) on delete cascade,
  item_id uuid references inventory_items(id),
  description text not null,
  quantity numeric(10,3) not null default 1,
  unit text default 'pcs',
  rate numeric(14,2) not null default 0,
  amount numeric(14,2) not null default 0,
  vat_rate numeric(5,2) not null default 13,
  vat_amount numeric(14,2) not null default 0,
  line_total numeric(14,2) not null default 0,
  hsn_code text,
  vat_treatment text not null default 'standard' check (vat_treatment in ('standard','zero_rated','exempt','out_of_scope'))
);

alter table sales_orders enable row level security;
alter table sales_order_lines enable row level security;
alter table purchase_quotations enable row level security;
alter table purchase_quotation_lines enable row level security;

-- SELECT-only RLS, same as invoices/bills/credit_notes/debit_notes --
-- all writes go exclusively through the SECURITY DEFINER functions
-- below, which bypass RLS by running as the function owner.
drop policy if exists "own sales orders" on sales_orders;
create policy "own sales orders" on sales_orders for select
  using (can_access_workspace(user_id));
drop policy if exists "own sales order lines" on sales_order_lines;
create policy "own sales order lines" on sales_order_lines for select
  using (exists (
    select 1 from sales_orders o
    where o.id = sales_order_lines.sales_order_id and can_access_workspace(o.user_id)
  ));
drop policy if exists "own purchase quotations" on purchase_quotations;
create policy "own purchase quotations" on purchase_quotations for select
  using (can_access_workspace(user_id));
drop policy if exists "own purchase quotation lines" on purchase_quotation_lines;
create policy "own purchase quotation lines" on purchase_quotation_lines for select
  using (exists (
    select 1 from purchase_quotations q
    where q.id = purchase_quotation_lines.purchase_quotation_id and can_access_workspace(q.user_id)
  ));

create index if not exists idx_sales_orders_user_date on sales_orders(user_id, order_date desc);
create index if not exists idx_sales_orders_party on sales_orders(party_id);
create index if not exists idx_sales_order_lines_order on sales_order_lines(sales_order_id);
create index if not exists idx_purchase_quotations_user_date on purchase_quotations(user_id, rfq_date desc);
create index if not exists idx_purchase_quotations_vendor on purchase_quotations(vendor_id);
create index if not exists idx_purchase_quotation_lines_quotation on purchase_quotation_lines(purchase_quotation_id);

grant select on sales_orders, sales_order_lines, purchase_quotations, purchase_quotation_lines to authenticated;

-- ============================================================
-- Sales Order functions
-- ============================================================

create or replace function save_sales_order_draft(p_header jsonb, p_lines jsonb, p_order_id uuid default null::uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare uid uuid:=get_workspace_owner(); v_id uuid:=p_order_id; v_num integer; v_fy text;
  v_subtotal numeric(14,2); v_vat numeric(14,2); v_total numeric(14,2); v_existing record;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  perform assert_role(array['owner','accountant','staff']);
  if p_lines is null or jsonb_typeof(p_lines)<>'array' or jsonb_array_length(p_lines)=0 then raise exception 'At least one line is required.'; end if;
  v_fy:=nullif(trim(p_header->>'fiscal_year'),'');
  if v_fy is null then raise exception 'Fiscal year is required.'; end if;
  if nullif(p_header->>'order_date','') is null then raise exception 'Order date is required.'; end if;
  if nullif(p_header->>'expected_date','') is not null and (p_header->>'expected_date')::date<(p_header->>'order_date')::date then raise exception 'Expected date cannot precede order date.'; end if;
  if nullif(trim(p_header->>'party_name'),'') is null then raise exception 'Customer name is required.'; end if;
  if nullif(p_header->>'party_id','') is not null and not exists(select 1 from parties where id=(p_header->>'party_id')::uuid and user_id=uid) then raise exception 'Customer does not belong to this business.'; end if;
  if exists(select 1 from jsonb_array_elements(p_lines) l where nullif(trim(l->>'description'),'') is null
    or coalesce((l->>'quantity')::numeric,0)<=0 or coalesce((l->>'rate')::numeric,0)<0
    or coalesce((l->>'vat_rate')::numeric,0)<0 or coalesce((l->>'vat_rate')::numeric,0)>100
    or coalesce(nullif(l->>'vat_treatment',''),case when coalesce((l->>'vat_rate')::numeric,0)>0 then 'standard' else 'exempt' end) not in ('standard','zero_rated','exempt','out_of_scope')
    or (coalesce(nullif(l->>'vat_treatment',''),case when coalesce((l->>'vat_rate')::numeric,0)>0 then 'standard' else 'exempt' end)='standard' and coalesce((l->>'vat_rate')::numeric,0)<=0)
    or (coalesce(nullif(l->>'vat_treatment',''),case when coalesce((l->>'vat_rate')::numeric,0)>0 then 'standard' else 'exempt' end)<>'standard' and abs(coalesce((l->>'vat_rate')::numeric,0))>0.0001)
  ) then raise exception 'Order lines have an invalid amount or VAT treatment.'; end if;
  if exists(select 1 from jsonb_array_elements(p_lines) l left join inventory_items i on i.id=nullif(l->>'item_id','')::uuid and i.user_id=uid and i.is_active=true where nullif(l->>'item_id','') is not null and i.id is null) then raise exception 'One or more order items do not belong to this business.'; end if;
  select coalesce(sum(round(coalesce((l->>'quantity')::numeric,1)*coalesce((l->>'rate')::numeric,0),2)),0),
    coalesce(sum(round(round(coalesce((l->>'quantity')::numeric,1)*coalesce((l->>'rate')::numeric,0),2)*coalesce((l->>'vat_rate')::numeric,0)/100,2)),0)
  into v_subtotal,v_vat from jsonb_array_elements(p_lines) l;
  v_total:=round(v_subtotal+v_vat,2); if v_total<=0 then raise exception 'Order total must be positive.'; end if;
  if v_id is null then
    select next_doc_number('sales_order',v_fy) into v_num;
    insert into sales_orders(user_id,order_number,fiscal_year,order_date,expected_date,party_id,party_name,party_address,party_pan,
      subtotal,vat_amount,total,status,notes,order_date_bs)
    values(uid,v_num,v_fy,(p_header->>'order_date')::date,nullif(p_header->>'expected_date','')::date,nullif(p_header->>'party_id','')::uuid,
      trim(p_header->>'party_name'),nullif(trim(p_header->>'party_address'),''),nullif(trim(p_header->>'party_pan'),''),v_subtotal,v_vat,v_total,
      'draft',nullif(trim(p_header->>'notes'),''),coalesce(p_header->>'order_date_bs','')) returning id into v_id;
  else
    select * into v_existing from sales_orders where id=v_id and user_id=uid for update;
    if not found then raise exception 'Sales order not found.'; end if;
    if v_existing.status<>'draft' then raise exception 'Only a draft sales order can be edited.'; end if;
    if v_existing.fiscal_year<>v_fy then raise exception 'Fiscal year cannot change after a document number is assigned.'; end if;
    update sales_orders set order_date=(p_header->>'order_date')::date,expected_date=nullif(p_header->>'expected_date','')::date,
      party_id=nullif(p_header->>'party_id','')::uuid,party_name=trim(p_header->>'party_name'),party_address=nullif(trim(p_header->>'party_address'),''),
      party_pan=nullif(trim(p_header->>'party_pan'),''),subtotal=v_subtotal,vat_amount=v_vat,total=v_total,
      notes=nullif(trim(p_header->>'notes'),''),order_date_bs=coalesce(p_header->>'order_date_bs',''),updated_at=now()
    where id=v_id and user_id=uid; delete from sales_order_lines where sales_order_id=v_id;
  end if;
  insert into sales_order_lines(sales_order_id,description,quantity,unit,rate,amount,vat_rate,vat_amount,line_total,item_id,hsn_code,vat_treatment)
  select v_id,trim(l->>'description'),round(coalesce((l->>'quantity')::numeric,1),3),coalesce(nullif(l->>'unit',''),'pcs'),
    round(coalesce((l->>'rate')::numeric,0),2),round(coalesce((l->>'quantity')::numeric,1)*coalesce((l->>'rate')::numeric,0),2),
    round(coalesce((l->>'vat_rate')::numeric,0),2),round(round(coalesce((l->>'quantity')::numeric,1)*coalesce((l->>'rate')::numeric,0),2)*coalesce((l->>'vat_rate')::numeric,0)/100,2),
    round(coalesce((l->>'quantity')::numeric,1)*coalesce((l->>'rate')::numeric,0),2)+round(round(coalesce((l->>'quantity')::numeric,1)*coalesce((l->>'rate')::numeric,0),2)*coalesce((l->>'vat_rate')::numeric,0)/100,2),
    nullif(l->>'item_id','')::uuid,nullif(l->>'hsn_code',''),coalesce(nullif(l->>'vat_treatment',''),case when coalesce((l->>'vat_rate')::numeric,0)>0 then 'standard' else 'exempt' end)
  from jsonb_array_elements(p_lines) l;
  perform write_audit_log(case when p_order_id is null then 'create_draft' else 'update_draft' end,'sales_orders',v_id::text,null,jsonb_build_object('total',v_total,'status','draft'));
  return v_id;
end; $$;

create or replace function confirm_sales_order(p_order_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare uid uuid:=get_workspace_owner(); o sales_orders%rowtype;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  perform assert_role(array['owner','accountant']);
  select * into o from sales_orders where id=p_order_id and user_id=uid for update;
  if not found then raise exception 'Sales order not found.'; end if;
  if o.status<>'draft' then raise exception 'Only a draft sales order can be confirmed.'; end if;
  if not exists(select 1 from sales_order_lines where sales_order_id=o.id) then raise exception 'Sales order has no lines.'; end if;

  -- Aggregate by item first -- a plain UPDATE...FROM only applies one
  -- matching source row per target row, not the sum, so an order with
  -- the same item on two lines would otherwise under-reserve stock.
  update inventory_items i set committed_stock = committed_stock + agg.qty
  from (
    select item_id, sum(quantity) as qty
    from sales_order_lines
    where sales_order_id = o.id and item_id is not null
    group by item_id
  ) agg
  where agg.item_id=i.id and i.user_id=uid
    and coalesce(i.track_inventory,true) and coalesce(i.item_type,'goods')='goods';

  update sales_orders set status='confirmed', stock_committed=true, confirmed_at=now(), updated_at=now()
  where id=o.id and user_id=uid;
  perform write_audit_log('confirm','sales_orders',o.id::text,null,jsonb_build_object('total',o.total));
end; $$;

create or replace function cancel_sales_order(p_order_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare uid uuid:=get_workspace_owner(); o sales_orders%rowtype;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  perform assert_role(array['owner','accountant']);
  if nullif(trim(p_reason),'') is null then raise exception 'A cancellation reason is required.'; end if;
  select * into o from sales_orders where id=p_order_id and user_id=uid for update;
  if not found then raise exception 'Sales order not found.'; end if;
  if o.status not in ('draft','confirmed') then raise exception 'Only a draft or confirmed sales order can be cancelled.'; end if;

  if o.stock_committed then
    update inventory_items i set committed_stock = greatest(committed_stock - agg.qty, 0)
    from (
      select item_id, sum(quantity) as qty
      from sales_order_lines
      where sales_order_id = o.id and item_id is not null
      group by item_id
    ) agg
    where agg.item_id=i.id and i.user_id=uid;
  end if;

  update sales_orders set status='cancelled', stock_committed=false, cancelled_at=now(), cancellation_reason=trim(p_reason), updated_at=now()
  where id=o.id and user_id=uid;
  perform write_audit_log('cancel','sales_orders',o.id::text,null,jsonb_build_object('reason',trim(p_reason)));
end; $$;

create or replace function convert_sales_order_to_invoice(p_order_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare uid uuid:=get_workspace_owner(); o sales_orders%rowtype; v_invoice_id uuid; v_lines jsonb;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  perform assert_role(array['owner','accountant']);
  select * into o from sales_orders where id=p_order_id and user_id=uid for update;
  if not found then raise exception 'Sales order not found.'; end if;
  if o.status<>'confirmed' then raise exception 'Only a confirmed sales order can be converted to an invoice.'; end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'description',l.description,'quantity',l.quantity,'unit',l.unit,'rate',l.rate,
    'vat_rate',l.vat_rate,'vat_treatment',l.vat_treatment,'item_id',l.item_id,'hsn_code',l.hsn_code
  )),'[]'::jsonb) into v_lines
  from sales_order_lines l where l.sales_order_id=o.id;

  v_invoice_id := save_invoice_draft(
    jsonb_build_object(
      'fiscal_year',o.fiscal_year,'invoice_date',current_date,'party_id',o.party_id,
      'party_name',o.party_name,'party_address',o.party_address,'party_pan',o.party_pan,
      'notes','Converted from Sales Order '||o.order_number
    ),
    v_lines
  );

  if o.stock_committed then
    update inventory_items i set committed_stock = greatest(committed_stock - agg.qty, 0)
    from (
      select item_id, sum(quantity) as qty
      from sales_order_lines
      where sales_order_id = o.id and item_id is not null
      group by item_id
    ) agg
    where agg.item_id=i.id and i.user_id=uid;
  end if;

  update sales_orders set status='converted', stock_committed=false, invoice_id=v_invoice_id, converted_at=now(), updated_at=now()
  where id=o.id and user_id=uid;
  perform write_audit_log('convert','sales_orders',o.id::text,null,jsonb_build_object('invoice_id',v_invoice_id));
  return v_invoice_id;
end; $$;

-- ============================================================
-- RFQ / Purchase Quotation functions
-- ============================================================

create or replace function save_rfq_draft(p_header jsonb, p_lines jsonb, p_rfq_id uuid default null::uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare uid uuid:=get_workspace_owner(); v_id uuid:=p_rfq_id; v_num integer; v_fy text;
  v_subtotal numeric(14,2); v_vat numeric(14,2); v_total numeric(14,2); v_existing record;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  perform assert_role(array['owner','accountant','staff']);
  if p_lines is null or jsonb_typeof(p_lines)<>'array' or jsonb_array_length(p_lines)=0 then raise exception 'At least one line is required.'; end if;
  v_fy:=nullif(trim(p_header->>'fiscal_year'),'');
  if v_fy is null then raise exception 'Fiscal year is required.'; end if;
  if nullif(p_header->>'rfq_date','') is null then raise exception 'RFQ date is required.'; end if;
  if nullif(p_header->>'expected_date','') is not null and (p_header->>'expected_date')::date<(p_header->>'rfq_date')::date then raise exception 'Expected date cannot precede RFQ date.'; end if;
  if nullif(trim(p_header->>'vendor_name'),'') is null then raise exception 'Vendor name is required.'; end if;
  if nullif(p_header->>'vendor_id','') is not null and not exists(select 1 from parties where id=(p_header->>'vendor_id')::uuid and user_id=uid) then raise exception 'Vendor does not belong to this business.'; end if;
  if exists(select 1 from jsonb_array_elements(p_lines) l where nullif(trim(l->>'description'),'') is null
    or coalesce((l->>'quantity')::numeric,0)<=0 or coalesce((l->>'rate')::numeric,0)<0
    or coalesce((l->>'vat_rate')::numeric,0)<0 or coalesce((l->>'vat_rate')::numeric,0)>100
    or coalesce(nullif(l->>'vat_treatment',''),case when coalesce((l->>'vat_rate')::numeric,0)>0 then 'standard' else 'exempt' end) not in ('standard','zero_rated','exempt','out_of_scope')
    or (coalesce(nullif(l->>'vat_treatment',''),case when coalesce((l->>'vat_rate')::numeric,0)>0 then 'standard' else 'exempt' end)='standard' and coalesce((l->>'vat_rate')::numeric,0)<=0)
    or (coalesce(nullif(l->>'vat_treatment',''),case when coalesce((l->>'vat_rate')::numeric,0)>0 then 'standard' else 'exempt' end)<>'standard' and abs(coalesce((l->>'vat_rate')::numeric,0))>0.0001)
  ) then raise exception 'RFQ lines have an invalid amount or VAT treatment.'; end if;
  if exists(select 1 from jsonb_array_elements(p_lines) l left join inventory_items i on i.id=nullif(l->>'item_id','')::uuid and i.user_id=uid and i.is_active=true where nullif(l->>'item_id','') is not null and i.id is null) then raise exception 'One or more RFQ items do not belong to this business.'; end if;
  select coalesce(sum(round(coalesce((l->>'quantity')::numeric,1)*coalesce((l->>'rate')::numeric,0),2)),0),
    coalesce(sum(round(round(coalesce((l->>'quantity')::numeric,1)*coalesce((l->>'rate')::numeric,0),2)*coalesce((l->>'vat_rate')::numeric,0)/100,2)),0)
  into v_subtotal,v_vat from jsonb_array_elements(p_lines) l;
  v_total:=round(v_subtotal+v_vat,2); if v_total<=0 then raise exception 'RFQ total must be positive.'; end if;
  if v_id is null then
    select next_doc_number('rfq',v_fy) into v_num;
    insert into purchase_quotations(user_id,rfq_number,fiscal_year,rfq_date,expected_date,vendor_id,vendor_name,vendor_address,vendor_pan,
      subtotal,vat_amount,total,status,notes,rfq_date_bs)
    values(uid,v_num,v_fy,(p_header->>'rfq_date')::date,nullif(p_header->>'expected_date','')::date,nullif(p_header->>'vendor_id','')::uuid,
      trim(p_header->>'vendor_name'),nullif(trim(p_header->>'vendor_address'),''),nullif(trim(p_header->>'vendor_pan'),''),v_subtotal,v_vat,v_total,
      'draft',nullif(trim(p_header->>'notes'),''),coalesce(p_header->>'rfq_date_bs','')) returning id into v_id;
  else
    select * into v_existing from purchase_quotations where id=v_id and user_id=uid for update;
    if not found then raise exception 'RFQ not found.'; end if;
    if v_existing.status<>'draft' then raise exception 'Only a draft RFQ can be edited.'; end if;
    if v_existing.fiscal_year<>v_fy then raise exception 'Fiscal year cannot change after a document number is assigned.'; end if;
    update purchase_quotations set rfq_date=(p_header->>'rfq_date')::date,expected_date=nullif(p_header->>'expected_date','')::date,
      vendor_id=nullif(p_header->>'vendor_id','')::uuid,vendor_name=trim(p_header->>'vendor_name'),vendor_address=nullif(trim(p_header->>'vendor_address'),''),
      vendor_pan=nullif(trim(p_header->>'vendor_pan'),''),subtotal=v_subtotal,vat_amount=v_vat,total=v_total,
      notes=nullif(trim(p_header->>'notes'),''),rfq_date_bs=coalesce(p_header->>'rfq_date_bs',''),updated_at=now()
    where id=v_id and user_id=uid; delete from purchase_quotation_lines where purchase_quotation_id=v_id;
  end if;
  insert into purchase_quotation_lines(purchase_quotation_id,description,quantity,unit,rate,amount,vat_rate,vat_amount,line_total,item_id,hsn_code,vat_treatment)
  select v_id,trim(l->>'description'),round(coalesce((l->>'quantity')::numeric,1),3),coalesce(nullif(l->>'unit',''),'pcs'),
    round(coalesce((l->>'rate')::numeric,0),2),round(coalesce((l->>'quantity')::numeric,1)*coalesce((l->>'rate')::numeric,0),2),
    round(coalesce((l->>'vat_rate')::numeric,0),2),round(round(coalesce((l->>'quantity')::numeric,1)*coalesce((l->>'rate')::numeric,0),2)*coalesce((l->>'vat_rate')::numeric,0)/100,2),
    round(coalesce((l->>'quantity')::numeric,1)*coalesce((l->>'rate')::numeric,0),2)+round(round(coalesce((l->>'quantity')::numeric,1)*coalesce((l->>'rate')::numeric,0),2)*coalesce((l->>'vat_rate')::numeric,0)/100,2),
    nullif(l->>'item_id','')::uuid,nullif(l->>'hsn_code',''),coalesce(nullif(l->>'vat_treatment',''),case when coalesce((l->>'vat_rate')::numeric,0)>0 then 'standard' else 'exempt' end)
  from jsonb_array_elements(p_lines) l;
  perform write_audit_log(case when p_rfq_id is null then 'create_draft' else 'update_draft' end,'purchase_quotations',v_id::text,null,jsonb_build_object('total',v_total,'status','draft'));
  return v_id;
end; $$;

create or replace function send_rfq(p_rfq_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare uid uuid:=get_workspace_owner(); q purchase_quotations%rowtype;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  perform assert_role(array['owner','accountant']);
  select * into q from purchase_quotations where id=p_rfq_id and user_id=uid for update;
  if not found then raise exception 'RFQ not found.'; end if;
  if q.status<>'draft' then raise exception 'Only a draft RFQ can be marked as sent.'; end if;
  if not exists(select 1 from purchase_quotation_lines where purchase_quotation_id=q.id) then raise exception 'RFQ has no lines.'; end if;
  update purchase_quotations set status='sent', sent_at=now(), updated_at=now() where id=q.id and user_id=uid;
  perform write_audit_log('send','purchase_quotations',q.id::text,null,jsonb_build_object('total',q.total));
end; $$;

create or replace function cancel_rfq(p_rfq_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare uid uuid:=get_workspace_owner(); q purchase_quotations%rowtype;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  perform assert_role(array['owner','accountant']);
  if nullif(trim(p_reason),'') is null then raise exception 'A cancellation reason is required.'; end if;
  select * into q from purchase_quotations where id=p_rfq_id and user_id=uid for update;
  if not found then raise exception 'RFQ not found.'; end if;
  if q.status not in ('draft','sent') then raise exception 'Only a draft or sent RFQ can be cancelled.'; end if;
  update purchase_quotations set status='cancelled', cancelled_at=now(), cancellation_reason=trim(p_reason), updated_at=now()
  where id=q.id and user_id=uid;
  perform write_audit_log('cancel','purchase_quotations',q.id::text,null,jsonb_build_object('reason',trim(p_reason)));
end; $$;

create or replace function convert_rfq_to_bill(p_rfq_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare uid uuid:=get_workspace_owner(); q purchase_quotations%rowtype; v_bill_id uuid; v_lines jsonb;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  perform assert_role(array['owner','accountant']);
  select * into q from purchase_quotations where id=p_rfq_id and user_id=uid for update;
  if not found then raise exception 'RFQ not found.'; end if;
  if q.status<>'sent' then raise exception 'Only an RFQ that has been sent can be converted to a bill.'; end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'description',l.description,'quantity',l.quantity,'unit',l.unit,'rate',l.rate,
    'vat_rate',l.vat_rate,'vat_treatment',l.vat_treatment,'item_id',l.item_id,'hsn_code',l.hsn_code
  )),'[]'::jsonb) into v_lines
  from purchase_quotation_lines l where l.purchase_quotation_id=q.id;

  v_bill_id := save_bill_draft(
    jsonb_build_object(
      'fiscal_year',q.fiscal_year,'bill_date',current_date,'vendor_id',q.vendor_id,
      'vendor_name',q.vendor_name,'vendor_address',q.vendor_address,'vendor_pan',q.vendor_pan,
      'notes','Converted from RFQ '||q.rfq_number
    ),
    v_lines
  );

  update purchase_quotations set status='converted', bill_id=v_bill_id, converted_at=now(), updated_at=now()
  where id=q.id and user_id=uid;
  perform write_audit_log('convert','purchase_quotations',q.id::text,null,jsonb_build_object('bill_id',v_bill_id));
  return v_bill_id;
end; $$;

-- ============================================================
-- Wire the new document types into the existing generic
-- attachments/notes/draft-delete dispatch (additive -- every other
-- branch is untouched).
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
    when 'sales_order' then select exists(select 1 from sales_orders where id=p_document_id and user_id=uid) into v_exists;
    when 'rfq' then select exists(select 1 from purchase_quotations where id=p_document_id and user_id=uid) into v_exists;
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
  elsif p_document_type='sales_order' then
    delete from sales_orders where id=p_document_id and user_id=uid and status='draft';
  elsif p_document_type='rfq' then
    delete from purchase_quotations where id=p_document_id and user_id=uid and status='draft';
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

grant execute on function save_sales_order_draft(jsonb,jsonb,uuid) to authenticated;
grant execute on function confirm_sales_order(uuid) to authenticated;
grant execute on function cancel_sales_order(uuid,text) to authenticated;
grant execute on function convert_sales_order_to_invoice(uuid) to authenticated;
grant execute on function save_rfq_draft(jsonb,jsonb,uuid) to authenticated;
grant execute on function send_rfq(uuid) to authenticated;
grant execute on function cancel_rfq(uuid,text) to authenticated;
grant execute on function convert_rfq_to_bill(uuid) to authenticated;

-- Surface the new committed_stock column (additive) so Items/Inventory
-- can show "available to sell" instead of just current_stock.
--
-- The live view has 5 more columns (average_cost, inventory_value,
-- valuation_method, valuation_updated_at, valuation_start_date -- a
-- later weighted-average-costing migration not reflected in
-- phaseP3_masters.sql, confirmed live 2026-07-26 via
-- information_schema.columns) than the repo file this was originally
-- copied from. Every existing column below is reproduced in its
-- live ordinal position; only committed_stock/available_stock are
-- new, appended at the very end since CREATE OR REPLACE VIEW cannot
-- reorder or insert columns among existing ones.
create or replace view item_summary as
select
  i.id,
  i.user_id,
  i.name,
  i.name_np,
  i.sku,
  i.hsn_code,
  i.brand,
  i.category_id,
  c.name as category_name,
  i.item_type,
  i.unit,
  i.selling_price   as sales_price,
  i.sales_tax_rate,
  i.sales_account_id,
  i.cost_price      as purchase_price,
  i.purchase_tax_rate,
  i.purchase_account_id,
  i.preferred_vendor_id,
  pv_a.name as preferred_vendor_name,
  i.track_inventory,
  i.current_stock,
  i.reorder_level,
  case when i.reorder_level > 0 and i.current_stock <= i.reorder_level
       then true else false end as is_low_stock,
  i.description,
  i.is_active,
  i.created_at,
  i.updated_at,
  i.average_cost,
  i.inventory_value,
  i.valuation_method,
  i.valuation_updated_at,
  i.valuation_start_date,
  i.committed_stock,
  (i.current_stock - i.committed_stock) as available_stock
from inventory_items i
left join item_categories c on c.id = i.category_id
left join parties pv on pv.id = i.preferred_vendor_id
left join accounts pv_a on pv_a.id = pv.account_id;

grant select on item_summary to authenticated;
