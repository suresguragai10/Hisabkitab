-- ============================================================
-- HisabKitab P0.1 — Safe manual voucher posting
-- Apply after phaseP0_posting.sql.
--
-- Improvements:
--   * validates voucher type and line shape
--   * verifies every account belongs to the signed-in owner
--   * rejects negative, zero-sided and double-sided lines
--   * creates header + lines in one database transaction
--   * serializes voucher numbering per user/type/fiscal year
-- ============================================================

create or replace function post_voucher(
  p_type text,
  p_fiscal_year text,
  p_date date,
  p_narration text,
  p_lines jsonb
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  v_id uuid;
  v_num integer;
  tot_debit numeric(14,2);
  tot_credit numeric(14,2);
  invalid_line_count integer;
  foreign_account_count integer;
begin
  if uid is null then
    raise exception 'Not authenticated';
  end if;

  if p_type not in ('journal','payment','receipt','contra','sales','purchase') then
    raise exception 'Unsupported voucher type: %', p_type;
  end if;

  if p_fiscal_year is null or btrim(p_fiscal_year) = '' then
    raise exception 'Fiscal year is required';
  end if;

  if p_date is null then
    raise exception 'Voucher date is required';
  end if;

  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) < 2 then
    raise exception 'A voucher requires at least two lines';
  end if;

  select count(*)
    into invalid_line_count
    from jsonb_array_elements(p_lines) line
   where nullif(line->>'account_id', '') is null
      or coalesce((line->>'debit')::numeric, 0) < 0
      or coalesce((line->>'credit')::numeric, 0) < 0
      or (
        coalesce((line->>'debit')::numeric, 0) = 0
        and coalesce((line->>'credit')::numeric, 0) = 0
      )
      or (
        coalesce((line->>'debit')::numeric, 0) > 0
        and coalesce((line->>'credit')::numeric, 0) > 0
      );

  if invalid_line_count > 0 then
    raise exception 'Each voucher line must contain one account and either a positive debit or a positive credit';
  end if;

  select count(*)
    into foreign_account_count
    from jsonb_array_elements(p_lines) line
    left join accounts account
      on account.id = (line->>'account_id')::uuid
     and account.user_id = uid
     and account.is_active = true
   where account.id is null;

  if foreign_account_count > 0 then
    raise exception 'One or more voucher accounts are invalid, inactive, or do not belong to this business';
  end if;

  select
    coalesce(sum((line->>'debit')::numeric), 0),
    coalesce(sum((line->>'credit')::numeric), 0)
    into tot_debit, tot_credit
    from jsonb_array_elements(p_lines) line;

  if abs(tot_debit - tot_credit) > 0.005 then
    raise exception 'Voucher not balanced: debit % vs credit %', tot_debit, tot_credit;
  end if;

  if tot_debit <= 0 then
    raise exception 'Voucher amount must be greater than zero';
  end if;

  -- Prevent two concurrent posts from receiving the same voucher number.
  perform pg_advisory_xact_lock(
    hashtextextended(uid::text || ':' || p_type || ':' || p_fiscal_year, 0)
  );

  select coalesce(max(voucher_number), 0) + 1
    into v_num
    from vouchers
   where user_id = uid
     and voucher_type = p_type
     and fiscal_year = p_fiscal_year;

  insert into vouchers (
    user_id,
    voucher_type,
    voucher_number,
    fiscal_year,
    voucher_date,
    narration
  ) values (
    uid,
    p_type,
    v_num,
    p_fiscal_year,
    p_date,
    nullif(btrim(p_narration), '')
  )
  returning id into v_id;

  insert into voucher_lines (
    voucher_id,
    account_id,
    debit,
    credit,
    description
  )
  select
    v_id,
    (line->>'account_id')::uuid,
    coalesce((line->>'debit')::numeric, 0),
    coalesce((line->>'credit')::numeric, 0),
    nullif(btrim(line->>'description'), '')
  from jsonb_array_elements(p_lines) line;

  return v_id;
end;
$$;

grant execute on function post_voucher(text, text, date, text, jsonb) to authenticated;

-- Void only manual voucher types. Sales and purchase vouchers must be
-- corrected from their source document so the ledger cannot drift away
-- from invoices and bills.
create or replace function void_manual_voucher(
  p_voucher_id uuid,
  p_reason text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  affected_rows integer;
begin
  if uid is null then
    raise exception 'Not authenticated';
  end if;

  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'A void reason is required';
  end if;

  update vouchers
     set is_void = true,
         void_reason = left(btrim(p_reason), 500),
         voided_at = now(),
         updated_at = now()
   where id = p_voucher_id
     and user_id = uid
     and is_void = false
     and voucher_type in ('journal', 'payment', 'receipt', 'contra');

  get diagnostics affected_rows = row_count;
  if affected_rows = 0 then
    raise exception 'Voucher cannot be voided. It may not exist, may already be voided, or must be corrected from its source document.';
  end if;
end;
$$;

grant execute on function void_manual_voucher(uuid, text) to authenticated;
