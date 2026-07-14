// ============================================================
// Phase P3 — Items page
// The item master. Rich fields (SKU, HSN, brand, category,
// default sales/purchase rates, preferred vendor, item type).
// Old Inventory.jsx keeps stock-movement / closing-stock UI;
// this page owns the item master and category picker.
// ============================================================

import React, { useEffect, useMemo, useState } from "react";
import {
  listItems, createItem, updateItem, deactivateItem,
  listCategories, createCategory,
} from "../lib/items";
import { listContacts } from "../lib/contacts";

const ITEM_TYPES = [
  { key: "goods",         label: "Goods (tracked in inventory)" },
  { key: "service",       label: "Service (no inventory)" },
  { key: "non_inventory", label: "Non-inventory (goods, but not tracked)" },
];

const UNITS = ["pcs", "kg", "gm", "ltr", "ml", "box", "ctn", "pack", "dozen", "meter", "sqft"];

const fmt = (n) => Number(n || 0).toLocaleString("en-IN", { maximumFractionDigits: 2 });

const BLANK = {
  name: "", nameNp: "", sku: "", hsnCode: "", brand: "",
  categoryId: "", itemType: "goods", unit: "pcs",
  salesPrice: "0", salesTaxRate: "13",
  purchasePrice: "0", purchaseTaxRate: "13",
  preferredVendorId: "",
  trackInventory: true,
  openingStock: "0", openingStockValue: "0",
  reorderLevel: "0",
  description: "",
};

