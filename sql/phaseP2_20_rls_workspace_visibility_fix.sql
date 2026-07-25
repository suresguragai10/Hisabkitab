-- ============================================================
-- HisabKitab P2.20 -- RLS policy fix: restore team-member visibility.
--
-- Separate mechanism from the P2.6-P2.19 function fixes (see memory:
-- workspace_scoping_gap.md). Even with every SECURITY DEFINER
-- function now correctly scoping data by get_workspace_owner(), a
-- table's own RLS policy can independently block a row from ever
-- being returned to a direct .from(table).select() call from the
-- frontend -- which is exactly what several tables were doing here,
-- gated only by "auth.uid() = user_id" with no workspace-aware
-- alternative.
--
-- Fix: use the existing, already-proven can_access_workspace(uuid)
-- helper (already relied on by accounts, business_profile, invoices,
-- parties, vouchers, etc.) -- it checks "is this the owner, OR an
-- active member of the owner's workspace." This restores read
-- visibility only; it does not change who is allowed to write --
-- writes already go through the SECURITY DEFINER functions fixed
-- earlier, which enforce their own rules (some already role-gated,
-- e.g. "write parties" requiring accountant/staff role -- untouched
-- here).
--
-- Excluded: dead "Layer 3" org-based policies (organizations,
-- journal_entries, accounting_periods, etc.) and workspace_members /
-- user_workspace_pref, which are correctly identity-scoped as-is
-- (membership records and per-person preferences should never be
-- workspace-scoped).
-- ============================================================

alter policy "own credit notes" on credit_notes
  using (can_access_workspace(user_id));

alter policy "own credit note lines" on credit_note_lines
  using (exists (
    select 1 from credit_notes n
     where n.id = credit_note_lines.credit_note_id
       and can_access_workspace(n.user_id)
  ));

alter policy "own debit notes" on debit_notes
  using (can_access_workspace(user_id));

alter policy "own debit note lines" on debit_note_lines
  using (exists (
    select 1 from debit_notes n
     where n.id = debit_note_lines.debit_note_id
       and can_access_workspace(n.user_id)
  ));

alter policy "own document attachments" on document_attachments
  using (can_access_workspace(user_id));

alter policy "own document internal notes" on document_internal_notes
  using (can_access_workspace(user_id));

alter policy "own document payments" on document_payments
  using (can_access_workspace(user_id));

alter policy "own fiscal year closures" on fiscal_year_closures
  using (can_access_workspace(user_id));

alter policy "own opening journals" on opening_journals
  using (can_access_workspace(user_id));

alter policy "own payment allocations" on payment_allocations
  using (can_access_workspace(user_id));

alter policy "own compliance settings" on tax_compliance_settings
  using (can_access_workspace(user_id));

alter policy "own vat returns" on vat_returns
  using (can_access_workspace(user_id));

alter policy "own sequences" on doc_sequences
  using (can_access_workspace(user_id))
  with check (user_id = get_workspace_owner());

alter policy "cat_all" on item_categories
  using (can_access_workspace(user_id))
  with check (user_id = auth.uid() or user_id = get_workspace_owner());

alter policy "own inventory items" on inventory_items
  using (can_access_workspace(user_id))
  with check (user_id = auth.uid() or user_id = get_workspace_owner());

alter policy "read own items" on inventory_items
  using (can_access_workspace(user_id));

alter policy "own inventory movements" on inventory_movements
  using (can_access_workspace(user_id))
  with check (user_id = auth.uid() or user_id = get_workspace_owner());

alter policy "read own movements" on inventory_movements
  using (can_access_workspace(user_id));
