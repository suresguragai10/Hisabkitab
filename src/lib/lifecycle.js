import { supabase } from "../supabase";

async function callRpc(name, args) {
  const { data, error } = await supabase.rpc(name, args);
  if (error) throw error;
  return data;
}

export function saveInvoiceDraft(header, lines, invoiceId = null) {
  return callRpc("save_invoice_draft", {
    p_header: header,
    p_lines: lines,
    p_invoice_id: invoiceId,
  });
}

export function saveBillDraft(header, lines, billId = null) {
  return callRpc("save_bill_draft", {
    p_header: header,
    p_lines: lines,
    p_bill_id: billId,
  });
}

export function postInvoiceDraft(invoiceId) {
  return callRpc("post_invoice_draft", { p_invoice_id: invoiceId });
}

export function postBillDraft(billId) {
  return callRpc("post_bill_draft", { p_bill_id: billId });
}

export function deleteDocumentDraft(documentType, documentId) {
  return callRpc("delete_document_draft", {
    p_document_type: documentType,
    p_document_id: documentId,
  });
}

export function cancelInvoiceDocument(invoiceId, reason, date) {
  return callRpc("cancel_invoice_document", {
    p_invoice_id: invoiceId,
    p_reason: reason,
    p_date: date,
  });
}

export function cancelBillDocument(billId, reason, date) {
  return callRpc("cancel_bill_document", {
    p_bill_id: billId,
    p_reason: reason,
    p_date: date,
  });
}

export function cancelCreditNote(noteId, reason, date) {
  return callRpc("cancel_credit_note", {
    p_credit_note_id: noteId,
    p_reason: reason,
    p_date: date,
  });
}

export function cancelDebitNote(noteId, reason, date) {
  return callRpc("cancel_debit_note", {
    p_debit_note_id: noteId,
    p_reason: reason,
    p_date: date,
  });
}

export function markInvoicePrinted(invoiceId) {
  return callRpc("mark_invoice_printed", { p_invoice_id: invoiceId });
}

export function addInternalNote(documentType, documentId, noteText) {
  return callRpc("add_document_internal_note", {
    p_document_type: documentType,
    p_document_id: documentId,
    p_note_text: noteText,
  });
}

export function registerAttachment(documentType, documentId, storagePath, file) {
  return callRpc("register_document_attachment", {
    p_document_type: documentType,
    p_document_id: documentId,
    p_storage_path: storagePath,
    p_file_name: file.name,
    p_mime_type: file.type || null,
    p_size_bytes: file.size || null,
  });
}

export function deleteAttachment(attachmentId) {
  return callRpc("delete_document_attachment", { p_attachment_id: attachmentId });
}

export async function listDocumentActivity(documentType, documentId) {
  const [notesResult, attachmentsResult] = await Promise.all([
    supabase
      .from("document_internal_notes")
      .select("*")
      .eq("document_type", documentType)
      .eq("document_id", documentId)
      .order("created_at", { ascending: false }),
    supabase
      .from("document_attachments")
      .select("*")
      .eq("document_type", documentType)
      .eq("document_id", documentId)
      .order("created_at", { ascending: false }),
  ]);
  if (notesResult.error) throw notesResult.error;
  if (attachmentsResult.error) throw attachmentsResult.error;
  return {
    notes: notesResult.data || [],
    attachments: attachmentsResult.data || [],
  };
}