function ItemFormModal({ initial, categories, vendors, onSave, onCancel, onNewCategory, busy, err }) {
  const [f, setF] = useState(initial || BLANK);
  const set = (k, v) => setF((x) => ({ ...x, [k]: v }));

  // Auto-flip track_inventory when itemType changes
  useEffect(() => {
    if (f.itemType === "service" || f.itemType === "non_inventory") {
      if (f.trackInventory) set("trackInventory", false);
    } else if (f.itemType === "goods" && !f.trackInventory) {
      set("trackInventory", true);
    }
    // eslint-disable-next-line
  }, [f.itemType]);

  const submit = (e) => {
    e.preventDefault();
    onSave({
      ...f,
      salesPrice: Number(f.salesPrice) || 0,
      purchasePrice: Number(f.purchasePrice) || 0,
      salesTaxRate: Number(f.salesTaxRate) || 0,
      purchaseTaxRate: Number(f.purchaseTaxRate) || 0,
      openingStock: Number(f.openingStock) || 0,
      openingStockValue: Number(f.openingStockValue) || 0,
      reorderLevel: Number(f.reorderLevel) || 0,
      categoryId: f.categoryId || null,
      preferredVendorId: f.preferredVendorId || null,
    });
  };

  return (
    <div className="modal-overlay" onClick={onCancel}>
      <div className="modal" onClick={(e) => e.stopPropagation()}
           style={{ maxWidth: 800, width: "94%", maxHeight: "92vh", overflowY: "auto" }}>
        <div className="panel-head">
          <h3>{initial?.id ? "Edit Item" : "New Item"}</h3>
          <button className="link" onClick={onCancel}>✕</button>
        </div>

        <form onSubmit={submit} style={{ display: "grid", gap: 12, padding: 16 }}>

          {/* Type + basics */}
          <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 10 }}>
            <label className="fld">Item type
              <select value={f.itemType} onChange={(e) => set("itemType", e.target.value)}>
                {ITEM_TYPES.map((t) => <option key={t.key} value={t.key}>{t.label}</option>)}
              </select>
            </label>
            <label className="fld">Unit
              <select value={f.unit} onChange={(e) => set("unit", e.target.value)}>
                {UNITS.map((u) => <option key={u} value={u}>{u}</option>)}
              </select>
            </label>
            <label className="fld">Name *
              <input required autoFocus value={f.name}
                     onChange={(e) => set("name", e.target.value)}
                     placeholder="e.g. Red Bull 250ml" />
            </label>
            <label className="fld">Devanagari
              <input value={f.nameNp} lang="ne"
                     onChange={(e) => set("nameNp", e.target.value)} placeholder="रेड बुल" />
            </label>
            <label className="fld">SKU / Item code
              <input value={f.sku} onChange={(e) => set("sku", e.target.value)}
                     placeholder="RB-250 (optional, auto-generated if blank)" />
            </label>
            <label className="fld">HSN code
              <input value={f.hsnCode} onChange={(e) => set("hsnCode", e.target.value)}
                     placeholder="e.g. 22029910 — required on IRD tax invoice" />
            </label>
            <label className="fld">Brand
              <input value={f.brand} onChange={(e) => set("brand", e.target.value)} placeholder="Red Bull, HQD, Geek Bar…" />
            </label>
            <label className="fld">
              Category
              <div style={{ display: "flex", gap: 6 }}>
                <select value={f.categoryId} onChange={(e) => set("categoryId", e.target.value)}
                        style={{ flex: 1 }}>
                  <option value="">— none —</option>
                  {categories.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
                </select>
                <button type="button" className="ghost-btn" onClick={onNewCategory} title="Add category">+ New</button>
              </div>
            </label>
          </div>

          {/* Sales */}
          <div style={{ background: "#f0f9ff", padding: 12, borderRadius: 6, borderLeft: "3px solid #0284c7" }}>
            <div style={{ fontWeight: 600, marginBottom: 8 }}>Sales defaults</div>
            <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 10 }}>
              <label className="fld" style={{ margin: 0 }}>Sales price (NPR)
                <input type="number" step="0.01" value={f.salesPrice}
                       onChange={(e) => set("salesPrice", e.target.value)} />
              </label>
              <label className="fld" style={{ margin: 0 }}>Sales VAT rate (%)
                <input type="number" step="0.01" value={f.salesTaxRate}
                       onChange={(e) => set("salesTaxRate", e.target.value)} />
              </label>
            </div>
          </div>

          {/* Purchase */}
          <div style={{ background: "#fef3c7", padding: 12, borderRadius: 6, borderLeft: "3px solid #d97706" }}>
            <div style={{ fontWeight: 600, marginBottom: 8 }}>Purchase defaults</div>
            <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr 2fr", gap: 10 }}>
              <label className="fld" style={{ margin: 0 }}>Purchase cost (NPR)
                <input type="number" step="0.01" value={f.purchasePrice}
                       onChange={(e) => set("purchasePrice", e.target.value)} />
              </label>
              <label className="fld" style={{ margin: 0 }}>Purchase VAT rate (%)
                <input type="number" step="0.01" value={f.purchaseTaxRate}
                       onChange={(e) => set("purchaseTaxRate", e.target.value)} />
              </label>
              <label className="fld" style={{ margin: 0 }}>Preferred vendor
                <select value={f.preferredVendorId}
                        onChange={(e) => set("preferredVendorId", e.target.value)}>
                  <option value="">— none —</option>
                  {vendors.map((v) => <option key={v.id} value={v.id}>{v.name}</option>)}
                </select>
              </label>
            </div>
          </div>

          {/* Inventory tracking (only if goods) */}
          {f.itemType === "goods" && (
            <div style={{ background: "#f5f5f5", padding: 12, borderRadius: 6 }}>
              <label style={{ display: "flex", alignItems: "center", gap: 8, marginBottom: 10 }}>
                <input type="checkbox" checked={f.trackInventory}
                       onChange={(e) => set("trackInventory", e.target.checked)} />
                <span style={{ fontWeight: 600 }}>Track inventory for this item</span>
              </label>
              {f.trackInventory && (
                <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr 1fr", gap: 10 }}>
                  <label className="fld" style={{ margin: 0 }}>Opening stock
                    <input type="number" step="0.001" value={f.openingStock}
                           onChange={(e) => set("openingStock", e.target.value)} />
                  </label>
                  <label className="fld" style={{ margin: 0 }}>Opening value (NPR)
                    <input type="number" step="0.01" value={f.openingStockValue}
                           onChange={(e) => set("openingStockValue", e.target.value)} />
                  </label>
                  <label className="fld" style={{ margin: 0 }}>Reorder level
                    <input type="number" step="0.001" value={f.reorderLevel}
                           onChange={(e) => set("reorderLevel", e.target.value)} />
                  </label>
                </div>
              )}
            </div>
          )}

          <label className="fld">Description
            <input value={f.description} onChange={(e) => set("description", e.target.value)}
                   placeholder="Optional — appears on invoice line by default" />
          </label>

          {err && <p className="msg err">{err}</p>}

          <div style={{ display: "flex", gap: 10, justifyContent: "flex-end", paddingTop: 6 }}>
            <button type="button" className="ghost-btn" onClick={onCancel}>Cancel</button>
            <button type="submit" className="btn" disabled={busy}>
              {busy ? "Saving…" : (initial?.id ? "Save changes" : "Save Item")}
            </button>
          </div>
        </form>
      </div>
    </div>
  );
}

