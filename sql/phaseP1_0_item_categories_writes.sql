-- ============================================================
-- HisabKitab P1.0 — Close the direct-write gap on item_categories.
--
-- Unlike business_profile/user_workspace_pref, this one genuinely
-- needed a new function first: src/lib/items.js's updateCategory()
-- was writing to item_categories directly, with no existing
-- function to fall back on. create_item_category() already existed
-- (covers insert); this adds update_item_category() to match, using
-- the same "null means leave unchanged" convention already used by
-- update_item() elsewhere in this codebase.
--
-- No delete function is added: nothing in the app deletes a
-- category (deactivating one is done via is_active = false through
-- the update path), so delete is simply closed with no replacement.
-- ============================================================

create or replace function update_item_category(
  p_id uuid,
  p_name text default null,
  p_name_np text default null,
  p_parent_id uuid default null,
  p_sort_order integer default null,
  p_notes text default null,
  p_is_active boolean default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
begin
  if uid is null then raise exception 'Not authenticated'; end if;

  if not exists (select 1 from item_categories where id = p_id and user_id = uid) then
    raise exception 'Item category not found.';
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

revoke all on function update_item_category(uuid, text, text, uuid, integer, text, boolean) from public;
grant execute on function update_item_category(uuid, text, text, uuid, integer, text, boolean) to authenticated;

grant select on item_categories to authenticated;
revoke insert, update, delete on item_categories from authenticated;
