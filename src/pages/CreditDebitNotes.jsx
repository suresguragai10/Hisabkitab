import React, { useEffect, useMemo, useState } from "react";
import { supabase } from "../supabase";
import { cancelCreditNote, cancelDebitNote } from "../lib/lifecycle";
import LifecycleActionModal from "../components/LifecycleActionModal";
import DocumentActivityModal from "../components/DocumentActivityModal";

const fmt = (value) => Number(value || 0).toLocaleString(undefined, {
  minimumFractionDigits: 2,
  maximumFractionDigits: 2,
});

function NotePrint({ note, noteType, onClose }) {
  const credit = noteType === "cn";
  const number = credit ? note.cn_number : note.dn_number;
  const date = credit ? note.cn_date : note.dn_date;
  const party = credit ? note.party_name : note.vendor_name;
  const lines = credit ? note.credit_note_lines || [] : note.debit_note_lines || [];
  return (
    <div className="print-overlay">
      <div className="print-actions no-print" style={{ display: "flex", gap: 12, marginBottom: 20 }}>
        <button className="btn" onClick={() => window.print()}>🖨 Print</button>
        <button className="link" onClick={onClose}>← Back</button>
      </div>
      <div className="invoice-paper">
        <div className="inv-header">
          <div style={{ flex: 1 }}>
            <div className="inv-title">{credit ? "CREDIT NOTE" : "DEBIT NOTE"}</div>
            <div className="inv-title-sub">{credit ? "क्रेडिट नोट (बिक्री फिर्ता)" : "डेबिट नोट (खरिद फिर्ता)"}</div>
          </div>
          <div style={{ textAlign: "right", fontSize: 12, color: "#555" }}>
            <div><b>No:</b> {credit ? "CN" : "DN"}-{String(number).padStart(4, "0")}</div>
            <div><b>Date:</b> {date}</div>
            <div><b>FY:</b> {note.fiscal_year}</div>
          </div>
        </div>
        <div className="inv-meta">
          <div className="inv-meta-left">
            <div style={{ fontWeight: 600 }}>{credit ? "Customer" : "Vendor"}:</div>
            <div style={{ fontSize: 15, fontWeight: 700 }}>{party}</div>
            {(credit ? note.party_address : note.vendor_address) && <div style={{ fontSize: 12 }}>{credit ? note.party_address : note.vendor_address}</div>}
            {(credit ? note.party_pan : note.vendor_pan) && <div style={{ fontSize: 12 }}>PAN: {credit ? note.party_pan : note.vendor_pan}</div>}
          </div>
          <div className="inv-meta-right">
            <div style={{ fontSize: 12 }}>{credit ? `Against Invoice #${note.invoice_number}` : `Against Bill #${note.bill_number}`}</div>
            <div style={{ fontSize: 12 }}><b>Reason:</b> {note.reason}</div>
          </div>
        </div>
        <table className="inv-table" style={{ marginTop: 16 }}>
          <thead><tr><th>#</th><th>Description</th><th>Qty</th><th>Unit</th><th className="r">Rate</th><th className="r">Amount</th><th className="r">VAT</th><th className="r">Total</th></tr></thead>
          <tbody>
            {lines.map((line, index) => (
              <tr key={line.id || index}>
                <td>{index + 1}</td><td>{line.description}</td><td>{line.quantity}</td><td>{line.unit}</td>
                <td className="r">{fmt(line.rate)}</td><td className="r">{fmt(line.amount)}</td>
                <td className="r">{fmt(line.vat_amount)}</td><td className="r">{fmt(line.line_total)}</td>
              </tr>
            ))}
          </tbody>
        </table>
        <div className="inv-summary">
          <div className="inv-summary-row"><span>Subtotal</span><span>NPR {fmt(note.subtotal)}</span></div>
          <div className="inv-summary-row"><span>VAT reversed</span><span>NPR {fmt(note.vat_amount)}</span></div>
          <div className="inv-summary-row inv-grand"><span>TOTAL</span><span>NPR {fmt(note.total)}</span></div>
        </div>
        {note.notes && <div className="inv-notes"><b>Notes:</b> {note.notes}</div>}
      </div>
    </div>
  );
}