// Quick modal to create a category inline while editing an item
function QuickCategoryModal({ onSave, onCancel, busy }) {
  const [name, setName] = useState("");
  const [nameNp, setNameNp] = useState("");
  const submit = (e) => {
    e.preventDefault();
    onSave({ name: name.trim(), nameNp: nameNp.trim() || null });
  };
  return (
    <div className="modal-overlay" onClick={onCancel}>
      <div className="modal" onClick={(e) => e.stopPropagation()} style={{ maxWidth: 460, width: "94%" }}>
        <div className="panel-head"><h3>New Category</h3><button className="link" onClick={onCancel}>✕</button></div>
        <form onSubmit={submit} style={{ padding: 16, display: "grid", gap: 10 }}>
          <label className="fld">Name *<input required autoFocus value={name} onChange={(e) => setName(e.target.value)} /></label>
          <label className="fld">Devanagari<input value={nameNp} lang="ne" onChange={(e) => setNameNp(e.target.value)} /></label>
          <div style={{ display: "flex", gap: 10, justifyContent: "flex-end" }}>
            <button type="button" className="ghost-btn" onClick={onCancel}>Cancel</button>
            <button type="submit" className="btn" disabled={busy}>{busy ? "Saving…" : "Add"}</button>
          </div>
        </form>
      </div>
    </div>
  );
}

