-- ============================================================
-- HisabKitab P2.18 -- Workspace-scoping fix, batch 10: Business
-- profile and settings.
--
-- Part of the larger workspace-scoping remediation (see memory:
-- workspace_scoping_gap.md). Fetched live and fixed with the minimal,
-- mechanical change: the uid variable's source only (auth.uid() ->
-- get_workspace_owner()). No other logic touched.
--
-- Consistency note: business_profile.user_id and tax_compliance_settings
-- .user_id / tax_rates.user_id are already keyed by the OWNER's id
-- elsewhere in the live system (list_my_workspaces, accept_invite,
-- and the already-fixed create_tds_entry / get_tax_rates(date) all
-- read these tables via get_workspace_owner()). Leaving these 5
-- functions on auth.uid() would mean an accountant's settings changes
-- silently land in a phantom row under their own id that nothing else
-- ever reads.
-- ============================================================

create or replace function get_or_create_business_profile()
returns setof business_profile
language plpgsql
security definer
set search_path = public
as $$
declare uid uuid := get_workspace_owner();
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  insert into business_profile (user_id)
  values (uid)
  on conflict (user_id) do nothing;
  return query select * from business_profile where user_id = uid;
end; $$;

create or replace function save_business_profile(p_biz_name text default ''::text, p_biz_name_np text default ''::text, p_address text default ''::text, p_city text default ''::text, p_pan_vat text default ''::text, p_phone text default ''::text, p_email text default ''::text, p_invoice_prefix text default ''::text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare uid uuid := get_workspace_owner();
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  insert into business_profile
    (user_id, biz_name, biz_name_np, address, city, pan_vat, phone, email, invoice_prefix)
  values
    (uid, p_biz_name, p_biz_name_np, p_address, p_city, p_pan_vat, p_phone, p_email, p_invoice_prefix)
  on conflict (user_id) do update set
    biz_name        = excluded.biz_name,
    biz_name_np     = excluded.biz_name_np,
    address         = excluded.address,
    city            = excluded.city,
    pan_vat         = excluded.pan_vat,
    phone           = excluded.phone,
    email           = excluded.email,
    invoice_prefix  = excluded.invoice_prefix,
    updated_at      = now();
end; $$;

create or replace function get_compliance_settings()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare uid uuid:=get_workspace_owner(); s tax_compliance_settings%rowtype;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  insert into tax_compliance_settings(user_id) values(uid) on conflict(user_id) do nothing;
  select * into s from tax_compliance_settings where user_id=uid;
  return to_jsonb(s);
end; $$;

create or replace function save_compliance_settings(p_vat_due_day integer, p_tds_due_day integer, p_require_pan_for_tds boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare uid uuid:=get_workspace_owner();
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  if p_vat_due_day not between 1 and 31 or p_tds_due_day not between 1 and 31 then raise exception 'Due days must be 1 to 31.'; end if;
  insert into tax_compliance_settings(user_id,vat_due_day,tds_due_day,require_pan_for_tds,updated_at)
  values(uid,p_vat_due_day,p_tds_due_day,coalesce(p_require_pan_for_tds,false),now())
  on conflict(user_id) do update set vat_due_day=excluded.vat_due_day,tds_due_day=excluded.tds_due_day,
    require_pan_for_tds=excluded.require_pan_for_tds,updated_at=now();
  perform write_audit_log('configure','tax_compliance_settings',uid::text,null,jsonb_build_object('vat_due_day',p_vat_due_day,'tds_due_day',p_tds_due_day));
end; $$;

create or replace function save_tax_rate(p_rate_type text, p_transaction_type text, p_label text, p_rate numeric, p_effective_from date, p_effective_to date default null::date, p_vat_treatment text default null::text, p_legal_reference text default null::text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare uid uuid:=get_workspace_owner(); v_id uuid;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  if p_rate_type not in ('vat','tds') then raise exception 'Invalid tax rate type.'; end if;
  if nullif(btrim(p_transaction_type),'') is null or nullif(btrim(p_label),'') is null then
    raise exception 'Transaction type and label are required.';
  end if;
  if p_rate<0 or p_rate>100 then raise exception 'Rate must be between 0 and 100.'; end if;
  if p_rate_type='vat' and p_vat_treatment not in ('standard','zero_rated','exempt','out_of_scope') then
    raise exception 'VAT treatment is required for VAT rates.';
  end if;
  if p_rate_type='vat' and p_vat_treatment<>'standard' and abs(p_rate)>0.0001 then
    raise exception 'Zero-rated, exempt and out-of-scope rates must be zero.';
  end if;
  insert into tax_rates(user_id,rate_type,transaction_type,label,rate,vat_treatment,effective_from,effective_to,legal_reference)
  values(uid,p_rate_type,btrim(p_transaction_type),btrim(p_label),round(p_rate,4),p_vat_treatment,p_effective_from,p_effective_to,nullif(btrim(p_legal_reference),''))
  returning id into v_id;
  perform write_audit_log('configure','tax_rates',v_id::text,null,jsonb_build_object('type',p_rate_type,'transaction_type',p_transaction_type,'rate',p_rate));
  return v_id;
end;
$$;
