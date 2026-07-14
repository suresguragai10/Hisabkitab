import React, { useEffect, useState } from "react";
import { listParties, createParty } from "../lib/db";

export default function Parties({ userId, onChanged }) {
  const [parties, setParties] = useState([]);
  const [loading, setLoading] = useState(true);
  const [err, setErr] = useState(null);
  const [showForm, setShowForm] = useState(false);
  const [busy, setBusy] = useState(false);
  const [form, setForm] = useState({
    name: "", partyType: "customer", phone: "", email: "", address: "",
    panVat: "",
  });

  const load = async () => {
    setLoading(true);
    try {
      setParties(await listParties());
      setErr(null);
    } catch (e) {
      setErr(e.message);
    }
    setLoading(false);
  };

  useEffect(() => { load(); }, []);

  const submit = async (e) => {
    e.preventDefault();
    if (!form.name.trim()) { setErr("Name is required."); return; }
    setBusy(true);
    try {
      await createParty(userId, {
        name: form.name.trim(),
        partyType: form.partyType,
        phone: form.phone.trim(),
        email: form.email.trim(),
        address: form.address.trim(),
        panVat: form.panVat.trim(),
        openingBalance: 0,
      });
      setForm({ name: "", partyType: "customer", phone: "", email: "", address: "", panVat: "" });
      setShowForm(false);
      await load();
      onChanged && onChanged();
    } catch (e) {
      setErr(e.message);
    }
    setBusy(false);
  };

  return (
    <div className="panel">
      <div className="panel-head">
        <h2>Parties (Customers &amp; Vendors)</h2>
        <button className="btn" onClick={() => setShowForm((s) => !s)}>
          {showForm ? "Cancel" : "+ New Party"}
        </button>
      </div>

      {showForm && (
        <form className="grid-form" onSubmit={submit}>
          <input placeholder="Name" value={form.name} onChange={(e) => setForm({ ...form, name: e.target.value })} required />
          <select value={form.partyType} onChange={(e) => setForm({ ...form, partyType: e.target.value })}>
            <option value="customer">Customer</option>
            <option value="vendor">Vendor</option>
            <option value="both">Both</option>
          </select>
          <input placeholder="Phone" value={form.phone} onChange={(e) => setForm({ ...form, phone: e.target.value })} />
          <input placeholder="Email" value={form.email} onChange={(e) => setForm({ ...form, email: e.target.value })} />
          <input placeholder="PAN / VAT number" value={form.panVat} onChange={(e) => setForm({ ...form, panVat: e.target.value })} />
          <input placeholder="Address" value={form.address} onChange={(e) => setForm({ ...form, address: e.target.value })} className="wide-field" />
          <p className="note wide-field">Post starting receivables or payables through Chart of Accounts → Opening Journal after saving the party.</p>
          <button className="btn" disabled={busy}>{busy ? "Saving…" : "Save Party"}</button>
        </form>
      )}

      {err && <p className="msg err">{err}</p>}
      {loading ? <p className="note">Loading…</p> : (
        parties.length === 0 ? <p className="note">No parties yet. Add your first customer or vendor.</p> : (
          <table className="tbl">
            <thead><tr><th>Name</th><th>Type</th><th>Phone</th><th>PAN/VAT</th><th className="num">Opening</th></tr></thead>
            <tbody>
              {parties.map((p) => (
                <tr key={p.id}>
                  <td>{p.accounts?.name}</td>
                  <td className="muted">{p.party_type}</td>
                  <td>{p.phone || "—"}</td>
                  <td>{p.pan_vat_number || "—"}</td>
                  <td className="num">
                    {Number(p.accounts?.opening_balance || 0).toLocaleString()} {p.accounts?.opening_balance_type === "debit" ? "Dr" : "Cr"}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )
      )}
    </div>
  );
}