function ReturnForm({ noteType, invoices, bills, onSave, onClose, busy, error }) {
  const credit = noteType === "cn";
  const documents = credit ? invoices : bills;
  const [documentId, setDocumentId] = useState("");
  const [date, setDate] = useState(new Date().toISOString().slice(0, 10));
  const [reason, setReason] = useState("");
  const [notes, setNotes] = useState("");
  const [lines, setLines] = useState([]);

  const selectedDocument = documents.find((document) => document.id === documentId);

  const chooseDocument = (id) => {
    setDocumentId(id);
    const document = documents.find((entry) => entry.id === id);
    const sourceLines = credit ? document?.invoice_lines || [] : document?.purchase_bill_lines || [];
    setLines(sourceLines.map((line) => ({
      sourceLineId: line.id,
      itemId: line.item_id || null,
      description: line.description,
      quantity: String(line.quantity),
      maxQuantity: Number(line.quantity),
      unit: line.unit || "pcs",
      rate: Number(line.rate || 0),
      vatRate: Number(line.vat_rate || 0),
      enabled: true,
    })));
  };

  const activeLines = useMemo(() => lines.filter((line) => line.enabled && Number(line.quantity) > 0), [lines]);
  const subtotal = activeLines.reduce((sum, line) => sum + Number(line.quantity) * line.rate, 0);
  const vat = activeLines.reduce((sum, line) => sum + Number(line.quantity) * line.rate * line.vatRate / 100, 0);

  const updateLine = (index, patch) => setLines((current) => current.map((line, lineIndex) => lineIndex === index ? { ...line, ...patch } : line));

  const submit = (event) => {
    event.preventDefault();
    if (!selectedDocument || !reason.trim() || activeLines.length === 0) return;
    const header = credit ? {
      cn_date: date,
      invoice_id: selectedDocument.id,
      reason: reason.trim(),
      notes: notes.trim() || null,
    } : {
      dn_date: date,
      bill_id: selectedDocument.id,
      reason: reason.trim(),
      notes: notes.trim() || null,
    };
    const payload = activeLines.map((line) => ({
      source_line_id: line.sourceLineId,
      item_id: line.itemId,
      quantity: Number(line.quantity),
    }));
    onSave(header, payload);
  };

  return (
    <form className="inv-form" onSubmit={submit} style={{ marginBottom: 16 }}>
      <b style={{ display: "block", marginBottom: 10 }}>New {credit ? "Credit Note / Sales Return" : "Debit Note / Purchase Return"}</b>
      <div className="settings-info-box" style={{ marginBottom: 12 }}>
        Returns must reference an original posted document. Quantities, rates, VAT, inventory cost, and party accounts are verified by the database.
      </div>
      <div className="inv-form-top">
        <label className="fld">Date <input type="date" value={date} onChange={(event) => setDate(event.target.value)} required /></label>
        <label className="fld wide-field">Original {credit ? "Invoice" : "Bill"}
          <select value={documentId} onChange={(event) => chooseDocument(event.target.value)} required>
            <option value="">— select posted document —</option>
            {documents.map((document) => (
              <option key={document.id} value={document.id}>
                {credit ? `Invoice #${document.invoice_number} — ${document.party_name}` : `Bill #${document.bill_number} — ${document.vendor_name}`} — NPR {Number(document.outstanding_amount || document.net_total || document.total).toLocaleString()}
              </option>
            ))}
          </select>
        </label>
        <label className="fld wide-field">Reason
          <input value={reason} onChange={(event) => setReason(event.target.value)} placeholder="Damaged goods, overcharge, returned goods…" required />
        </label>
        <label className="fld wide-field">Printed notes
          <input value={notes} onChange={(event) => setNotes(event.target.value)} placeholder="Optional note printed on the return document" />
        </label>
      </div>

      {lines.length > 0 && (
        <div style={{ overflowX: "auto", marginTop: 12 }}>
          <table className="tbl">
            <thead><tr><th>Return</th><th>Description</th><th>Max Qty</th><th>Return Qty</th><th>Unit</th><th className="num">Rate</th><th className="num">VAT%</th><th className="num">Total</th></tr></thead>
            <tbody>
              {lines.map((line, index) => {
                const quantity = Number(line.quantity || 0);
                const total = quantity * line.rate * (1 + line.vatRate / 100);
                return (
                  <tr key={line.sourceLineId}>
                    <td><input type="checkbox" checked={line.enabled} onChange={(event) => updateLine(index, { enabled: event.target.checked })} /></td>
                    <td>{line.description}</td><td>{line.maxQuantity}</td>
                    <td><input type="number" step="0.001" min="0" max={line.maxQuantity} value={line.quantity} disabled={!line.enabled} onChange={(event) => updateLine(index, { quantity: event.target.value })} style={{ width: 85 }} /></td>
                    <td>{line.unit}</td><td className="num">{fmt(line.rate)}</td><td className="num">{line.vatRate}%</td><td className="num">{fmt(total)}</td>
                  </tr>
                );
              })}
            </tbody>
            <tfoot><tr><td colSpan={5} /><td className="num"><b>Subtotal {fmt(subtotal)}</b></td><td className="num"><b>VAT {fmt(vat)}</b></td><td className="num"><b>NPR {fmt(subtotal + vat)}</b></td></tr></tfoot>
          </table>
        </div>
      )}

      {error && <p className="msg err">{error}</p>}
      <div style={{ display: "flex", gap: 10, marginTop: 12 }}>
        <button className="btn" disabled={busy || !selectedDocument || !reason.trim() || activeLines.length === 0}>{busy ? "Posting…" : `Post ${credit ? "Credit" : "Debit"} Note`}</button>
        <button type="button" className="ghost-btn" onClick={onClose}>Close</button>
      </div>
    </form>
  );
}

