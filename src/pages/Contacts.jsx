// ============================================================
// Phase P3 — Contacts page (replaces Parties)
// UX principles:
//   * Tabs for All / Customers / Vendors / Both / Inactive.
//   * Search that hits name, phone, email, PAN.
//   * Outstanding shown at a glance ("They owe" / "You owe").
//   * "+ New Contact" opens a rich modal with role checkboxes.
//   * A contact can be both customer + vendor (checkboxes, not enum).
//   * Statement of Account link jumps into the ledger filtered
//     to that contact's backing account.
// ============================================================

import React, { useEffect, useMemo, useState } from "react";
import {
  listContacts, createContact, updateContact, deactivateContact,
} from "../lib/contacts";

const ROLE_TABS = [
  { key: "all",      label: "All" },
  { key: "customer", label: "Customers" },
  { key: "vendor",   label: "Vendors" },
  { key: "both",     label: "Customer + Vendor" },
  { key: "inactive", label: "Inactive" },
];

// Small NPR formatter — keep it lightweight, no library.
const fmt = (n) => {
  if (n === null || n === undefined || Number.isNaN(Number(n))) return "0";
  return Number(n).toLocaleString("en-IN", { maximumFractionDigits: 2 });
};

// Present an outstanding balance in plain-language terms a business
// owner understands, colored by direction. Customer outstanding > 0
// = they owe you (green good). Vendor outstanding < 0 = you owe them.
function OutstandingCell({ contact }) {
  const v = Number(contact.outstanding || 0);
  if (Math.abs(v) < 0.005) {
    return <span className="muted">Settled</span>;
  }
  // For a customer-account (asset), positive means they owe you.
  // For a vendor-account (liability, stored as opening_balance with
  // 'credit' type), positive outstanding still means the receivable
  // side — but for a pure vendor contact the account itself is a
  // liability, so we flip the interpretation based on role.
  const owesYou = contact.is_customer && v > 0;
  const youOwe  = contact.is_vendor   && v < 0;
  if (owesYou) {
    return <span style={{ color: "var(--ok,#0a7a2f)", fontWeight: 600 }}>
      Owes you NPR {fmt(v)}
    </span>;
  }
  if (youOwe) {
    return <span style={{ color: "var(--rust,#a4442d)", fontWeight: 600 }}>
      You owe NPR {fmt(Math.abs(v))}
    </span>;
  }
  // Fallback: show magnitude with sign hint
  return <span>NPR {fmt(v)} {v > 0 ? "Dr" : "Cr"}</span>;
}

const BLANK_FORM = {
  name: "",
  nameNp: "",
  isCustomer: true,
  isVendor: false,
  contactPerson: "",
  phone: "",
  email: "",
  billingAddress: "",
  shippingAddress: "",
  panNumber: "",
  vatNumber: "",
  paymentTermsDays: "",
  tdsApplicable: false,
  tdsRate: "",
  notes: "",
  openingBalance: "0",
  openingBalanceType: "debit",
};

