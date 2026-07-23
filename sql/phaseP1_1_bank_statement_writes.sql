-- ============================================================
-- HisabKitab P1.1 — Close the direct-write gap on bank_statements
-- and bank_statement_lines.
--
-- BankReconciliation.jsx wrote to both tables directly in three
-- places (creating a statement, adding one transaction line, and
-- bulk CSV import), with no functions to fall back on. This adds
-- three, then closes direct table access.
--
-- All three use get_workspace_owner() (already validated safe by
-- switch_workspace()) rather than trusting a client-supplied user
-- id -- this also fixes a latent bug in the old direct-insert code,
-- which stored the CALLER's own auth id instead of the workspace
-- owner's, so a team member acting on a workspace they'd joined
-- (not their own) would have hit an RLS rejection. account_name is
-- now looked up server-side from the real account row instead of
-- trusting whatever string the client sent.
-- ============================================================

create or replace function create_bank_statement(
  p_account_id uuid,
  p_from_date date,
  p_to_date date,
  p_opening_balance numeric default 0,
  p_closing_balance numeric default 0,
  p_notes text default null
)
returns bank_statements
language plpgsql
security definer
set search_path = public
as $$
declare
  owner uuid := get_workspace_owner();
  acct record;
  v_row bank_statements%rowtype;
begin
  if owner is null then raise exception 'Not authenticated'; end if;
  if p_from_date is null or p_to_date is null then raise exception 'From/to date are required.'; end if;
  if p_to_date < p_from_date then raise exception 'To date must be on or after from date.'; end if;

  select id, name into acct from accounts
   where id = p_account_id and user_id = owner and is_active = true;
  if not found then raise exception 'Bank/cash account not found.'; end if;

  insert into bank_statements
    (user_id, account_id, account_name, from_date, to_date, opening_balance, closing_balance, notes)
  values
    (owner, p_account_id, acct.name, p_from_date, p_to_date,
     coalesce(p_opening_balance,0), coalesce(p_closing_balance,0), nullif(btrim(p_notes),''))
  returning * into v_row;

  return v_row;
end;
$$;

revoke all on function create_bank_statement(uuid, date, date, numeric, numeric, text) from public;
grant execute on function create_bank_statement(uuid, date, date, numeric, numeric, text) to authenticated;

create or replace function add_bank_statement_line(
  p_statement_id uuid,
  p_txn_date date,
  p_description text,
  p_reference text default null,
  p_deposits numeric default 0,
  p_withdrawals numeric default 0,
  p_balance numeric default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  owner uuid := get_workspace_owner();
  v_id uuid;
begin
  if owner is null then raise exception 'Not authenticated'; end if;
  if p_txn_date is null then raise exception 'Transaction date is required.'; end if;
  if nullif(btrim(p_description),'') is null then raise exception 'Description is required.'; end if;
  if coalesce(p_deposits,0) = 0 and coalesce(p_withdrawals,0) = 0 then
    raise exception 'Enter a deposit or withdrawal amount.';
  end if;

  if not exists (select 1 from bank_statements where id = p_statement_id and user_id = owner) then
    raise exception 'Bank statement not found.';
  end if;

  insert into bank_statement_lines
    (statement_id, user_id, txn_date, description, reference, deposits, withdrawals, balance)
  values
    (p_statement_id, owner, p_txn_date, btrim(p_description), nullif(btrim(p_reference),''),
     coalesce(p_deposits,0), coalesce(p_withdrawals,0), p_balance)
  returning id into v_id;

  return v_id;
end;
$$;

revoke all on function add_bank_statement_line(uuid, date, text, text, numeric, numeric, numeric) from public;
grant execute on function add_bank_statement_line(uuid, date, text, text, numeric, numeric, numeric) to authenticated;

create or replace function import_bank_statement_lines(
  p_statement_id uuid,
  p_lines jsonb
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  owner uuid := get_workspace_owner();
  v_count integer;
begin
  if owner is null then raise exception 'Not authenticated'; end if;
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'At least one transaction is required.';
  end if;

  if not exists (select 1 from bank_statements where id = p_statement_id and user_id = owner) then
    raise exception 'Bank statement not found.';
  end if;

  insert into bank_statement_lines
    (statement_id, user_id, txn_date, description, reference, deposits, withdrawals, balance)
  select p_statement_id, owner,
         (elem->>'txn_date')::date,
         coalesce(elem->>'description',''),
         nullif(elem->>'reference',''),
         coalesce((elem->>'deposits')::numeric, 0),
         coalesce((elem->>'withdrawals')::numeric, 0),
         nullif(elem->>'balance','')::numeric
    from jsonb_array_elements(p_lines) elem
   where (elem->>'txn_date') is not null;

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

revoke all on function import_bank_statement_lines(uuid, jsonb) from public;
grant execute on function import_bank_statement_lines(uuid, jsonb) to authenticated;

grant select on bank_statements, bank_statement_lines to authenticated;
revoke insert, update, delete on bank_statements, bank_statement_lines from authenticated;