export default function Items({ onChanged }) {
  const [rows, setRows] = useState([]);
  const [categories, setCategories] = useState([]);
  const [vendors, setVendors] = useState([]);
  const [search, setSearch] = useState("");
  const [categoryFilter, setCategoryFilter] = useState("");
  const [lowOnly, setLowOnly] = useState(false);
  const [inactive, setInactive] = useState(false);
  const [loading, setLoading] = useState(true);
  const [err, setErr] = useState(null);

  const [showForm, setShowForm] = useState(false);
  const [editing, setEditing] = useState(null);
  const [showQuickCat, setShowQuickCat] = useState(false);
  const [busy, setBusy] = useState(false);
  const [formErr, setFormErr] = useState(null);

  const load = async () => {
    setLoading(true);
    try {
      const [i, c, v] = await Promise.all([
        listItems({
          search,
          categoryId: categoryFilter || null,
          lowStockOnly: lowOnly,
          activeOnly: !inactive,
        }),
        listCategories(),
        listContacts({ role: "vendor" }),
      ]);
      setRows(i); setCategories(c); setVendors(v);
      setErr(null);
    } catch (e) { setErr(e.message); }
    setLoading(false);
  };

  useEffect(() => { load(); }, [categoryFilter, lowOnly, inactive]); // eslint-disable-line
  useEffect(() => {
    const t = setTimeout(load, 250);
    return () => clearTimeout(t);
  }, [search]); // eslint-disable-line

  const totalStockValue = useMemo(
    () => rows.reduce((s, r) => s + Number(r.current_stock || 0) * Number(r.purchase_price || 0), 0),
    [rows]
  );

  const submit = async (fields) => {
    setBusy(true); setFormErr(null);
    try {
      if (editing?.id) await updateItem(editing.id, fields);
      else await createItem(fields);
      setShowForm(false); setEditing(null);
      await load();
      onChanged && onChanged();
    } catch (e) { setFormErr(e.message); }
    setBusy(false);
  };

  const openEdit = (r) => {
    setEditing({
      id: r.id, name: r.name, nameNp: r.name_np || "",
      sku: r.sku || "", hsnCode: r.hsn_code || "", brand: r.brand || "",
      categoryId: r.category_id || "", itemType: r.item_type || "goods",
      unit: r.unit || "pcs",
      salesPrice: String(r.sales_price ?? 0), salesTaxRate: String(r.sales_tax_rate ?? 13),
      purchasePrice: String(r.purchase_price ?? 0), purchaseTaxRate: String(r.purchase_tax_rate ?? 13),
      preferredVendorId: r.preferred_vendor_id || "",
      trackInventory: !!r.track_inventory,
      openingStock: "0", openingStockValue: "0",
      reorderLevel: String(r.reorder_level ?? 0),
      description: r.description || "",
    });
    setShowForm(true);
  };

  const saveQuickCat = async (fields) => {
    setBusy(true);
    try {
      const id = await createCategory(fields);
      const cs = await listCategories();
      setCategories(cs);
      // Push the just-created category onto the current form (if open)
      setEditing((e) => (e ? { ...e, categoryId: id } : e));
      setShowQuickCat(false);
    } catch (e) { setFormErr(e.message); }
    setBusy(false);
  };

  return (
    <div className="panel">
      <div className="panel-head">
        <div>
          <h2>Items</h2>
          <div className="muted" style={{ fontSize: 13 }}>
            The item master. Feeds invoice lines and bill lines with smart defaults —
            enter the price, VAT, HSN once and every future document uses it.
          </div>
        </div>
        <button className="btn" onClick={() => { setEditing(null); setShowForm(true); }}>+ New Item</button>
      </div>

      <div style={{ display: "flex", gap: 8, flexWrap: "wrap", padding: "10px 16px",
                    alignItems: "center", borderBottom: "1px solid #eee" }}>
        <input placeholder="Search name, SKU, HSN, brand…" value={search}
               onChange={(e) => setSearch(e.target.value)}
               style={{ padding: "6px 10px", minWidth: 240 }} />
        <select value={categoryFilter} onChange={(e) => setCategoryFilter(e.target.value)}>
          <option value="">All categories</option>
          {categories.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
        </select>
        <label style={{ display: "inline-flex", alignItems: "center", gap: 4, fontSize: 13 }}>
          <input type="checkbox" checked={lowOnly} onChange={(e) => setLowOnly(e.target.checked)} />
          Low stock only
        </label>
        <label style={{ display: "inline-flex", alignItems: "center", gap: 4, fontSize: 13 }}>
          <input type="checkbox" checked={inactive} onChange={(e) => setInactive(e.target.checked)} />
          Include inactive
        </label>
        <div style={{ marginLeft: "auto", fontSize: 13 }} className="muted">
          {rows.length} items · Stock value NPR {fmt(totalStockValue)}
        </div>
      </div>

      {err && <p className="msg err">{err}</p>}

      {loading ? <p className="note">Loading…</p> : rows.length === 0 ? (
        <p className="note">
          No items match. <a className="link" onClick={() => { setEditing(null); setShowForm(true); }}>Add your first item.</a>
        </p>
      ) : (
        <table className="tbl">
          <thead>
            <tr>
              <th>Name</th>
              <th>Category / Brand</th>
              <th>SKU / HSN</th>
              <th>Type</th>
              <th className="num">Sales / Purchase</th>
              <th className="num">Stock</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            {rows.map((r) => (
              <tr key={r.id} style={{ opacity: r.is_active ? 1 : 0.55 }}>
                <td>
                  <div style={{ fontWeight: 600 }}>{r.name}</div>
                  {r.name_np && <div className="muted" style={{ fontSize: 12 }}>{r.name_np}</div>}
                </td>
                <td>
                  {r.category_name || <span className="muted">Uncategorized</span>}
                  {r.brand && <div className="muted" style={{ fontSize: 12 }}>{r.brand}</div>}
                </td>
                <td className="muted" style={{ fontSize: 13 }}>
                  {r.sku && <div>{r.sku}</div>}
                  {r.hsn_code && <div>HSN {r.hsn_code}</div>}
                  {!r.sku && !r.hsn_code && "—"}
                </td>
                <td className="muted" style={{ fontSize: 13 }}>
                  {r.item_type === "service" ? "Service" :
                   r.item_type === "non_inventory" ? "Non-inventory" :
                   r.track_inventory ? "Goods (tracked)" : "Goods (untracked)"}
                </td>
                <td className="num">
                  <div>NPR {fmt(r.sales_price)} <span className="muted" style={{ fontSize: 11 }}>+{r.sales_tax_rate}%</span></div>
                  <div className="muted" style={{ fontSize: 12 }}>Cost NPR {fmt(r.purchase_price)}</div>
                </td>
                <td className="num">
                  {r.track_inventory ? (
                    <>
                      <div style={{ fontWeight: 600, color: r.is_low_stock ? "var(--rust,#a4442d)" : "inherit" }}>
                        {fmt(r.current_stock)} {r.unit}
                      </div>
                      {r.reorder_level > 0 &&
                        <div className="muted" style={{ fontSize: 11 }}>reorder ≤ {fmt(r.reorder_level)}</div>}
                      {r.is_low_stock &&
                        <div style={{ fontSize: 11, color: "var(--rust,#a4442d)", fontWeight: 600 }}>LOW STOCK</div>}
                    </>
                  ) : <span className="muted">—</span>}
                </td>
                <td style={{ whiteSpace: "nowrap" }}>
                  <button className="link" onClick={() => openEdit(r)}>Edit</button>
                  {r.is_active && (
                    <>{" · "}
                      <button className="link" style={{ color: "var(--rust,#a4442d)" }}
                              onClick={() => { if (confirm(`Deactivate ${r.name}?`)) deactivateItem(r.id).then(load); }}>
                        Deactivate
                      </button>
                    </>
                  )}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}

      {showForm && (
        <ItemFormModal
          initial={editing}
          categories={categories}
          vendors={vendors}
          onNewCategory={() => setShowQuickCat(true)}
          onSave={submit}
          onCancel={() => { setShowForm(false); setEditing(null); setFormErr(null); }}
          busy={busy}
          err={formErr}
        />
      )}
      {showQuickCat && (
        <QuickCategoryModal
          onSave={saveQuickCat}
          onCancel={() => setShowQuickCat(false)}
          busy={busy}
        />
      )}
    </div>
  );
}
