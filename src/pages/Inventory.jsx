import React, { useEffect, useMemo, useState } from "react";
import {
  getInventoryReconciliation,
  listInventoryItems,
  listInventoryMovements,
  recordInventoryAdjustment,
  reconcileInventoryLedger,
} from "../lib/inventory";
import { currentFiscalYear } from "../lib/fiscalYear";
import { todayLocalDate } from "../lib/nepaliCalendar";

const TODAY = () => todayLocalDate();
const fmt = (n, digits = 2) => Number(n || 0).toLocaleString("en-IN", {
  minimumFractionDigits: digits,
  maximumFractionDigits: digits,
});

const REASONS = [
  { value: "adjustment_in", label: "Stock In / Correction", direction: "in", cost: true },
  { value: "adjustment_out", label: "Stock Out / Correction", direction: "out", cost: false },
  { value: "damage", label: "Damaged / Written Off", direction: "out", cost: false },
  { value: "opening", label: "Opening Stock / Opening Correction", direction: "in", cost: true },
];

function ReconciliationPanel({ stats, loading, onRefresh, onReconciled }) {
  const [show, setShow] = useState(false);
  const [date, setDate] = useState(TODAY());
  const [reason, setReason] = useState("Stage 3 opening inventory reconciliation");
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState(null);
  const [ok, setOk] = useState(null);

  const difference = Number(stats?.difference || 0);
  const balanced = Math.abs(difference) <= 0.005;

  const post = async () => {
    if (reason.trim().length < 5) {
      setErr("Enter a clear reconciliation reason.");
      return;
    }
    setBusy(true); setErr(null); setOk(null);
    try {
      const voucherId = await reconcileInventoryLedger({
        date,
        fiscalYear: currentFiscalYear(),
        reason: reason.trim(),
      });
      setOk(voucherId
        ? "Inventory Asset was reconciled to the current stock valuation."
        : "No entry was needed; inventory already reconciles.");
      setShow(false);
      await onReconciled();
    } catch (e) {
      setErr(e.message);
    }
    setBusy(false);
  };

  return (
    <div className="settings-info-box" style={{ marginBottom: 16, borderLeftColor: balanced ? "var(--green2)" : "var(--gold)" }}>
      <div style={{ display: "flex", justifyContent: "space-between", gap: 12, alignItems: "flex-start", flexWrap: "wrap" }}>
        <div>
          <b>Inventory ↔ General Ledger reconciliation</b>
          <div className="muted" style={{ marginTop: 4 }}>
            Perpetual inventory using moving weighted-average cost. Purchases debit Inventory Asset; sales post COGS automatically.
          </div>
        </div>
        <button className="ghost-btn" onClick={onRefresh} disabled={loading}>{loading ? "Checking…" : "Refresh"}</button>
      </div>

      {stats && (
        <>
          <div className="stat-row" style={{ marginTop: 12 }}>
            <div className="stat"><span>NPR {fmt(stats.stock_valuation)}</span>Stock valuation</div>
            <div className="stat"><span>NPR {fmt(stats.inventory_ledger_balance)}</span>Inventory Asset ledger</div>
            <div className="stat">
              <span style={{ color: balanced ? "var(--green2)" : "var(--rust)" }}>NPR {fmt(difference)}</span>
              Difference
            </div>
            <div className="stat"><span>{Number(stats.legacy_movements || 0)}</span>Legacy movements</div>
          </div>

          {balanced ? (
            <p className="msg ok" style={{ marginTop: 10 }}>✓ Stock valuation equals the Inventory Asset ledger.</p>
          ) : (
            <div className="msg err" style={{ marginTop: 10 }}>
              <b>Reconciliation required.</b> Review legacy stock and costs before posting the one-time balancing entry.
              <button className="link" style={{ marginLeft: 8 }} onClick={() => setShow((v) => !v)}>
                {show ? "Cancel" : "Post reviewed reconciliation"}
              </button>
            </div>
          )}

          {Number(stats.unvalued_stock_items || 0) > 0 && (
            <p className="msg err">{stats.unvalued_stock_items} tracked item(s) have positive quantity but zero value.</p>
          )}
          {Number(stats.negative_stock_items || 0) > 0 && (
            <p className="msg err">{stats.negative_stock_items} tracked item(s) have negative stock and must be corrected.</p>
          )}
        </>
      )}

      {show && !balanced && (
        <div style={{ marginTop: 12, display: "flex", gap: 10, flexWrap: "wrap", alignItems: "flex-end" }}>
          <label className="fld" style={{ margin: 0 }}>
            Posting date
            <input type="date" value={date} onChange={(e) => setDate(e.target.value)} />
          </label>
          <label className="fld" style={{ margin: 0, flex: "1 1 300px" }}>
            Reason
            <input value={reason} onChange={(e) => setReason(e.target.value)} />
          </label>
          <button className="btn" onClick={post} disabled={busy}>{busy ? "Posting…" : "Post Reconciliation"}</button>
        </div>
      )}
      {err && <p className="msg err" style={{ marginTop: 8 }}>{err}</p>}
      {ok && <p className="msg ok" style={{ marginTop: 8 }}>{ok}</p>}
    </div>
  );
}