function ContactFormModal({ initial, onSave, onCancel, busy, err }) {
  const [f, setF] = useState(initial || BLANK_FORM);

  const set = (k, v) => setF((x) => ({ ...x, [k]: v }));

  const submit = (e) => {
    e.preventDefault();
    onSave({
      ...f,
      paymentTermsDays: f.paymentTermsDays ? Number(f.paymentTermsDays) : null,
      tdsRate: f.tdsRate ? Number(f.tdsRate) : null,
      openingBalance: Number(f.openingBalance) || 0,
    });
  };

  return (
    <div className="modal-overlay" onClick={onCancel}>
      <div className="modal" onClick={(e) => e.stopPropagation()}
           style={{ maxWidth: 720, width: "94%", maxHeight: "90vh", overflowY: "auto" }}>
        <div className="panel-head">
          <h3>{initial?.id ? "Edit Contact" : "New Contact"}</h3>
          <button className="link" onClick={onCancel}>✕</button>
        </div>

        <form onSubmit={submit} style={{ display: "grid", gap: 12, padding: 16 }}>
          {/* Role — the most important field. Presented as two clear checkboxes. */}
          <div style={{ background: "#fdf6e3", padding: 12, borderRadius: 6, borderLeft: "3px solid var(--gold,#b8860b)" }}>
            <div style={{ fontWeight: 600, marginBottom: 8 }}>This contact is a:</div>
            <label style={{ display: "inline-flex", alignItems: "center", gap: 6, marginRight: 24 }}>
              <input type="checkbox" checked={f.isCustomer}
                     onChange={(e) => set("isCustomer", e.target.checked)} />
              <span>Customer <span className="muted">(will appear on invoices)</span></span>
            </label>
            <label style={{ display: "inline-flex", alignItems: "center", gap: 6 }}>
              <input type="checkbox" checked={f.isVendor}
                     onChange={(e) => set("isVendor", e.target.checked)} />
              <span>Vendor <span className="muted">(will appear on bills)</span></span>
            </label>
          </div>

          <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 10 }}>
            <label className="fld">Business / Legal name *
              <input required autoFocus value={f.name}
                     onChange={(e) => set("name", e.target.value)} />
            </label>
            <label className="fld">Devanagari name (नाम)
              <input value={f.nameNp} lang="ne"
                     onChange={(e) => set("nameNp", e.target.value)} />
            </label>
            <label className="fld">Contact person
              <input value={f.contactPerson}
                     onChange={(e) => set("contactPerson", e.target.value)} />
            </label>
            <label className="fld">Phone
              <input value={f.phone}
                     onChange={(e) => set("phone", e.target.value)} />
            </label>
            <label className="fld">Email
              <input type="email" value={f.email}
                     onChange={(e) => set("email", e.target.value)} />
            </label>
            <label className="fld">Payment terms (days)
              <input type="number" min="0" value={f.paymentTermsDays}
                     placeholder="e.g. 30"
                     onChange={(e) => set("paymentTermsDays", e.target.value)} />
            </label>
            <label className="fld" style={{ gridColumn: "1 / -1" }}>Billing address
              <input value={f.billingAddress}
                     onChange={(e) => set("billingAddress", e.target.value)} />
            </label>
            <label className="fld" style={{ gridColumn: "1 / -1" }}>Shipping address <span className="muted">(if different)</span>
              <input value={f.shippingAddress}
                     onChange={(e) => set("shippingAddress", e.target.value)} />
            </label>
            <label className="fld">PAN number
              <input value={f.panNumber} placeholder="9-digit PAN"
                     onChange={(e) => set("panNumber", e.target.value)} />
            </label>
            <label className="fld">VAT number <span className="muted">(if VAT-registered)</span>
              <input value={f.vatNumber}
                     onChange={(e) => set("vatNumber", e.target.value)} />
            </label>
          </div>

          <div style={{ display: "grid", gridTemplateColumns: "auto 1fr", gap: 10, alignItems: "center",
                        background: "#fafafa", padding: 12, borderRadius: 6 }}>
            <label style={{ display: "inline-flex", alignItems: "center", gap: 6, whiteSpace: "nowrap" }}>
              <input type="checkbox" checked={f.tdsApplicable}
                     onChange={(e) => set("tdsApplicable", e.target.checked)} />
              <span>TDS applicable</span>
            </label>
            {f.tdsApplicable && (
              <label className="fld" style={{ margin: 0 }}>Default TDS rate (%)
                <input type="number" step="0.01" value={f.tdsRate}
                       placeholder="e.g. 10 for rent, 15 for professional"
                       onChange={(e) => set("tdsRate", e.target.value)} />
              </label>
            )}
          </div>

          {!initial?.id && (
            <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 10,
                          borderTop: "1px solid #eee", paddingTop: 12 }}>
              <label className="fld">Opening balance
                <input type="number" step="0.01" value={f.openingBalance}
                       onChange={(e) => set("openingBalance", e.target.value)} />
              </label>
              <label className="fld">Type
                <select value={f.openingBalanceType}
                        onChange={(e) => set("openingBalanceType", e.target.value)}>
                  <option value="debit">They owe you (Dr)</option>
                  <option value="credit">You owe them (Cr)</option>
                </select>
              </label>
            </div>
          )}

          <label className="fld">Notes
            <input value={f.notes} onChange={(e) => set("notes", e.target.value)}
                   placeholder="Anything worth remembering when we invoice/bill this contact" />
          </label>

          {err && <p className="msg err">{err}</p>}

          <div style={{ display: "flex", gap: 10, justifyContent: "flex-end", paddingTop: 6 }}>
            <button type="button" className="ghost-btn" onClick={onCancel}>Cancel</button>
            <button type="submit" className="btn" disabled={busy}>
              {busy ? "Saving…" : (initial?.id ? "Save changes" : "Save Contact")}
            </button>
          </div>
        </form>
      </div>
    </div>
  );
}

