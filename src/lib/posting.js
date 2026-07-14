// ============================================================
// Phase P0 — document → ledger posting (client side)
// Thin wrappers over the atomic Postgres functions. Each of these
// creates the document AND its balanced voucher in one transaction,
// so the ledger can never drift from the documents.
// ============================================================
import { supabase } from "../supabase";

// Create an invoice and its sales voucher atomically. Returns the new invoice id.
export async function createInvoiceWithPosting(header, lines) {
  const { data, error } = await supabase.rpc("create_invoice_with_posting", {
    p_header: header,
    p_lines: lines,
  });
  if (error) throw error;
  return data; // invoice id
}

// Create a purchase bill and its purchase voucher atomically. Returns the new bill id.
export async function createBillWithPosting(header, lines) {
  const { data, error } = await supabase.rpc("create_bill_with_posting", {
    p_header: header,
    p_lines: lines,
  });
  if (error) throw error;
  return data; // bill id
}

// Refresh cached paid/outstanding amounts and due-date statuses.
export async function refreshDocumentPaymentStatuses() {
  const { data, error } = await supabase.rpc("refresh_document_payment_statuses");
  if (error) throw error;
  return data;
}

// Record a payment/receipt and allocate it to one document atomically.
//   docType: 'invoice' | 'bill'
//   depositCode: 'cash' | 'bank'
export async function recordDocumentPayment(
  docType, docId, amount, depositCode, date, reference = null, notes = null
) {
  const { data, error } = await supabase.rpc("record_document_payment", {
    p_doc_type: docType,
    p_doc_id: docId,
    p_amount: amount,
    p_deposit_code: depositCode,
    p_date: date,
    p_reference: reference,
    p_notes: notes,
  });
  if (error) throw error;
  return data;
}

// Backward-compatible name retained for existing callers.
export async function settleDocument(docType, docId, amount, depositCode, date) {
  return recordDocumentPayment(docType, docId, amount, depositCode, date);
}

export async function getPaymentHistory(docType, docId) {
  const { data, error } = await supabase.rpc("get_payment_history", {
    p_doc_type: docType,
    p_doc_id: docId,
  });
  if (error) throw error;
  return data || [];
}

export async function reversePaymentAllocation(allocationId, reason, date) {
  const { data, error } = await supabase.rpc("reverse_payment_allocation", {
    p_allocation_id: allocationId,
    p_reason: reason,
    p_date: date,
  });
  if (error) throw error;
  return data;
}

// One-time: post vouchers for documents created before the P0 fix.
export async function backfillPostExisting() {
  const { data, error } = await supabase.rpc("backfill_post_existing");
  if (error) throw error;
  return data; // human-readable summary
}

// Trial balance — the integrity check. Debits should equal credits.
export async function listTrialBalance() {
  const { data, error } = await supabase
    .from("trial_balance")
    .select("*")
    .order("account_type")
    .order("name");
  if (error) throw error;
  return data;
}
