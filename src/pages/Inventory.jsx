import React, { useEffect, useState } from "react";
import { supabase } from "../supabase";

// ── DB helpers ────────────────────────────────────────────────
async function listItems() {
  const { data, error } = await supabase
    .from("inventory_items")
    .select("*")
    .order("name");
  if (error) throw error;
  return data;
}

async function listMovements(itemId) {
  const { data, error } = await supabase
    .from("inventory_movements")
    .select("*")
    .eq("item_id", itemId)
    .order("movement_date", { ascending: false })
    .limit(50);
  if (error) throw error;
  return data;
}

async function saveItem(userId, item) {
  const { data, error } = await supabase
    .from("inventory_items")
    .insert({ user_id: userId, ...item })
    .select().single();
  if (error) throw error;
  return data;
}

async function recordMovement(userId, movement) {
  const { data, error } = await supabase
    .from("inventory_movements")
    .insert({ user_id: userId, ...movement })
    .select().single();
  if (error) throw error;
  // update current stock
  const delta = movement.movement_type === "in" ? movement.quantity : -movement.quantity;
  await supabase.rpc("update_stock", { p_item_id: movement.item_id, p_delta: delta });
  return data;
}

async function updateItem(id, patch) {
  const { error } = await supabase.from("inventory_items").update(patch).eq("id", id);
  if (error) throw error;
}

// ── Main Inventory page ───────────────────────────────────────
// ── Closing Stock panel — posts stock value to the ledger ─────
function ClosingStockPanel({ totalStockValue, onPosted }) {
  const [show, setShow]   = useState(false);
  const [amount, setAmount] = useState("");
  const [date, setDate]   = useState(new Date().toISOString().slice(0,10));
  const [notes, setNotes] = useState("");
  const [busy, setBusy]   = useState(false);
  const [err, setErr]     = useState(null);
  const [ok, setOk]       = useState(null);

  const currentFY = () => {
    const d = new Date();
    return d.getMonth() >= 6 ? `${d.getFullYear()}/${String(d.getFullYear()+1).slice(2)}` : `${d.getFullYear()-1}/${String(d.getFullYear()).slice(2)}`;
  };

  const post = async () => {
    const amt = parseFloat(amount) || totalStockValue;
    if (amt <= 0) { setErr("Enter a valid closing stock amount."); return; }
    setBusy(true); setErr(null); setOk(null);
    try {
      const { error } = await supabase.rpc("post_closing_stock", {
        p_date: date, p_amount: amt, p_fiscal_year: currentFY(),
        p_notes: notes.trim() || "Closing stock valuation adjustment",
      });
      if (error) throw error;
      setOk(`Posted NPR ${amt.toLocaleString()} closing stock — check Balance Sheet & P&L.`);
      setShow(false);
      onPosted && onPosted();
    } catch(e) { setErr(e.message); }
    setBusy(false);
  };

  return (
    <div className="settings-info-box" style={{marginBottom:16,background:"#fdf6e3",borderLeftColor:"var(--gold)"}}>
      <div style={{display:"flex",justifyContent:"space-between",alignItems:"center",flexWrap:"wrap",gap:8}}>
        <div>
          <b>Closing Stock:</b> your current stock is valued at <b>NPR {totalStockValue.toLocaleString()}</b> (weighted average cost).
          Post this to your books so it appears on the Balance Sheet and correctly reduces Cost of Goods Sold in Profit &amp; Loss.
        </div>
        <button className="ghost-btn" onClick={()=>{setShow(s=>!s); setAmount(String(totalStockValue));}}>
          {show ? "Cancel" : "Post Closing Stock →"}
        </button>
      </div>

      {show && (
        <div style={{marginTop:12,display:"flex",gap:10,flexWrap:"wrap",alignItems:"flex-end"}}>
          <label className="fld" style={{margin:0}}>
            Amount (NPR)
            <input type="number" step="0.01" value={amount} onChange={e=>setAmount(e.target.value)} />
          </label>
          <label className="fld" style={{margin:0}}>
            As of Date
            <input type="date" value={date} onChange={e=>setDate(e.target.value)} />
          </label>
          <label className="fld" style={{margin:0,flex:"1 1 180px"}}>
            Notes
            <input placeholder="Optional" value={notes} onChange={e=>setNotes(e.target.value)} />
          </label>
          <button className="btn" onClick={post} disabled={busy}>{busy?"Posting…":"Post Entry"}</button>
        </div>
      )}
      {err && <p className="msg err" style={{marginTop:8}}>{err}</p>}
      {ok  && <p className="msg ok"  style={{marginTop:8}}>{ok}</p>}
    </div>
  );
}

