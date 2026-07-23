-- ============================================================
-- HisabKitab P0.8 — Two fixes confirmed via a live read-only audit
-- of the actual Supabase project (not just the files in this repo).
--
-- FIX 1 — close the direct-write gap on vouchers/voucher_lines.
-- Confirmed live: `authenticated` could INSERT a voucher directly
-- (bypassing post_voucher's debit=credit balance check and its
-- sequential numbering), and could INSERT/UPDATE/DELETE
-- voucher_lines directly (bypassing that same balance check).
-- Every legitimate path already goes through post_voucher,
-- void_manual_voucher, create_invoice_with_posting,
-- create_bill_with_posting, create_credit_note, create_debit_note,
-- record_inventory_adjustment, etc. — all SECURITY DEFINER, so all
-- are unaffected by this revoke. This mirrors the exact protection
-- already applied elsewhere (document_payments, payment_allocations,
-- inventory_items, inventory_movements, invoices, purchase_bills).
--
-- FIX 2 — the set_period_lock overload ambiguity.
-- Two versions of set_period_lock already exist live: an old
-- 2-argument version with no safety checks, and a newer 3-argument
-- version that refuses to unlock a period whose fiscal year is
-- closed, or that has an already-filed VAT return. Postgres prefers
-- an exact-arity match, so any caller that omits the reason
-- argument silently resolves to the OLD, unprotected version —
-- which is exactly what Settings.jsx has been doing on every
-- lock/unlock click. Dropping the old overload removes the
-- ambiguity permanently. Settings.jsx is updated separately (in the
-- same commit) to always call the 3-argument version.
-- ============================================================

-- ------------------------------------------------------------
-- FIX 1
-- ------------------------------------------------------------
grant select on vouchers, voucher_lines to authenticated;
revoke insert, update, delete on vouchers, voucher_lines from authenticated;

-- ------------------------------------------------------------
-- FIX 2
-- ------------------------------------------------------------
drop function if exists set_period_lock(uuid, boolean);
