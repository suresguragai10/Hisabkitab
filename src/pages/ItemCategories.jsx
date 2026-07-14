// ============================================================
// Phase P3 — Item Categories page
// Simple flat + optional-parent hierarchy management.
// ============================================================

import React, { useEffect, useState } from "react";
import { listCategories, createCategory, updateCategory } from "../lib/items";

const BLANK = { name: "", nameNp: "", parentId: "", notes: "" };

export default function ItemCategories({ onChanged }) {
  const [rows, setRows] = useState([]);
  const [loading, setLoading] = useState(true);
  const [err, setErr] = useState(null);
  const [form, setForm] = useState(BLANK);
  const [editing, setEditing] = useState(null);
  const [busy, setBusy] = useState(false);

  const load = async () => {
    setLoading(true);
    try {
      setRows(await listCategories({ activeOnly: false }));
      setErr(null);
    } catch (e) { setErr(e.message); }
    setLoading(false);
  };
  useEffect(() => { load(); }, []);

  const parentName = (id) => rows.find((r) => r.id === id)?.name || "";

  const save = async (e) => {
    e.preventDefault();
    if (!form.name.trim()) { setErr("Name is required"); return; }
    setBusy(true); setErr(null);
    try {
      if (editing) {
        await updateCategory(editing.id, {
          name: form.name.trim(),
          nameNp: form.nameNp.trim() || null,
          parentId: form.parentId || null,
          notes: form.notes.trim() || null,
        });
      } else {
        await createCategory({
          name: form.name.trim(),
          nameNp: form.nameNp.trim() || null,
          parentId: form.parentId || null,
          notes: form.notes.trim() || null,
        });
      }
      setForm(BLANK); setEditing(null);
      await load();
      onChanged && onChanged();
    } catch (e) { setErr(e.message); }
    setBusy(false);
  };

  const toggleActive = async (row) => {
    try {
      await updateCategory(row.id, { isActive: !row.is_active });
      await load();
    } catch (e) { setErr(e.message); }
  };

  const startEdit = (row) => {
    setEditing(row);
    setForm({
      name: row.name || "",
      nameNp: row.name_np || "",
      parentId: row.parent_id || "",
      notes: row.notes || "",
    });
  };

  return (
    <div className="panel">
      <div className="panel-head">
        <div>
          <h2>Item Categories</h2>
          <div className="muted" style={{ fontSize: 13 }}>
            Group items so you can run "sales by category" and keep item lists tidy.
            Optional parent lets you nest ("Beverages → Energy Drinks").
          </div>
        </div>
      </div>

      <form onSubmit={save} style={{ display: "grid",
        gridTemplateColumns: "2fr 2fr 2fr 3fr auto",
        gap: 10, padding: 16, alignItems: "end" }}>
        <label className="fld" style={{ margin: 0 }}>
          Name *
          <input required value={form.name}
                 onChange={(e) => setForm({ ...form, name: e.target.value })}
                 placeholder="e.g. Beverages" />
        </label>
        <label className="fld" style={{ margin: 0 }}>
          Devanagari
          <input value={form.nameNp} lang="ne"
                 onChange={(e) => setForm({ ...form, nameNp: e.target.value })}
                 placeholder="पेय पदार्थ" />
        </label>
        <label className="fld" style={{ margin: 0 }}>
          Parent (optional)
          <select value={form.parentId}
                  onChange={(e) => setForm({ ...form, parentId: e.target.value })}>
            <option value="">— top level —</option>
            {rows.filter((r) => r.is_active && r.id !== editing?.id).map((r) => (
              <option key={r.id} value={r.id}>{r.name}</option>
            ))}
          </select>
        </label>
        <label className="fld" style={{ margin: 0 }}>
          Notes
          <input value={form.notes}
                 onChange={(e) => setForm({ ...form, notes: e.target.value })} />
        </label>
        <div style={{ display: "flex", gap: 6 }}>
          <button className="btn" disabled={busy}>
            {busy ? "Saving…" : (editing ? "Save" : "+ Add")}
          </button>
          {editing && (
            <button type="button" className="ghost-btn"
                    onClick={() => { setEditing(null); setForm(BLANK); }}>Cancel</button>
          )}
        </div>
      </form>

      {err && <p className="msg err">{err}</p>}

      {loading ? <p className="note">Loading…</p> : rows.length === 0 ? (
        <p className="note">No categories yet. Add your first one above.</p>
      ) : (
        <table className="tbl">
          <thead>
            <tr>
              <th>Name</th>
              <th>Devanagari</th>
              <th>Parent</th>
              <th>Notes</th>
              <th>Status</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            {rows.map((r) => (
              <tr key={r.id} style={{ opacity: r.is_active ? 1 : 0.55 }}>
                <td style={{ fontWeight: 600 }}>{r.name}</td>
                <td>{r.name_np || "—"}</td>
                <td className="muted">{parentName(r.parent_id) || "—"}</td>
                <td className="muted">{r.notes || "—"}</td>
                <td>{r.is_active
                  ? <span className="badge" style={{ background: "#dcfce7" }}>Active</span>
                  : <span className="badge" style={{ background: "#fee2e2" }}>Inactive</span>}</td>
                <td>
                  <button className="link" onClick={() => startEdit(r)}>Edit</button>
                  {" · "}
                  <button className="link" onClick={() => toggleActive(r)}>
                    {r.is_active ? "Deactivate" : "Reactivate"}
                  </button>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </div>
  );
}