export default function Inventory({ userId }) {
  const [items, setItems] = useState([]);
  const [loading, setLoading] = useState(true);
  const [err, setErr] = useState(null);
  const [showItemForm, setShowItemForm] = useState(false);
  const [showMoveForm, setShowMoveForm] = useState(false);
  const [selectedItem, setSelectedItem] = useState(null);
  const [movements, setMovements] = useState([]);
  const [movLoading, setMovLoading] = useState(false);
  const [busy, setBusy] = useState(false);
  const [filter, setFilter] = useState("all");

  const [itemForm, setItemForm] = useState({
    name: "", category: "", unit: "pcs", reorder_level: "0",
    cost_price: "", selling_price: "", description: "",
  });

  const [moveForm, setMoveForm] = useState({
    itemId: "", movementType: "in", quantity: "", rate: "",
    movementDate: new Date().toISOString().slice(0,10),
    reference: "", notes: "",
  });

  const load = async () => {
    setLoading(true);
    try { setItems(await listItems()); setErr(null); }
    catch(e) { setErr(e.message); }
    setLoading(false);
  };

  useEffect(() => { load(); }, []);

  const loadMovements = async (item) => {
    setSelectedItem(item);
    setMovLoading(true);
    try { setMovements(await listMovements(item.id)); }
    catch(e) { setErr(e.message); }
    setMovLoading(false);
  };

  const submitItem = async (e) => {
    e.preventDefault();
    if (!itemForm.name.trim()) { setErr("Item name required."); return; }
    setBusy(true); setErr(null);
    try {
      await saveItem(userId, {
        name: itemForm.name.trim(),
        category: itemForm.category.trim() || "General",
        unit: itemForm.unit.trim() || "pcs",
        reorder_level: parseFloat(itemForm.reorder_level) || 0,
        cost_price: parseFloat(itemForm.cost_price) || 0,
        selling_price: parseFloat(itemForm.selling_price) || 0,
        description: itemForm.description.trim() || null,
        current_stock: 0,
      });
      setItemForm({ name:"", category:"", unit:"pcs", reorder_level:"0", cost_price:"", selling_price:"", description:"" });
      setShowItemForm(false);
      await load();
    } catch(e) { setErr(e.message); }
    setBusy(false);
  };

  const submitMove = async (e) => {
    e.preventDefault();
    if (!moveForm.itemId) { setErr("Select an item."); return; }
    if (!parseFloat(moveForm.quantity)) { setErr("Enter quantity."); return; }
    // check stock for out movement
    const item = items.find(i => i.id === moveForm.itemId);
    if (moveForm.movementType === "out" && item && Number(item.current_stock) < parseFloat(moveForm.quantity)) {
      setErr(`Insufficient stock. Current stock: ${item.current_stock} ${item.unit}`);
      return;
    }
    setBusy(true); setErr(null);
    try {
      await recordMovement(userId, {
        item_id: moveForm.itemId,
        movement_type: moveForm.movementType,
        quantity: parseFloat(moveForm.quantity),
        rate: parseFloat(moveForm.rate) || 0,
        movement_date: moveForm.movementDate,
        reference: moveForm.reference.trim() || null,
        notes: moveForm.notes.trim() || null,
      });
      setMoveForm({ itemId:"", movementType:"in", quantity:"", rate:"", movementDate: new Date().toISOString().slice(0,10), reference:"", notes:"" });
      setShowMoveForm(false);
      await load();
      if (selectedItem?.id === moveForm.itemId) await loadMovements(selectedItem);
    } catch(e) { setErr(e.message); }
    setBusy(false);
  };

  const filtered = filter === "all" ? items
    : filter === "low" ? items.filter(i => Number(i.current_stock) <= Number(i.reorder_level))
    : items.filter(i => i.category === filter);

  const categories = [...new Set(items.map(i => i.category))].filter(Boolean);
  const lowStockCount = items.filter(i => Number(i.current_stock) <= Number(i.reorder_level)).length;
  const totalItems = items.length;
  const totalStockValue = items.reduce((s,i) => s + Number(i.current_stock) * Number(i.cost_price), 0);

  return (
    <div className="panel">
      <div className="panel-head">
        <h2>Inventory (स्टक)</h2>
        <div style={{display:"flex",gap:8}}>
          <button className="ghost-btn" onClick={() => { setShowMoveForm(s=>!s); setShowItemForm(false); }}>
            {showMoveForm ? "Cancel" : "± Stock Movement"}
          </button>
          <button className="btn" onClick={() => { setShowItemForm(s=>!s); setShowMoveForm(false); }}>
            {showItemForm ? "Cancel" : "+ New Item"}
          </button>
        </div>
      </div>

      {/* Stats */}
      <div className="stat-row">
        <div className="stat"><span>{totalItems}</span>Total Items</div>
        <div className="stat"><span style={{color:lowStockCount>0?"var(--rust)":"var(--green2)"}}>{lowStockCount}</span>Low Stock</div>
        <div className="stat"><span>NPR {totalStockValue.toLocaleString()}</span>Stock Value</div>
      </div>

      {/* Closing Stock — posts the stock value to the ledger as a Balance Sheet asset */}
      <ClosingStockPanel totalStockValue={totalStockValue} onPosted={load} />

      {lowStockCount > 0 && (
        <div className="alert-bar">
          ⚠ {lowStockCount} item{lowStockCount>1?"s":""} at or below reorder level.
          <button className="link" style={{display:"inline",marginLeft:8}} onClick={()=>setFilter("low")}>View →</button>
        </div>
      )}

      {/* New Item Form */}
      {showItemForm && (
        <form className="inv-form" onSubmit={submitItem}>
          <b style={{marginBottom:8,display:"block"}}>New Inventory Item</b>
          <div className="inv-form-top">
            <label className="fld">Item Name <input placeholder="e.g. A4 Paper" value={itemForm.name} onChange={e=>setItemForm(f=>({...f,name:e.target.value}))} required /></label>
            <label className="fld">Category <input placeholder="e.g. Stationery" value={itemForm.category} onChange={e=>setItemForm(f=>({...f,category:e.target.value}))} /></label>
            <label className="fld">Unit <input placeholder="pcs / kg / ltr" value={itemForm.unit} onChange={e=>setItemForm(f=>({...f,unit:e.target.value}))} /></label>
            <label className="fld">Cost Price <input type="number" step="0.01" placeholder="0" value={itemForm.cost_price} onChange={e=>setItemForm(f=>({...f,cost_price:e.target.value}))} /></label>
            <label className="fld">Selling Price <input type="number" step="0.01" placeholder="0" value={itemForm.selling_price} onChange={e=>setItemForm(f=>({...f,selling_price:e.target.value}))} /></label>
            <label className="fld">Reorder Level <input type="number" step="0.001" placeholder="0" value={itemForm.reorder_level} onChange={e=>setItemForm(f=>({...f,reorder_level:e.target.value}))} /></label>
            <label className="fld wide-field">Description <input placeholder="Optional description" value={itemForm.description} onChange={e=>setItemForm(f=>({...f,description:e.target.value}))} /></label>
          </div>
          {err && <p className="msg err">{err}</p>}
          <button className="btn" disabled={busy}>{busy?"Saving…":"Save Item"}</button>
        </form>
      )}

      {/* Stock Movement Form */}
      {showMoveForm && (
        <form className="inv-form" onSubmit={submitMove}>
          <b style={{marginBottom:8,display:"block"}}>Record Stock Movement</b>
          <div className="inv-form-top">
            <label className="fld">Item
              <select value={moveForm.itemId} onChange={e=>setMoveForm(f=>({...f,itemId:e.target.value}))} required>
                <option value="">Select item…</option>
                {items.map(i=><option key={i.id} value={i.id}>{i.name} (Stock: {i.current_stock} {i.unit})</option>)}
              </select>
            </label>
            <label className="fld">Type
              <select value={moveForm.movementType} onChange={e=>setMoveForm(f=>({...f,movementType:e.target.value}))}>
                <option value="in">Stock In (Purchase / Return)</option>
                <option value="out">Stock Out (Sale / Use)</option>
                <option value="adjustment">Adjustment</option>
              </select>
            </label>
            <label className="fld">Quantity <input type="number" step="0.001" placeholder="0" value={moveForm.quantity} onChange={e=>setMoveForm(f=>({...f,quantity:e.target.value}))} required /></label>
            <label className="fld">Rate/Unit <input type="number" step="0.01" placeholder="Cost per unit" value={moveForm.rate} onChange={e=>setMoveForm(f=>({...f,rate:e.target.value}))} /></label>
            <label className="fld">Date <input type="date" value={moveForm.movementDate} onChange={e=>setMoveForm(f=>({...f,movementDate:e.target.value}))} /></label>
            <label className="fld">Reference <input placeholder="Invoice # / Bill #" value={moveForm.reference} onChange={e=>setMoveForm(f=>({...f,reference:e.target.value}))} /></label>
            <label className="fld wide-field">Notes <input placeholder="Optional notes" value={moveForm.notes} onChange={e=>setMoveForm(f=>({...f,notes:e.target.value}))} /></label>
          </div>
          {err && <p className="msg err">{err}</p>}
          <button className="btn" disabled={busy}>{busy?"Saving…":"Record Movement"}</button>
        </form>
      )}

      {/* Filter */}
      <div className="filter-tabs">
        <button className={"filter-tab"+(filter==="all"?" active":"")} onClick={()=>setFilter("all")}>All</button>
        <button className={"filter-tab"+(filter==="low"?" active":"")} onClick={()=>setFilter("low")} style={{color:lowStockCount>0?"var(--rust)":""}}>
          Low Stock {lowStockCount>0&&`(${lowStockCount})`}
        </button>
        {categories.map(c=>(
          <button key={c} className={"filter-tab"+(filter===c?" active":"")} onClick={()=>setFilter(c)}>{c}</button>
        ))}
      </div>

      {/* Items table */}
      {loading ? <p className="note">Loading…</p> : filtered.length === 0 ? (
        <p className="note">No items found. Add your first inventory item above.</p>
      ) : (
        <table className="tbl" style={{marginTop:8}}>
          <thead>
            <tr><th>Item</th><th>Category</th><th>Unit</th><th className="num">Stock</th><th className="num">Reorder</th><th className="num">Cost</th><th className="num">Selling</th><th className="num">Value</th><th/></tr>
          </thead>
          <tbody>
            {filtered.map(i=>{
              const isLow = Number(i.current_stock) <= Number(i.reorder_level);
              return (
                <tr key={i.id} className={isLow?"low-stock-row":""}>
                  <td><b>{i.name}</b>{i.description&&<div className="muted" style={{fontSize:11}}>{i.description}</div>}</td>
                  <td className="muted">{i.category}</td>
                  <td>{i.unit}</td>
                  <td className={"num"+(isLow?" low-stock-val":"")}><b>{Number(i.current_stock).toLocaleString()}</b>{isLow&&<span className="tag tag-void">Low</span>}</td>
                  <td className="num muted">{Number(i.reorder_level).toLocaleString()}</td>
                  <td className="num">{Number(i.cost_price).toLocaleString()}</td>
                  <td className="num">{Number(i.selling_price).toLocaleString()}</td>
                  <td className="num">{(Number(i.current_stock)*Number(i.cost_price)).toLocaleString()}</td>
                  <td><button className="link" onClick={()=>loadMovements(i)}>History</button></td>
                </tr>
              );
            })}
          </tbody>
          <tfoot>
            <tr>
              <td colSpan={7} className="muted">Total stock value</td>
              <td className="num"><b>NPR {totalStockValue.toLocaleString()}</b></td>
              <td/>
            </tr>
          </tfoot>
        </table>
      )}

      {/* Movement history panel */}
      {selectedItem && (
        <div className="panel" style={{marginTop:16}}>
          <div className="panel-head">
            <h2>Stock History — {selectedItem.name}</h2>
            <button className="link" onClick={()=>{setSelectedItem(null);setMovements([]);}}>✕ Close</button>
          </div>
          <p className="note">Current stock: <b>{selectedItem.current_stock} {selectedItem.unit}</b></p>
          {movLoading ? <p className="note">Loading…</p> : movements.length === 0 ? (
            <p className="note">No movements recorded yet.</p>
          ) : (
            <table className="tbl">
              <thead><tr><th>Date</th><th>Type</th><th className="num">Qty</th><th className="num">Rate</th><th className="num">Value</th><th>Reference</th><th>Notes</th></tr></thead>
              <tbody>
                {movements.map(m=>(
                  <tr key={m.id}>
                    <td>{m.movement_date}</td>
                    <td><span className={m.movement_type==="in"?"mov-in":m.movement_type==="out"?"mov-out":"mov-adj"}>{m.movement_type}</span></td>
                    <td className="num">{m.movement_type==="out"?"-":""}{Number(m.quantity).toLocaleString()}</td>
                    <td className="num">{Number(m.rate).toLocaleString()}</td>
                    <td className="num">{(Number(m.quantity)*Number(m.rate)).toLocaleString()}</td>
                    <td>{m.reference||"—"}</td>
                    <td className="muted">{m.notes||"—"}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
        </div>
      )}
    </div>
  );
}
