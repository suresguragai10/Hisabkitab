import React, { useEffect, useState } from "react";
import { supabase } from "../supabase";
import { listParties } from "../lib/db";
import { currentFiscalYear } from "../lib/fiscalYear";
import { createBillWithPosting, refreshDocumentPaymentStatuses } from "../lib/posting";
import PaymentModal from "./PaymentModal";
import { useBusinessProfile } from "../lib/businessProfile";

const VAT_RATE = 13;
const blankLine = () => ({ itemId: "", description: "", quantity: "1", unit: "pcs", rate: "", vatRate: VAT_RATE });

// ── helpers ───────────────────────────────────────────────────
function calcAmount(l) { return (parseFloat(l.quantity)||0) * (parseFloat(l.rate)||0); }
function calcVat(l) { return calcAmount(l) * ((parseFloat(l.vatRate)||0)/100); }

async function nextBillNumber(fiscalYear) {
  const { data, error } = await supabase.rpc("next_bill_number", { p_fiscal_year: fiscalYear });
  if (error) throw error;
  return data;
}

// NOTE: bill creation now goes through createBillWithPosting()
// (see ../lib/posting.js), which inserts the bill AND its balanced
// purchase voucher (Dr Inventory Asset or Purchase Expense / Dr VAT / Cr Vendor) in
// one transaction. The old non-posting insert was removed.

async function fetchItems() {
  const { data } = await supabase.from("inventory_items").select("id,name,unit,cost_price,average_cost,current_stock,hsn_code,track_inventory,item_type").eq("is_active",true).order("name");
  return data || [];
}

async function listBills() {
  const { data, error } = await supabase
    .from("purchase_bills")
    .select("*, purchase_bill_lines(*)")
    .order("bill_date", { ascending: false });
  if (error) throw error;
  return data;
}

async function updateBillStatus(id, status) {
  const { error } = await supabase.from("purchase_bills").update({ status }).eq("id", id);
  if (error) throw error;
}

// ── Bill print view ───────────────────────────────────────────
function BillPrint({ bill, bizName, profile, onClose }) {
  return (
    <div className="print-overlay">
      <div className="print-actions no-print">
        <button className="btn" onClick={() => window.print()}>🖨 Print / Save PDF</button>
        <button className="link" onClick={onClose}>← Back</button>
      </div>
      <div className="invoice-paper">
        <div className="inv-header">
          <div>
            <div className="inv-biz-name">{bizName || "Your Business"}</div>
            {profile?.address && <div className="inv-biz-sub">{profile.address}{profile.city ? ", "+profile.city : ""}</div>}
            {profile?.pan_vat && <div className="inv-biz-sub">PAN/VAT: {profile.pan_vat}</div>}
            <div className="inv-biz-sub">Purchase Record</div>
          </div>
          <div className="inv-title-block">
            <div className="inv-title">PURCHASE BILL</div>
            <div className="inv-title-sub">खरिद बिल</div>
          </div>
        </div>

        <div className="inv-meta">
          <div className="inv-meta-left">
            <div><b>Vendor:</b></div>
            <div>{bill.vendor_name}</div>
            {bill.vendor_address && <div>{bill.vendor_address}</div>}
            {bill.vendor_pan && <div>PAN: {bill.vendor_pan}</div>}
          </div>
          <div className="inv-meta-right">
            <div><span>Bill No:</span><b>{bill.fiscal_year}-PB-{String(bill.bill_number).padStart(4,"0")}</b></div>
            <div><span>Date:</span><b>{bill.bill_date}</b></div>
            {bill.due_date && <div><span>Due:</span><b>{bill.due_date}</b></div>}
            {bill.vendor_bill_ref && <div><span>Vendor Ref:</span><b>{bill.vendor_bill_ref}</b></div>}
          </div>
        </div>

        <table className="inv-table">
          <thead>
            <tr><th>#</th><th>Description</th><th>Unit</th><th className="r">Qty</th><th className="r">Rate</th><th className="r">Amount</th><th className="r">VAT%</th><th className="r">VAT</th><th className="r">Total</th></tr>
          </thead>
          <tbody>
            {bill.purchase_bill_lines.map((l,i) => (
              <tr key={l.id}>
                <td>{i+1}</td><td>{l.description}</td><td>{l.unit}</td>
                <td className="r">{l.quantity}</td>
                <td className="r">{Number(l.rate).toLocaleString()}</td>
                <td className="r">{Number(l.amount).toLocaleString()}</td>
                <td className="r">{l.vat_rate}%</td>
                <td className="r">{Number(l.vat_amount).toLocaleString()}</td>
                <td className="r">{Number(l.line_total).toLocaleString()}</td>
              </tr>
            ))}
          </tbody>
          <tfoot>
            <tr><td colSpan={5}></td><td className="r"><b>Subtotal</b></td><td colSpan={2}></td><td className="r"><b>{Number(bill.subtotal).toLocaleString()}</b></td></tr>
            <tr><td colSpan={5}></td><td className="r"><b>Input VAT</b></td><td colSpan={2}></td><td className="r"><b>{Number(bill.vat_amount).toLocaleString()}</b></td></tr>
            <tr className="inv-total-row"><td colSpan={5}></td><td className="r"><b>TOTAL</b></td><td colSpan={2}></td><td className="r"><b>{Number(bill.total).toLocaleString()}</b></td></tr>
          </tfoot>
        </table>

        {bill.notes && <div className="inv-notes"><b>Notes:</b> {bill.notes}</div>}
        <div className="inv-footer">
          <div className="inv-sign"><div className="inv-sign-line"></div><div>Received by</div></div>
          <div className="inv-footer-note">Input VAT claimable against output VAT</div>
        </div>
      </div>
    </div>
  );
}