export default function Inventory() {
  const [items, setItems] = useState([]);
  const [stats, setStats] = useState(null);
  const [loading, setLoading] = useState(true);
  const [reconLoading, setReconLoading] = useState(false);
  const [err, setErr] = useState(null);
  const [showMoveForm, setShowMoveForm] = useState(false);
  const [selectedItem, setSelectedItem] = useState(null);
  const [movements, setMovements] = useState([]);
  const [movLoading, setMovLoading] = useState(false);
  const [busy, setBusy] = useState(false);
  const [filter, setFilter] = useState("all");
  const [moveForm, setMoveForm] = useState({
    itemId: "",
    reasonType: "adjustment_in",
    quantity: "",
    unitCost: "",
    movementDate: TODAY(),
    reference: "",
    notes: "",
  });

  const loadReconciliation = async () => {
    setReconLoading(true);
    try {
      setStats(await getInventoryReconciliation());
    } catch (e) {
      setErr(e.message);
    }
    setReconLoading(false);
  };

  const load = async () => {
    setLoading(true); setErr(null);
    try {
      const [rows, reconciliation] = await Promise.all([
        listInventoryItems(),
        getInventoryReconciliation(),
      ]);
      setItems(rows);
      setStats(reconciliation);
    } catch (e) {
      setErr(e.message);
    }
    setLoading(false);
  };

  useEffect(() => { load(); }, []);

  const loadMovements = async (item) => {
    setSelectedItem(item); setMovLoading(true); setErr(null);
    try {
      setMovements(await listInventoryMovements(item.id));
    } catch (e) {
      setErr(e.message);
    }
    setMovLoading(false);
  };

  const submitMovement = async (e) => {
    e.preventDefault();
    const quantity = Number(moveForm.quantity);
    if (!moveForm.itemId) { setErr("Select an item."); return; }
    if (!(quantity > 0)) { setErr("Quantity must be positive."); return; }

    const reason = REASONS.find((r) => r.value === moveForm.reasonType);
    const item = items.find((i) => i.id === moveForm.itemId);
    if (reason?.direction === "out" && item && Number(item.current_stock) + 0.0005 < quantity) {
      setErr(`Insufficient stock. Available: ${item.current_stock} ${item.unit}.`);
      return;
    }

    setBusy(true); setErr(null);
    try {
      await recordInventoryAdjustment({
        itemId: moveForm.itemId,
        reasonType: moveForm.reasonType,
        quantity,
        unitCost: reason?.cost ? Number(moveForm.unitCost || 0) : null,
        date: moveForm.movementDate,
        fiscalYear: currentFiscalYear(),
        reference: moveForm.reference.trim(),
        notes: moveForm.notes.trim(),
      });
      setMoveForm({
        itemId: "", reasonType: "adjustment_in", quantity: "", unitCost: "",
        movementDate: TODAY(), reference: "", notes: "",
      });
      setShowMoveForm(false);
      await load();
      if (selectedItem) {
        const refreshed = items.find((i) => i.id === selectedItem.id) || selectedItem;
        await loadMovements(refreshed);
      }
    } catch (e) {
      setErr(e.message);
    }
    setBusy(false);
  };

  const selectedReason = REASONS.find((r) => r.value === moveForm.reasonType);
  const filtered = filter === "low" ? items.filter((i) => i.is_low_stock) : items;
  const totalStockValue = useMemo(
    () => items.reduce((s, i) => s + Number(i.inventory_value || 0), 0),
    [items]
  );
  const lowStockCount = items.filter((i) => i.is_low_stock).length;

  return (
    <div className="panel">
      <div className="panel-head">
        <div>
          <h2>Inventory (स्टक)</h2>
          <div className="muted" style={{ fontSize: 13 }}>
            Quantity, weighted-average cost, stock value, COGS, and Inventory Asset are updated together in PostgreSQL.
          </div>
        </div>
        <button className="btn" onClick={() => setShowMoveForm((v) => !v)}>
          {showMoveForm ? "Cancel" : "+ Stock Adjustment"}
        </button>
      </div>

      <div className="stat-row">
        <div className="stat"><span>{items.length}</span>Tracked Items</div>
        <div className="stat"><span style={{ color: lowStockCount ? "var(--rust)" : "var(--green2)" }}>{lowStockCount}</span>Low Stock</div>
        <div className="stat"><span>NPR {fmt(totalStockValue)}</span>Weighted-Average Value</div>
      </div>

      <ReconciliationPanel
        stats={stats}
        loading={reconLoading}
        onRefresh={loadReconciliation}
        onReconciled={load}
      />

      {err && <p className="msg err">{err}</p>}

      {showMoveForm && (
        <form className="inv-form" onSubmit={submitMovement}>
          <b style={{ marginBottom: 8, display: "block" }}>Controlled Inventory Movement</b>
          <div className="inv-form-top">
            <label className="fld">Item
              <select value={moveForm.itemId} onChange={(e) => {
                const item = items.find((i) => i.id === e.target.value);
                setMoveForm((f) => ({
                  ...f,
                  itemId: e.target.value,
                  unitCost: item ? String(Number(item.average_cost || item.purchase_price || 0)) : "",
                }));
              }} required>
                <option value="">Select item…</option>
                {items.map((i) => (
                  <option key={i.id} value={i.id}>{i.name} (Stock: {fmt(i.current_stock, 3)} {i.unit})</option>
                ))}
              </select>
            </label>
            <label className="fld">Reason
              <select value={moveForm.reasonType} onChange={(e) => setMoveForm((f) => ({ ...f, reasonType: e.target.value }))}>
                {REASONS.map((r) => <option key={r.value} value={r.value}>{r.label}</option>)}
              </select>
            </label>
            <label className="fld">Quantity
              <input type="number" min="0.001" step="0.001" value={moveForm.quantity}
                     onChange={(e) => setMoveForm((f) => ({ ...f, quantity: e.target.value }))} required />
            </label>
            {selectedReason?.cost && (
              <label className="fld">Inbound unit cost
                <input type="number" min="0" step="0.01" value={moveForm.unitCost}
                       onChange={(e) => setMoveForm((f) => ({ ...f, unitCost: e.target.value }))} />
              </label>
            )}
            <label className="fld">Date
              <input type="date" value={moveForm.movementDate}
                     onChange={(e) => setMoveForm((f) => ({ ...f, movementDate: e.target.value }))} required />
            </label>
            <label className="fld">Reference
              <input value={moveForm.reference} onChange={(e) => setMoveForm((f) => ({ ...f, reference: e.target.value }))}
                     placeholder="Count sheet / reason" />
            </label>
            <label className="fld wide-field">Notes
              <input value={moveForm.notes} onChange={(e) => setMoveForm((f) => ({ ...f, notes: e.target.value }))}
                     placeholder="Supporting detail" />
            </label>
          </div>
          <p className="note">
            Outgoing stock is valued at the current weighted-average cost. Every non-zero-value movement posts a balanced journal automatically.
          </p>
          <button className="btn" disabled={busy}>{busy ? "Posting…" : "Post Movement"}</button>
        </form>
      )}

      <div className="filter-tabs">
        <button className={`filter-tab${filter === "all" ? " active" : ""}`} onClick={() => setFilter("all")}>All</button>
        <button className={`filter-tab${filter === "low" ? " active" : ""}`} onClick={() => setFilter("low")}>Low Stock ({lowStockCount})</button>
      </div>

      {loading ? <p className="note">Loading…</p> : filtered.length === 0 ? (
        <p className="note">No tracked inventory items. Create tracked goods from the Items page.</p>
      ) : (
        <div style={{ overflowX: "auto" }}>
          <table className="tbl" style={{ marginTop: 8 }}>
            <thead>
              <tr>
                <th>Item</th><th>Category</th><th>Unit</th>
                <th className="num">Stock</th><th className="num">Avg Cost</th>
                <th className="num">Value</th><th className="num">Reorder</th><th />
              </tr>
            </thead>
            <tbody>
              {filtered.map((i) => (
                <tr key={i.id} className={i.is_low_stock ? "low-stock-row" : ""}>
                  <td><b>{i.name}</b>{i.sku && <div className="muted" style={{ fontSize: 11 }}>{i.sku}</div>}</td>
                  <td className="muted">{i.category_name || "—"}</td>
                  <td>{i.unit}</td>
                  <td className={`num${i.is_low_stock ? " low-stock-val" : ""}`}><b>{fmt(i.current_stock, 3)}</b></td>
                  <td className="num">{fmt(i.average_cost ?? i.purchase_price, 2)}</td>
                  <td className="num"><b>{fmt(i.inventory_value)}</b></td>
                  <td className="num muted">{fmt(i.reorder_level, 3)}</td>
                  <td><button className="link" onClick={() => loadMovements(i)}>History</button></td>
                </tr>
              ))}
            </tbody>
            <tfoot>
              <tr><td colSpan={5} className="muted">Total inventory valuation</td><td className="num"><b>NPR {fmt(totalStockValue)}</b></td><td colSpan={2} /></tr>
            </tfoot>
          </table>
        </div>
      )}

      {selectedItem && (
        <div className="panel" style={{ marginTop: 16 }}>
          <div className="panel-head">
            <h2>Valuation History — {selectedItem.name}</h2>
            <button className="link" onClick={() => { setSelectedItem(null); setMovements([]); }}>✕ Close</button>
          </div>
          {movLoading ? <p className="note">Loading…</p> : movements.length === 0 ? (
            <p className="note">No movements recorded.</p>
          ) : (
            <div style={{ overflowX: "auto" }}>
              <table className="tbl">
                <thead>
                  <tr><th>Date</th><th>Source</th><th className="num">Qty Δ</th><th className="num">Unit Cost</th><th className="num">Cost</th><th className="num">Stock After</th><th className="num">Value After</th><th>Reference</th></tr>
                </thead>
                <tbody>
                  {movements.map((m) => (
                    <tr key={m.id}>
                      <td>{m.movement_date}</td>
                      <td><span className={Number(m.quantity_delta) >= 0 ? "mov-in" : "mov-out"}>{String(m.source_type || m.movement_type).replaceAll("_", " ")}</span>{m.is_legacy && <div className="muted" style={{ fontSize: 10 }}>legacy</div>}</td>
                      <td className="num">{Number(m.quantity_delta || 0) > 0 ? "+" : ""}{fmt(m.quantity_delta, 3)}</td>
                      <td className="num">{fmt(m.unit_cost ?? m.rate, 2)}</td>
                      <td className="num">{fmt(m.total_cost ?? Number(m.quantity || 0) * Number(m.rate || 0), 2)}</td>
                      <td className="num">{m.stock_after == null ? "—" : fmt(m.stock_after, 3)}</td>
                      <td className="num">{m.value_after == null ? "—" : fmt(m.value_after, 2)}</td>
                      <td>{m.reference || "—"}{m.notes && <div className="muted" style={{ fontSize: 11 }}>{m.notes}</div>}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </div>
      )}
    </div>
  );
}