export default function Contacts({ userId, onChanged, onViewStatement }) {
  const [tab, setTab] = useState("all");
  const [rows, setRows] = useState([]);
  const [search, setSearch] = useState("");
  const [loading, setLoading] = useState(true);
  const [err, setErr] = useState(null);
  const [showForm, setShowForm] = useState(false);
  const [editing, setEditing] = useState(null);
  const [busy, setBusy] = useState(false);
  const [formErr, setFormErr] = useState(null);

  const load = async () => {
    setLoading(true);
    try {
      const data = await listContacts({ role: tab, search });
      setRows(data);
      setErr(null);
    } catch (e) {
      setErr(e.message);
    }
    setLoading(false);
  };

  useEffect(() => { load(); }, [tab]); // eslint-disable-line

  // Debounce search so we don't hit the DB on every keystroke.
  useEffect(() => {
    const t = setTimeout(load, 250);
    return () => clearTimeout(t);
  }, [search]); // eslint-disable-line

  const counts = useMemo(() => {
    // Only computed for current tab's rows — accurate enough for the header.
    const c = { all: rows.length, customer: 0, vendor: 0, both: 0 };
    for (const r of rows) {
      if (r.is_customer && r.is_vendor) c.both++;
      else if (r.is_customer) c.customer++;
      else if (r.is_vendor) c.vendor++;
    }
    return c;
  }, [rows]);

  const submit = async (fields) => {
    setBusy(true); setFormErr(null);
    try {
      if (editing?.id) {
        await updateContact(editing.id, fields);
      } else {
        await createContact(fields);
      }
      setShowForm(false); setEditing(null);
      await load();
      onChanged && onChanged();
    } catch (e) {
      setFormErr(e.message);
    }
    setBusy(false);
  };

  const openEdit = (row) => {
    setEditing({
      id: row.id,
      name: row.name,
      nameNp: row.name_np || "",
      isCustomer: row.is_customer,
      isVendor: row.is_vendor,
      contactPerson: row.contact_person || "",
      phone: row.phone || "",
      email: row.email || "",
      billingAddress: row.billing_address || "",
      shippingAddress: row.shipping_address || "",
      panNumber: row.pan_number || "",
      vatNumber: row.vat_number || "",
      paymentTermsDays: row.payment_terms_days ?? "",
      tdsApplicable: !!row.tds_applicable,
      tdsRate: row.tds_rate ?? "",
      notes: row.notes || "",
      openingBalance: "0",
      openingBalanceType: "debit",
    });
    setShowForm(true);
  };

  const deactivate = async (row) => {
    if (!confirm(`Deactivate ${row.name}? They'll be hidden but their history stays intact.`)) return;
    try {
      await deactivateContact(row.id);
      await load();
    } catch (e) { setErr(e.message); }
  };

  return (
    <div className="panel">
      <div className="panel-head">
        <div>
          <h2>Contacts</h2>
          <div className="muted" style={{ fontSize: 13 }}>
            One record per business. Customers, vendors, or both — used across invoices, bills, and reports.
          </div>
        </div>
        <button className="btn" onClick={() => { setEditing(null); setShowForm(true); }}>
          + New Contact
        </button>
      </div>

      {/* Tabs */}
      <div style={{ display: "flex", gap: 6, flexWrap: "wrap", padding: "10px 16px", borderBottom: "1px solid #eee" }}>
        {ROLE_TABS.map((t) => (
          <button key={t.key}
            className={tab === t.key ? "btn" : "ghost-btn"}
            style={{ padding: "6px 12px", fontSize: 13 }}
            onClick={() => setTab(t.key)}>
            {t.label}
            {tab === t.key && ` (${counts[t.key] ?? rows.length})`}
          </button>
        ))}
        <input
          className="fld-inline"
          placeholder="Search name, phone, email, PAN…"
          value={search}
          onChange={(e) => setSearch(e.target.value)}
          style={{ marginLeft: "auto", padding: "6px 10px", minWidth: 240 }} />
      </div>

      {err && <p className="msg err">{err}</p>}

      {loading ? (
        <p className="note">Loading…</p>
      ) : rows.length === 0 ? (
        <p className="note">
          No contacts here yet. {tab !== "all" && "Try the All tab, or "}
          <a className="link" onClick={() => { setEditing(null); setShowForm(true); }}>add your first contact</a>.
        </p>
      ) : (
        <table className="tbl">
          <thead>
            <tr>
              <th>Name</th>
              <th>Role</th>
              <th>Contact</th>
              <th>PAN / VAT</th>
              <th className="num">Outstanding</th>
              <th>Terms</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            {rows.map((r) => (
              <tr key={r.id} style={{ opacity: r.is_active ? 1 : 0.55 }}>
                <td>
                  <div style={{ fontWeight: 600 }}>{r.name}</div>
                  {r.name_np && <div className="muted" style={{ fontSize: 12 }}>{r.name_np}</div>}
                  {r.contact_person && <div className="muted" style={{ fontSize: 12 }}>👤 {r.contact_person}</div>}
                </td>
                <td>
                  {r.is_customer && r.is_vendor && <span className="badge">Both</span>}
                  {r.is_customer && !r.is_vendor && <span className="badge" style={{ background: "#e0f2fe" }}>Customer</span>}
                  {r.is_vendor && !r.is_customer && <span className="badge" style={{ background: "#fef3c7" }}>Vendor</span>}
                  {r.tds_applicable && <div style={{ fontSize: 11, color: "var(--rust,#a4442d)", marginTop: 2 }}>TDS {r.tds_rate}%</div>}
                </td>
                <td>
                  {r.phone && <div>{r.phone}</div>}
                  {r.email && <div className="muted" style={{ fontSize: 12 }}>{r.email}</div>}
                  {r.billing_address && <div className="muted" style={{ fontSize: 12 }}>{r.billing_address}</div>}
                </td>
                <td className="muted" style={{ fontSize: 13 }}>
                  {r.pan_number && <div>PAN: {r.pan_number}</div>}
                  {r.vat_number && <div>VAT: {r.vat_number}</div>}
                  {!r.pan_number && !r.vat_number && "—"}
                </td>
                <td className="num">
                  <OutstandingCell contact={r} />
                </td>
                <td className="muted">
                  {r.payment_terms_days ? `${r.payment_terms_days} days` : "—"}
                </td>
                <td style={{ whiteSpace: "nowrap" }}>
                  <button className="link" onClick={() => openEdit(r)}>Edit</button>
                  {onViewStatement && (
                    <>
                      {" · "}
                      <button className="link" onClick={() => onViewStatement(r)}>Statement</button>
                    </>
                  )}
                  {r.is_active && (
                    <>
                      {" · "}
                      <button className="link" style={{ color: "var(--rust,#a4442d)" }} onClick={() => deactivate(r)}>Deactivate</button>
                    </>
                  )}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}

      {showForm && (
        <ContactFormModal
          initial={editing}
          busy={busy}
          err={formErr}
          onCancel={() => { setShowForm(false); setEditing(null); setFormErr(null); }}
          onSave={submit}
        />
      )}
    </div>
  );
}
