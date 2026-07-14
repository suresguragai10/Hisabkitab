import React, { useEffect, useState } from "react";
import { supabase } from "../supabase";
import {
  addInternalNote,
  deleteAttachment,
  listDocumentActivity,
  registerAttachment,
} from "../lib/lifecycle";

function formatBytes(value) {
  const bytes = Number(value || 0);
  if (!bytes) return "";
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

function safeFileName(name) {
  return name.replace(/[^a-zA-Z0-9._-]+/g, "-").slice(-120) || "attachment";
}

export default function DocumentActivityModal({ documentType, document, title, onClose }) {
  const [notes, setNotes] = useState([]);
  const [attachments, setAttachments] = useState([]);
  const [noteText, setNoteText] = useState("");
  const [file, setFile] = useState(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);

  const load = async () => {
    setError(null);
    try {
      const result = await listDocumentActivity(documentType, document.id);
      setNotes(result.notes);
      setAttachments(result.attachments);
    } catch (err) {
      setError(err.message || "Could not load document activity.");
    }
  };

  useEffect(() => { load(); }, [documentType, document.id]);

  const saveNote = async () => {
    if (!noteText.trim()) return;
    setBusy(true);
    setError(null);
    try {
      await addInternalNote(documentType, document.id, noteText.trim());
      setNoteText("");
      await load();
    } catch (err) {
      setError(err.message || "Could not save the note.");
    } finally {
      setBusy(false);
    }
  };

  const upload = async () => {
    if (!file) return;
    setBusy(true);
    setError(null);
    let uploadedPath = null;
    try {
      const { data: authData, error: authError } = await supabase.auth.getUser();
      if (authError) throw authError;
      const userId = authData?.user?.id;
      if (!userId) throw new Error("Not authenticated.");
      const unique = typeof crypto !== "undefined" && crypto.randomUUID
        ? crypto.randomUUID()
        : `${Date.now()}-${Math.random().toString(16).slice(2)}`;
      uploadedPath = `${userId}/${documentType}/${document.id}/${unique}-${safeFileName(file.name)}`;
      const { error: uploadError } = await supabase.storage
        .from("document-attachments")
        .upload(uploadedPath, file, { upsert: false });
      if (uploadError) throw uploadError;
      await registerAttachment(documentType, document.id, uploadedPath, file);
      setFile(null);
      await load();
    } catch (err) {
      if (uploadedPath) {
        await supabase.storage.from("document-attachments").remove([uploadedPath]);
      }
      setError(err.message || "Could not upload the attachment.");
    } finally {
      setBusy(false);
    }
  };

  const openAttachment = async (attachment) => {
    setError(null);
    const { data, error: signedError } = await supabase.storage
      .from(attachment.storage_bucket || "document-attachments")
      .createSignedUrl(attachment.storage_path, 60);
    if (signedError) {
      setError(signedError.message);
      return;
    }
    window.open(data.signedUrl, "_blank", "noopener,noreferrer");
  };

  const removeAttachment = async (attachment) => {
    setBusy(true);
    setError(null);
    try {
      const { error: removeError } = await supabase.storage
        .from(attachment.storage_bucket || "document-attachments")
        .remove([attachment.storage_path]);
      if (removeError) throw removeError;
      await deleteAttachment(attachment.id);
      await load();
    } catch (err) {
      setError(err.message || "Could not delete the attachment.");
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="modal-overlay" role="dialog" aria-modal="true" aria-label={title || "Document activity"}>
      <div className="modal-card" style={{ maxWidth: 720 }}>
        <div className="modal-head">
          <div>
            <h3>{title || "Document activity"}</h3>
            <div className="muted" style={{ fontSize: 12 }}>
              Internal notes are not printed. Attachments are stored privately.
            </div>
          </div>
          <button type="button" className="link" onClick={onClose} aria-label="Close">✕</button>
        </div>

        <section style={{ marginBottom: 22 }}>
          <b>Internal notes</b>
          <textarea
            rows={3}
            style={{ width: "100%", marginTop: 8 }}
            value={noteText}
            onChange={(e) => setNoteText(e.target.value)}
            placeholder="Add a private note for your team…"
          />
          <div style={{ marginTop: 8 }}>
            <button className="ghost-btn" onClick={saveNote} disabled={busy || !noteText.trim()}>Add Note</button>
          </div>
          <div style={{ marginTop: 10, display: "grid", gap: 8 }}>
            {notes.length === 0 ? <span className="muted">No internal notes.</span> : notes.map((note) => (
              <div key={note.id} className="settings-info-box" style={{ margin: 0 }}>
                <div>{note.note_text}</div>
                <div className="muted" style={{ fontSize: 11, marginTop: 5 }}>
                  {new Date(note.created_at).toLocaleString()}
                </div>
              </div>
            ))}
          </div>
        </section>

        <section>
          <b>Attachments</b>
          <div style={{ display: "flex", gap: 8, alignItems: "center", marginTop: 8, flexWrap: "wrap" }}>
            <input type="file" onChange={(e) => setFile(e.target.files?.[0] || null)} />
            <button className="ghost-btn" onClick={upload} disabled={busy || !file}>Upload</button>
          </div>
          <div style={{ marginTop: 10, display: "grid", gap: 8 }}>
            {attachments.length === 0 ? <span className="muted">No attachments.</span> : attachments.map((attachment) => (
              <div key={attachment.id} style={{ display: "flex", justifyContent: "space-between", gap: 10, alignItems: "center", borderBottom: "1px solid var(--line)", paddingBottom: 8 }}>
                <div>
                  <button className="link" onClick={() => openAttachment(attachment)}>{attachment.file_name}</button>
                  <div className="muted" style={{ fontSize: 11 }}>
                    {[attachment.mime_type, formatBytes(attachment.size_bytes)].filter(Boolean).join(" · ")}
                  </div>
                </div>
                <button className="link" style={{ color: "var(--rust)" }} onClick={() => removeAttachment(attachment)} disabled={busy}>Delete</button>
              </div>
            ))}
          </div>
        </section>

        {error && <p className="msg err">{error}</p>}
        <div className="modal-actions">
          <button className="btn" onClick={onClose}>Done</button>
        </div>
      </div>
    </div>
  );
}
