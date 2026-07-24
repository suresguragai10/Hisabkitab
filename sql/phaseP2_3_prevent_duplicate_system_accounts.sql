-- ============================================================
-- HisabKitab P2.3 — Make duplicate system accounts impossible,
-- not just something we clean up after the fact.
--
-- resolve_system_account() is supposed to check for an existing
-- account before creating one, but nothing at the database level
-- enforced that -- which is presumably how the 9 duplicates cleaned
-- up in P2.2 came to exist in the first place. A partial unique
-- index (only applies when system_code is set, so regular
-- user-created accounts are untouched) makes a second account with
-- the same system_code for the same business a hard database error
-- from now on, regardless of what application code does.
-- ============================================================

create unique index if not exists uq_accounts_user_system_code
  on accounts (user_id, system_code)
  where system_code is not null;
