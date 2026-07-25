-- ============================================================
-- HisabKitab P2.31 -- Close a foreign-key ownership gap on
-- item/category writes (audit item 5.2).
--
-- Found while re-auditing PRODUCT_AUDIT.md's 5.2 finding
-- ("security-definer functions need ownership checks for every
-- foreign key"): create_item() already validated p_category_id and
-- p_preferred_vendor_id belong to the caller's business, but never
-- validated p_sales_account_id/p_purchase_account_id the same way.
-- update_item() was worse -- it validated NONE of its four foreign
-- IDs (category_id, preferred_vendor_id, sales_account_id,
-- purchase_account_id). create_item_category()/update_item_category()
-- never validated p_parent_id either.
--
-- Impact today is low (sales_account_id/purchase_account_id on an
-- item aren't currently read by post_invoice_draft/post_bill_draft --
-- those always post to the system-wide sales/purchase account, not
-- a per-item override -- and item_categories.parent_id is just a
-- display hierarchy), but a foreign UUID could still be silently
-- attached to your own records today, and either field becoming
-- load-bearing in a future feature would turn a silent gap into a
-- live cross-tenant leak. Fixing it now costs nothing and matches
-- the pattern create_item() already uses for its other two FKs.
--
-- The same gap also existed on create_structured_account()/
-- update_structured_account()'s p_parent_account_id (Chart of
-- Accounts hierarchy) -- fixed below too, same reasoning.
--
-- Only the validation blocks were added -- every other line is
-- byte-for-byte identical to the live versions in
-- phaseP2_29_rbac_batch7_drafts_contacts_items.sql and
-- phaseP2_23_rbac_batch1_owner_only.sql.
-- ============================================================

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
  if p_sales_account_id is not null and not exists (
    select 1 from accounts where id = p_sales_account_id and user_id = uid
  ) then raise exception 'Sales account does not belong to this business.'; end if;
  if p_purchase_account_id is not null and not exists (
    select 1 from accounts where id = p_purchase_account_id and user_id = uid
  ) then raise exception 'Purchase account does not belong to this business.'; end if;

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

  if p_category_id is not null and not exists (
    select 1 from item_categories where id = p_category_id and user_id = uid
  ) then raise exception 'Category does not belong to this business.'; end if;
  if p_preferred_vendor_id is not null and not exists (
    select 1 from parties where id = p_preferred_vendor_id and user_id = uid
  ) then raise exception 'Preferred vendor does not belong to this business.'; end if;
  if p_sales_account_id is not null and not exists (
    select 1 from accounts where id = p_sales_account_id and user_id = uid
  ) then raise exception 'Sales account does not belong to this business.'; end if;
  if p_purchase_account_id is not null and not exists (
    select 1 from accounts where id = p_purchase_account_id and user_id = uid
  ) then raise exception 'Purchase account does not belong to this business.'; end if;

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

  if p_parent_id is not null and not exists (
    select 1 from item_categories where id = p_parent_id and user_id = uid
  ) then raise exception 'Parent category does not belong to this business.'; end if;

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

  if p_parent_id is not null and not exists (
    select 1 from item_categories where id = p_parent_id and user_id = uid
  ) then raise exception 'Parent category does not belong to this business.'; end if;
  if p_parent_id = p_id then
    raise exception 'A category cannot be its own parent.';
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

create or replace function create_structured_account(p_name text, p_account_code text, p_account_type text, p_report_class text, p_account_subtype text default 'general'::text, p_normal_balance text default null::text, p_parent_account_id uuid default null::uuid, p_cash_flow_category text default 'operating'::text, p_allow_manual_posting boolean default true)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid:=get_workspace_owner();
  v_id uuid;
  v_code text;
  v_normal text;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  perform assert_role(array['owner']);
  if p_name is null or btrim(p_name)='' then raise exception 'Account name is required.'; end if;
  if p_parent_account_id is not null and not exists (
    select 1 from accounts where id = p_parent_account_id and user_id = uid
  ) then raise exception 'Parent account does not belong to this business.'; end if;
  v_normal:=coalesce(p_normal_balance,case when p_account_type in ('asset','expense') then 'debit' else 'credit' end);
  v_code:=coalesce(nullif(btrim(p_account_code),''),next_structured_account_code(uid,p_report_class,null));

  insert into accounts(
    user_id,name,account_code,account_type,group_name,parent_account_id,
    report_class,account_subtype,normal_balance,cash_flow_category,
    is_party_account,is_control_account,is_system_account,allow_manual_posting,
    opening_balance,opening_balance_type,is_active
  ) values (
    uid,btrim(p_name),v_code,p_account_type,replace(initcap(replace(p_report_class,'_',' ')),' And ',' & '),p_parent_account_id,
    p_report_class,coalesce(nullif(btrim(p_account_subtype),''),'general'),v_normal,p_cash_flow_category,
    false,false,false,coalesce(p_allow_manual_posting,true),0,v_normal,true
  ) returning id into v_id;

  perform write_audit_log('create','accounts',v_id::text,null,
    jsonb_build_object('account_code',v_code,'name',btrim(p_name),'report_class',p_report_class));
  return v_id;
end;
$$;

create or replace function update_structured_account(p_id uuid, p_name text, p_account_code text, p_account_type text, p_report_class text, p_account_subtype text, p_normal_balance text, p_parent_account_id uuid, p_cash_flow_category text, p_allow_manual_posting boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare uid uuid:=get_workspace_owner(); v_old accounts%rowtype;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  perform assert_role(array['owner']);
  if p_name is null or btrim(p_name)='' then raise exception 'Account name is required.'; end if;
  if p_account_code is null or btrim(p_account_code)='' then raise exception 'Account code is required.'; end if;
  select * into v_old from accounts where id=p_id and user_id=uid for update;
  if not found then raise exception 'Account not found.'; end if;
  if v_old.is_system_account then raise exception 'System accounts cannot be edited from the Chart of Accounts.'; end if;
  if p_parent_account_id is not null and not exists (
    select 1 from accounts where id = p_parent_account_id and user_id = uid
  ) then raise exception 'Parent account does not belong to this business.'; end if;
  if p_parent_account_id = p_id then
    raise exception 'An account cannot be its own parent.';
  end if;
  update accounts set
    name=btrim(p_name), account_code=btrim(p_account_code), account_type=p_account_type,
    report_class=p_report_class, group_name=replace(initcap(replace(p_report_class,'_',' ')),' And ',' & '),
    account_subtype=coalesce(nullif(btrim(p_account_subtype),''),'general'), normal_balance=p_normal_balance,
    parent_account_id=p_parent_account_id, cash_flow_category=p_cash_flow_category,
    allow_manual_posting=coalesce(p_allow_manual_posting,true)
  where id=p_id and user_id=uid;
  perform write_audit_log('update','accounts',p_id::text,to_jsonb(v_old),
    jsonb_build_object('account_code',p_account_code,'name',p_name,'report_class',p_report_class));
end;
$$;
