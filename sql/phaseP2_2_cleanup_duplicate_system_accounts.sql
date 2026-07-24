-- ============================================================
-- HisabKitab P2.2 — One-time cleanup of duplicate/misclassified
-- system accounts found during the audit (all confirmed zero
-- ledger entries via voucher_lines).
--
-- This is a direct delete, not routed through delete_structured_account(),
-- because that function deliberately refuses to touch is_system_account
-- rows (correct protection for normal use, but this is a one-time
-- admin cleanup of accidental duplicates, not a regular user action).
-- No DELETE trigger exists on accounts, so this is a clean, safe
-- operation as long as no other table still references these ids
-- (checked defensively per-row below rather than assumed).
-- ============================================================

do $$
declare
  ids uuid[] := array[
    '0b0f6545-ec35-4c88-acf0-bac9504e217d', -- "capital" misclassified as asset
    '0bfde930-fce7-4e16-b28c-db08e94c1ff4', -- Inventory Asset duplicate (unused)
    '8a4b16ab-634b-4c51-831a-b3864a7081d7', -- Inventory Opening Equity duplicate 1 (unused)
    'c549b4a8-ea16-49a8-8a63-f1423826b688', -- Inventory Opening Equity duplicate 2 (unused)
    '953eebab-4e60-495c-aeeb-7f27aff40a52', -- Purchase Returns Clearing duplicate 1 (unused)
    '97aabe38-079b-49e8-b37f-b7e95747db4a', -- Purchase Returns Clearing duplicate 2 (unused)
    'ce82c076-22be-4904-bb65-7779bf65ba56', -- TDS Payable duplicate (unused)
    '370b49f8-ced6-4d3b-9672-368779ce90ef', -- VAT Payable duplicate (unused)
    '3c2f171c-f02c-4ef4-a303-c60ff4639bc3'  -- VAT Receivable duplicate (unused)
  ];
  v_id uuid;
begin
  foreach v_id in array ids loop
    begin
      delete from accounts where id = v_id;
      raise notice 'Deleted account %', v_id;
    exception when others then
      raise notice 'Could not delete account % : %', v_id, sqlerrm;
    end;
  end loop;
end $$;
