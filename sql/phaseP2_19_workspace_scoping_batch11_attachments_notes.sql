-- ============================================================
-- HisabKitab P2.19 -- Workspace-scoping fix, batch 11 (final):
-- document attachments and internal notes.
--
-- Part of the larger workspace-scoping remediation (see memory:
-- workspace_scoping_gap.md). add_document_internal_note and
-- delete_document_attachment get the standard mechanical fix.
--
-- register_document_attachment is split deliberately:
--   - the storage PATH check stays against auth.uid() (the real
--     uploader), because Supabase Storage's own bucket policy
--     ((storage.foldername(name))[1] = auth.uid()::text, set up in
--     phaseP0_4_document_lifecycle.sql) is hardcoded to the real
--     actor's identity, not workspace-aware. Changing this function's
--     check alone without also changing the storage policy would
--     just move the mismatch, not fix it.
--   - the document_attachments row itself is scoped by
--     get_workspace_owner(), consistent with assert_owned_document
--     (already fixed) and every other document-scoped table.
--
-- NOTE (not fixed here, flagged for the same future dedicated pass):
-- the RLS SELECT policy on document_attachments itself
-- ("own document attachments" ... using (auth.uid() = user_id))
-- also gates by auth.uid() directly. Even with this function fixed,
-- an accountant still could not see attachments the owner scoped
-- this way to a business, because the row-level security policy
-- blocks it before the row is ever returned. RLS policies are a
-- separate mechanism from function bodies and need their own review
-- across all tables, not just this one -- out of scope for tonight.
-- ============================================================

create or replace function add_document_internal_note(p_document_type text, p_document_id uuid, p_note_text text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := get_workspace_owner();
  v_id uuid;
begin
  if nullif(trim(coalesce(p_note_text,'')), '') is null then
    raise exception 'Internal note cannot be blank.';
  end if;
  perform assert_owned_document(p_document_type, p_document_id);
  insert into document_internal_notes(user_id, document_type, document_id, note_text)
  values(uid, p_document_type, p_document_id, left(trim(p_note_text), 4000))
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function delete_document_attachment(p_attachment_id uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := get_workspace_owner();
  v_path text;
begin
  delete from document_attachments
   where id = p_attachment_id and user_id = uid
   returning storage_path into v_path;
  if v_path is null then raise exception 'Attachment not found.'; end if;
  return v_path;
end;
$$;

create or replace function register_document_attachment(p_document_type text, p_document_id uuid, p_storage_path text, p_file_name text, p_mime_type text default null::text, p_size_bytes bigint default null::bigint)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  owner uuid := get_workspace_owner();
  actor uuid := auth.uid();
  v_id uuid;
begin
  perform assert_owned_document(p_document_type, p_document_id);
  if p_storage_path is null or split_part(p_storage_path, '/', 1) <> actor::text then
    raise exception 'Attachment path must be inside the signed-in owner folder.';
  end if;
  if p_size_bytes is not null and (p_size_bytes < 0 or p_size_bytes > 20971520) then
    raise exception 'Attachment size must not exceed 20 MB.';
  end if;
  insert into document_attachments(
    user_id, document_type, document_id, storage_path,
    file_name, mime_type, size_bytes
  ) values (
    owner, p_document_type, p_document_id, p_storage_path,
    left(coalesce(nullif(trim(p_file_name),''),'attachment'), 255),
    nullif(trim(p_mime_type),''), p_size_bytes
  ) returning id into v_id;
  return v_id;
end;
$$;
