-- ============================================================
-- HisabKitab P2.34 -- Reverse reference: an Invoice/Bill created by
-- converting a Sales Order/RFQ should show which one it came from,
-- not just the Sales Order/RFQ showing which Invoice/Bill it became.
-- sales_orders.invoice_id and purchase_quotations.bill_id already
-- exist (forward reference, from phaseP2_32); this adds the reverse
-- column on the other side so Invoices/Purchases can display and
-- link back to the source document without an extra lookup query
-- per row.
-- ============================================================

alter table invoices add column if not exists sales_order_id uuid references sales_orders(id);
alter table purchase_bills add column if not exists rfq_id uuid references purchase_quotations(id);

create index if not exists idx_invoices_sales_order on invoices(sales_order_id);
create index if not exists idx_purchase_bills_rfq on purchase_bills(rfq_id);

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
  update invoices set sales_order_id=o.id where id=v_invoice_id and user_id=uid;

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
  update purchase_bills set rfq_id=q.id where id=v_bill_id and user_id=uid;

  update purchase_quotations set status='converted', bill_id=v_bill_id, converted_at=now(), updated_at=now()
  where id=q.id and user_id=uid;
  perform write_audit_log('convert','purchase_quotations',q.id::text,null,jsonb_build_object('bill_id',v_bill_id));
  return v_bill_id;
end; $$;