export default function CreditDebitNotes() {
  const [noteType, setNoteType] = useState("cn");
  const [notes, setNotes] = useState([]);
  const [invoices, setInvoices] = useState([]);
  const [bills, setBills] = useState([]);
  const [loading, setLoading] = useState(true);
  const [showForm, setShowForm] = useState(false);
  const [printNote, setPrintNote] = useState(null);
  const [cancelNote, setCancelNote] = useState(null);
  const [activityNote, setActivityNote] = useState(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);

  const load = async () => {
    setLoading(true);
    setError(null);
    try {
      const credit = noteType === "cn";
      const [noteResult, invoiceResult, billResult] = await Promise.all([
        credit
          ? supabase.from("credit_notes").select("*, credit_note_lines(*)").order("cn_date", { ascending: false })
          : supabase.from("debit_notes").select("*, debit_note_lines(*)").order("dn_date", { ascending: false }),
        supabase.from("invoices").select("*, invoice_lines(*)").eq("document_status", "posted").gt("outstanding_amount", 0).order("invoice_date", { ascending: false }),
        supabase.from("purchase_bills").select("*, purchase_bill_lines(*)").eq("document_status", "posted").gt("outstanding_amount", 0).order("bill_date", { ascending: false }),
      ]);
      if (noteResult.error) throw noteResult.error;
      if (invoiceResult.error) throw invoiceResult.error;
      if (billResult.error) throw billResult.error;
      setNotes(noteResult.data || []);
      setInvoices(invoiceResult.data || []);
      setBills(billResult.data || []);
    } catch (err) {
      setError(err.message);
    }
    setLoading(false);
  };

  useEffect(() => { load(); }, [noteType]);

  const save = async (header, lines) => {
    setBusy(true);
    setError(null);
    try {
      const functionName = noteType === "cn" ? "create_credit_note" : "create_debit_note";
      const { data: id, error: rpcError } = await supabase.rpc(functionName, { p_header: header, p_lines: lines });
      if (rpcError) throw rpcError;
      setShowForm(false);
      await load();
      const table = noteType === "cn" ? "credit_notes" : "debit_notes";
      const select = noteType === "cn" ? "*, credit_note_lines(*)" : "*, debit_note_lines(*)";
      const { data: note, error: readError } = await supabase.from(table).select(select).eq("id", id).single();
      if (readError) throw readError;
      setPrintNote(note);
    } catch (err) {
      setError(err.message);
    }
    setBusy(false);
  };

  if (printNote) return <NotePrint note={printNote} noteType={noteType} onClose={() => setPrintNote(null)} />;

  const credit = noteType === "cn";
  return (
    <div className="panel">
      <div className="panel-head">
        <h2>Credit &amp; Debit Notes</h2>
        <button className="btn" onClick={() => setShowForm((current) => !current)}>{showForm ? "Close Editor" : `+ New ${credit ? "Credit" : "Debit"} Note`}</button>
      </div>

      <div className="filter-tabs" style={{ marginBottom: 16 }}>
        <button className={`filter-tab${credit ? " active" : ""}`} onClick={() => { setNoteType("cn"); setShowForm(false); }}>Credit Notes / Sales Returns</button>
        <button className={`filter-tab${!credit ? " active" : ""}`} onClick={() => { setNoteType("dn"); setShowForm(false); }}>Debit Notes / Purchase Returns</button>
      </div>

      <div className="settings-info-box" style={{ marginBottom: 16 }}>
        {credit
          ? "Credit notes reduce customer receivables and reverse sales, output VAT, inventory, and COGS for returned goods."
          : "Debit notes reduce vendor payables and reverse input VAT, inventory or purchase expense, with weighted-average valuation differences recorded separately."}
      </div>

      {showForm && <ReturnForm noteType={noteType} invoices={invoices} bills={bills} onSave={save} onClose={() => setShowForm(false)} busy={busy} error={error} />}
      {error && !showForm && <p className="msg err">{error}</p>}

      {loading ? <p className="note">Loading…</p> : notes.length === 0 ? <p className="note">No {credit ? "credit" : "debit"} notes yet.</p> : (
        <div style={{ overflowX: "auto" }}>
          <table className="tbl">
            <thead><tr><th>#</th><th>Date</th><th>{credit ? "Customer" : "Vendor"}</th><th>Original</th><th>Reason</th><th className="num">Total</th><th>Status</th><th /></tr></thead>
            <tbody>
              {notes.map((note) => {
                const number = credit ? note.cn_number : note.dn_number;
                const date = credit ? note.cn_date : note.dn_date;
                return (
                  <tr key={note.id}>
                    <td><b>{credit ? "CN" : "DN"}-{String(number).padStart(4, "0")}</b></td>
                    <td>{date}</td><td>{credit ? note.party_name : note.vendor_name}</td>
                    <td>{credit ? `Invoice #${note.invoice_number}` : `Bill #${note.bill_number}`}</td>
                    <td>{note.reason}</td><td className="num"><b>NPR {fmt(note.total)}</b></td>
                    <td><span className={`status-${note.document_status}`}>{note.document_status}</span></td>
                    <td style={{ whiteSpace: "nowrap" }}>
                      <button className="link" onClick={() => setPrintNote(note)}>Print</button>
                      <button className="link" onClick={() => setActivityNote(note)}>Activity</button>
                      {note.document_status === "posted" && <button className="link" style={{ color: "var(--rust)" }} onClick={() => setCancelNote(note)}>Cancel</button>}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}

      {activityNote && <DocumentActivityModal documentType={credit ? "credit_note" : "debit_note"} document={activityNote} title={`${credit ? "Credit" : "Debit"} Note #${credit ? activityNote.cn_number : activityNote.dn_number}`} onClose={() => setActivityNote(null)} />}
      {cancelNote && (
        <LifecycleActionModal
          title={`Cancel ${credit ? "Credit" : "Debit"} Note #${credit ? cancelNote.cn_number : cancelNote.dn_number}`}
          description="The note remains in the audit trail and an equal-and-opposite voucher and stock movement will be posted."
          actionLabel="Cancel & Reverse"
          onClose={() => setCancelNote(null)}
          onConfirm={async (reason, date) => {
            if (credit) await cancelCreditNote(cancelNote.id, reason, date);
            else await cancelDebitNote(cancelNote.id, reason, date);
            await load();
          }}
        />
      )}
    </div>
  );
}