// ── Main Purchases page ───────────────────────────────────────
export default function Purchases({ userId }) {
  const [bills, setBills] = useState([]);
  const [parties, setParties] = useState([]);
  const [loading, setLoading] = useState(true);
  const [showForm, setShowForm] = useState(false);
  const [printBill, setPrintBill] = useState(null);
  const [err, setErr] = useState(null);
  const [busy, setBusy] = useState(false);
  const [items, setItems] = useState([]);
  const [payModal, setPayModal] = useState(null);
  const [filter, setFilter] = useState("all");

  const { profile } = useBusinessProfile();
  const bizName = profile?.biz_name || "";

  const [form, setForm] = useState({
    vendorId: "", vendorName: "", vendorAddress: "", vendorPan: "",
    vendorBillRef: "", billDate: new Date().toISOString().slice(0,10),
    dueDate: "", notes: "",
  });
  const [lines, setLines] = useState([blankLine(), blankLine()]);

  const load = async () => {
    setLoading(true);
    try {
      await refreshDocumentPaymentStatuses();
      const [bs, pts, itms] = await Promise.all([listBills(), listParties(), fetchItems()]);
      setBills(bs);
      setParties(pts);
      setItems(itms);
    } catch(e) { setErr(e.message); }
    setLoading(false);
  };

  useEffect(() => { load(); }, []);

  const selectVendor = (vendorId) => {
    const p = parties.find(p => p.id === vendorId);
    if (p) setForm(f => ({ ...f, vendorId, vendorName: p.accounts?.name||"", vendorAddress: p.address||"", vendorPan: p.pan_vat_number||"" }));
    else setForm(f => ({ ...f, vendorId:"", vendorName:"", vendorAddress:"", vendorPan:"" }));
  };

  const updateLine = (i, patch) => setLines(ls => ls.map((l,idx) => idx===i ? {...l,...patch} : l));
  const addLine = () => setLines(ls => [...ls, blankLine()]);
  const removeLine = (i) => setLines(ls => ls.filter((_,idx) => idx!==i));

  const subtotal = lines.reduce((s,l) => s+calcAmount(l), 0);
  const vatTotal = lines.reduce((s,l) => s+calcVat(l), 0);
  const grandTotal = subtotal + vatTotal;

  const submit = async (e) => {
    e.preventDefault();
    if (!form.vendorName.trim()) { setErr("Vendor name is required."); return; }
    const validLines = lines.filter(l => l.description && parseFloat(l.rate));
    if (validLines.length === 0) { setErr("Add at least one line item."); return; }
    setBusy(true); setErr(null);
    try {
      const fiscalYear = currentFiscalYear();
      const billNumber = await nextBillNumber(fiscalYear);
      const postLines = validLines.map((l) => ({
        item_id: l.itemId || null,
        hsn_code: items.find((item) => item.id === l.itemId)?.hsn_code || null,
        description: l.description,
        quantity: parseFloat(l.quantity) || 1,
        unit: l.unit || "pcs",
        rate: parseFloat(l.rate) || 0,
        amount: calcAmount(l),
        vat_rate: parseFloat(l.vatRate) || VAT_RATE,
        vat_amount: calcVat(l),
        line_total: calcAmount(l) + calcVat(l),
      }));
      const header = {
        bill_number: billNumber,
        fiscal_year: fiscalYear,
        bill_date: form.billDate,
        due_date: form.dueDate || null,
        vendor_id: form.vendorId || null,
        vendor_name: form.vendorName.trim(),
        vendor_address: form.vendorAddress.trim() || null,
        vendor_pan: form.vendorPan.trim() || null,
        vendor_bill_ref: form.vendorBillRef.trim() || null,
        notes: form.notes.trim() || null,
        status: "open",
      };
      const billId = await createBillWithPosting(header, postLines);
      setShowForm(false);
      setLines([blankLine(), blankLine()]);
      setForm({ vendorId:"", vendorName:"", vendorAddress:"", vendorPan:"", vendorBillRef:"", billDate: new Date().toISOString().slice(0,10), dueDate:"", notes:"" });
      await load();
      const { data: bill } = await supabase.from("purchase_bills").select("*, purchase_bill_lines(*)").eq("id", billId).single();
      setPrintBill(bill);
    } catch(e) { setErr(e.message); }
    setBusy(false);
  };

  const filtered = filter === "all" ? bills : bills.filter(b => b.status === filter);

  const activeBills = bills.filter(b => !["cancelled", "credited"].includes(b.status));
  const totalOutstanding = activeBills.reduce((s, b) => s + Number(b.outstanding_amount ?? b.total), 0);
  const totalPaid = activeBills.reduce((s, b) => s + Number(b.amount_paid || 0), 0);
  const totalVat = activeBills.reduce((s, b) => s + Number(b.vat_amount), 0);

    if (payModal) return (
    <PaymentModal docType="bill" doc={payModal}
      onClose={()=>setPayModal(null)}
      onSaved={()=>{setPayModal(null); load();}} />
  );

  if (printBill) return <BillPrint bill={printBill} bizName={bizName} profile={profile} onClose={() => setPrintBill(null)} />;

  return (
    <div className="panel">
      <div className="panel-head">
        <h2>Purchases (खरिद)</h2>
        <button className="btn" onClick={() => setShowForm(s=>!s)}>{showForm ? "Cancel" : "+ New Bill"}</button>
      </div>

      {/* Summary stats */}
      <div className="stat-row">
        <div className="stat"><span style={{color:"var(--rust)"}}>NPR {totalOutstanding.toLocaleString()}</span>Outstanding Bills</div>
        <div className="stat"><span>NPR {totalPaid.toLocaleString()}</span>Paid Bills</div>
        <div className="stat"><span>NPR {totalVat.toLocaleString()}</span>Input VAT (claimable)</div>
        <div className="stat"><span>{bills.length}</span>Total Bills</div>
      </div>

      {showForm && (
        <form className="inv-form" onSubmit={submit}>
          <div className="inv-form-top">
            <label className="fld">Vendor
              <select value={form.vendorId} onChange={e=>selectVendor(e.target.value)}>
                <option value="">Select or type below…</option>
                {parties.filter(p=>p.party_type==="vendor"||p.party_type==="both").map(p=>(
                  <option key={p.id} value={p.id}>{p.accounts?.name}</option>
                ))}
              </select>
            </label>
            <label className="fld">Vendor Name <input placeholder="Vendor name" value={form.vendorName} onChange={e=>setForm(f=>({...f,vendorName:e.target.value}))} required /></label>
            <label className="fld">Vendor PAN <input placeholder="PAN/VAT number" value={form.vendorPan} onChange={e=>setForm(f=>({...f,vendorPan:e.target.value}))} /></label>
            <label className="fld">Vendor Address <input placeholder="Address" value={form.vendorAddress} onChange={e=>setForm(f=>({...f,vendorAddress:e.target.value}))} /></label>
            <label className="fld">Bill Date <input type="date" value={form.billDate} onChange={e=>setForm(f=>({...f,billDate:e.target.value}))} required /></label>
            <label className="fld">Due Date <input type="date" value={form.dueDate} onChange={e=>setForm(f=>({...f,dueDate:e.target.value}))} /></label>
            <label className="fld">Vendor's Bill Ref# <input placeholder="Their invoice number" value={form.vendorBillRef} onChange={e=>setForm(f=>({...f,vendorBillRef:e.target.value}))} /></label>
          </div>

          <table className="tbl inv-lines-tbl">
            <thead><tr><th>Description</th><th>Unit</th><th className="num">Qty</th><th className="num">Rate</th><th className="num">Amount</th><th className="num">VAT%</th><th className="num">VAT</th><th className="num">Total</th><th/></tr></thead>
            <tbody>
              {lines.map((l,i)=>(
                <tr key={i}>
                  <td>
                    <select style={{width:"100%",marginBottom:3}} value={l.itemId||""}
                      onChange={e=>{
                        const itm = items.find(x=>x.id===e.target.value);
                        if(itm) updateLine(i,{itemId:itm.id,description:itm.name,unit:itm.unit,rate:String(itm.average_cost || itm.cost_price)});
                        else updateLine(i,{itemId:"",description:"",unit:"pcs",rate:""});
                      }}>
                      <option value="">— type below or pick item —</option>
                      {items.map(itm=>(
                        <option key={itm.id} value={itm.id}>{itm.name} (Stock: {Number(itm.current_stock).toLocaleString()} {itm.unit})</option>
                      ))}
                    </select>
                    <input placeholder="Description" value={l.description} onChange={e=>updateLine(i,{description:e.target.value})} />
                  </td>
                  <td><input placeholder="pcs" value={l.unit} onChange={e=>updateLine(i,{unit:e.target.value})} style={{width:50}} /></td>
                  <td><input type="number" step="0.001" className="num-input" value={l.quantity} onChange={e=>updateLine(i,{quantity:e.target.value})} /></td>
                  <td><input type="number" step="0.01" className="num-input" value={l.rate} onChange={e=>updateLine(i,{rate:e.target.value})} /></td>
                  <td className="num">{calcAmount(l).toLocaleString()}</td>
                  <td><input type="number" step="0.01" className="num-input" value={l.vatRate} onChange={e=>updateLine(i,{vatRate:e.target.value})} style={{width:55}} /></td>
                  <td className="num">{calcVat(l).toLocaleString()}</td>
                  <td className="num">{(calcAmount(l)+calcVat(l)).toLocaleString()}</td>
                  <td>{lines.length>1&&<button type="button" className="link" onClick={()=>removeLine(i)}>✕</button>}</td>
                </tr>
              ))}
            </tbody>
            <tfoot>
              <tr><td colSpan={4} className="muted">Subtotal</td><td className="num"><b>{subtotal.toLocaleString()}</b></td><td></td><td className="num"><b>{vatTotal.toLocaleString()}</b></td><td className="num"><b>{grandTotal.toLocaleString()}</b></td><td/></tr>
            </tfoot>
          </table>
          <button type="button" className="link" onClick={addLine}>+ Add line</button>

          <label className="fld" style={{marginTop:12}}>Notes <input placeholder="Optional notes" value={form.notes} onChange={e=>setForm(f=>({...f,notes:e.target.value}))} /></label>
          {err && <p className="msg err">{err}</p>}
          <button className="btn" disabled={busy}>{busy?"Saving…":"Save Bill"}</button>
        </form>
      )}

      {/* Filter tabs */}
      <div className="filter-tabs">
        {["all","open","partial","overdue","paid","cancelled","credited"].map(f=>(
          <button key={f} className={"filter-tab"+(filter===f?" active":"")} onClick={()=>setFilter(f)}>
            {f.charAt(0).toUpperCase()+f.slice(1)}
          </button>
        ))}
      </div>

      {loading ? <p className="note">Loading…</p> : filtered.length === 0 ? (
        <p className="note">No bills found.</p>
      ) : (
        <table className="tbl" style={{marginTop:8}}>
          <thead><tr><th>Bill #</th><th>Date</th><th>Due</th><th>Vendor</th><th>Status</th><th className="num">Paid</th><th className="num">Outstanding</th><th className="num">Total</th><th/></tr></thead>
          <tbody>
            {filtered.map(b=>(
              <tr key={b.id}>
                <td>{b.fiscal_year}-PB-{String(b.bill_number).padStart(4,"0")}</td>
                <td>{b.bill_date}</td>
                <td className={b.status === "overdue" ? "overdue" : ""}>{b.due_date||"—"}</td>
                <td>{b.vendor_name}</td>
                <td><span className={"status-"+b.status}>{b.status}</span>{["partial", "overdue"].includes(b.status) && <div style={{fontSize:10,color:"var(--rust)",marginTop:2}}>Paid NPR {Number(b.amount_paid||0).toLocaleString()}</div>}</td>
                <td className="num">NPR {Number(b.amount_paid || 0).toLocaleString()}</td>
                <td className="num"><b>NPR {Number(b.outstanding_amount ?? b.total).toLocaleString()}</b></td>
                <td className="num">NPR {Number(b.total).toLocaleString()}</td>
                <td>
                  <button className="link" onClick={()=>setPrintBill(b)}>View</button>
                  {(["open", "partial", "overdue"].includes(b.status)) && (
                    <button className="link" onClick={()=>setPayModal(b)}>
                      {Number(b.amount_paid || 0) > 0 ? "Record More Payment" : "Record Payment"}
                    </button>
                  )}
                  {b.status==="open" && Number(b.amount_paid || 0) === 0 && <button className="link" style={{color:"var(--rust)"}} onClick={async()=>{await updateBillStatus(b.id,"cancelled");load();}}>Cancel</button>}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </div>
  );
}
