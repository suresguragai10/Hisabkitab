import React, { useState } from "react";
import { supabase } from "../supabase";
import { fiscalYearFor } from "../lib/fiscalYear";

const fmt = (n) => Number(n||0).toLocaleString(undefined,{minimumFractionDigits:2,maximumFractionDigits:2});

// ── Business type options ─────────────────────────────────────
const BIZ_TYPES = [
  { type:"trading",      icon:"🛒", label:"Retail / Trading",   desc:"Sells products, manages inventory, has suppliers and customers" },
  { type:"service",      icon:"🔧", label:"Service Business",    desc:"Sells services like consulting, repair, IT, construction" },
  { type:"restaurant",   icon:"🍽", label:"Restaurant / Food",   desc:"Food & beverage business, kitchen operations" },
  { type:"professional", icon:"💼", label:"Professional",        desc:"CA, Doctor, Lawyer, Consultant, Architect" },
];

// ── Step indicator ────────────────────────────────────────────
function StepBar({ step }) {
  const labels = ["Business Type","Your Details","Starting Balances","Done!"];
  return (
    <div className="wizard-steps">
      {labels.map((l,i) => (
        <div key={i} className={"wizard-step" + (i===step?" active":i<step?" done":"")}>
          <div className="wizard-step-dot">{i < step ? "✓" : i+1}</div>
          <div className="wizard-step-label">{l}</div>
        </div>
      ))}
    </div>
  );
}

// ── Step 1: Business Type ─────────────────────────────────────
function Step1({ value, onChange, onNext }) {
  return (
    <div className="wizard-body">
      <div className="wizard-welcome">
        <div className="wizard-logo"><span>हिसाब</span>KitabHisabKitab</div>
        <h2>Welcome! Let's set up your books.</h2>
        <p className="muted">It takes about 2 minutes. What type of business is this?</p>
      </div>
      <div className="wizard-type-grid">
        {BIZ_TYPES.map(t => (
          <div key={t.type}
            className={"wizard-type-card" + (value===t.type?" selected":"")}
            onClick={() => onChange(t.type)}>
            <div className="wizard-type-icon">{t.icon}</div>
            <div className="wizard-type-label">{t.label}</div>
            <div className="wizard-type-desc">{t.desc}</div>
          </div>
        ))}
      </div>
      <div className="wizard-footer">
        <button className="btn" onClick={onNext} disabled={!value}>
          Continue →
        </button>
      </div>
    </div>
  );
}

// ── Step 2: Business Details ──────────────────────────────────
function Step2({ form, onChange, onNext, onBack, busy, err }) {
  const set = (k,v) => onChange({...form, [k]:v});
  return (
    <div className="wizard-body">
      <h2>Tell us about your business</h2>
      <p className="muted">This appears on every invoice you print.</p>

      <div className="wizard-form">
        <label className="fld">
          Business Name (English) *
          <input placeholder="e.g. Ram Traders Pvt. Ltd." value={form.bizName}
            onChange={e=>set("bizName",e.target.value)} />
        </label>
        <label className="fld">
          Business Name (Nepali) — shown on invoices
          <input placeholder="e.g. राम ट्रेडर्स" value={form.bizNameNp}
            onChange={e=>set("bizNameNp",e.target.value)} />
        </label>
        <label className="fld">
          PAN / VAT Number *
          <input placeholder="9-digit PAN number" value={form.panVat}
            onChange={e=>set("panVat",e.target.value)} />
        </label>
        <label className="fld">
          Phone Number
          <input placeholder="+977-01-XXXXXXX" value={form.phone}
            onChange={e=>set("phone",e.target.value)} />
        </label>
        <label className="fld">
          Address
          <input placeholder="Street, Area" value={form.address}
            onChange={e=>set("address",e.target.value)} />
        </label>
        <label className="fld">
          City / District
          <input placeholder="e.g. Kathmandu" value={form.city}
            onChange={e=>set("city",e.target.value)} />
        </label>
      </div>

      {err && <p className="msg err">{err}</p>}
      <div className="wizard-footer">
        <button className="ghost-btn" onClick={onBack}>← Back</button>
        <button className="btn" onClick={onNext} disabled={busy||!form.bizName.trim()||!form.panVat.trim()}>
          {busy ? "Saving…" : "Continue →"}
        </button>
      </div>
    </div>
  );
}

// ── Step 3: Opening Balances ──────────────────────────────────
function Step3({ bizType, form, onChange, onNext, onBack, busy, err }) {
  const set = (k,v) => onChange({...form,[k]:v});
  const n = k => parseFloat(form[k])||0;

  const totalAssets = n("cash") + n("bank") + n("stock") + n("debtors");
  const totalLiab   = n("creditors");
  const capital     = totalAssets - totalLiab;
  const isBalanced  = capital > 0 || (totalAssets === 0 && totalLiab === 0);

  const isTrading = ["trading","restaurant"].includes(bizType);

  return (
    <div className="wizard-body">
      <h2>What do you start with today?</h2>
      <p className="muted">Enter your current actual balances. You can update these later in Chart of Accounts.</p>

      <div className="wizard-form">
        <label className="fld">
          Cash in hand right now (NPR)
          <input type="number" step="0.01" placeholder="0" value={form.cash}
            onChange={e=>set("cash",e.target.value)} />
        </label>
        <label className="fld">
          Money in your bank account (NPR)
          <input type="number" step="0.01" placeholder="0" value={form.bank}
            onChange={e=>set("bank",e.target.value)} />
        </label>
        {isTrading && (
          <label className="fld">
            Value of current stock / inventory (NPR)
            <input type="number" step="0.01" placeholder="0" value={form.stock}
              onChange={e=>set("stock",e.target.value)} />
          </label>
        )}
        <label className="fld">
          Money customers owe you — receivables (NPR)
          <input type="number" step="0.01" placeholder="0" value={form.debtors}
            onChange={e=>set("debtors",e.target.value)} />
        </label>
        <label className="fld">
          Money you owe suppliers — payables (NPR)
          <input type="number" step="0.01" placeholder="0" value={form.creditors}
            onChange={e=>set("creditors",e.target.value)} />
        </label>
      </div>

      {/* Live Balance Sheet Preview */}
      <div className="wizard-bs-preview">
        <div className="wizard-bs-title">Your opening Balance Sheet</div>
        <div className="wizard-bs-row"><span>Cash & Bank</span><span>NPR {fmt(n("cash")+n("bank"))}</span></div>
        {isTrading && n("stock")>0 && <div className="wizard-bs-row"><span>Stock / Inventory</span><span>NPR {fmt(n("stock"))}</span></div>}
        {n("debtors")>0 && <div className="wizard-bs-row"><span>Customers owe you</span><span>NPR {fmt(n("debtors"))}</span></div>}
        <div className="wizard-bs-divider"/>
        {n("creditors")>0 && <div className="wizard-bs-row" style={{color:"var(--rust)"}}><span>You owe suppliers</span><span>NPR {fmt(n("creditors"))}</span></div>}
        <div className="wizard-bs-row wizard-bs-capital">
          <span><b>Your Capital (auto-calculated)</b></span>
          <span><b>NPR {fmt(capital)}</b></span>
        </div>
        <div className="wizard-bs-row wizard-bs-check" style={{color:isBalanced?"var(--green2)":"var(--rust)"}}>
          <span>{isBalanced ? "✓ Balance Sheet will balance" : "⚠ Capital cannot be negative"}</span>
        </div>
      </div>

      {err && <p className="msg err">{err}</p>}
      <div className="wizard-footer">
        <button className="ghost-btn" onClick={onBack}>← Back</button>
        <button className="btn" onClick={onNext} disabled={busy||!isBalanced}>
          {busy ? "Setting up…" : "Finish Setup →"}
        </button>
      </div>
    </div>
  );
}

// ── Step 4: Done ──────────────────────────────────────────────
function Step4({ bizName, onDone }) {
  return (
    <div className="wizard-body wizard-done">
      <div className="wizard-confetti">🎉</div>
      <h2>Your books are ready!</h2>
      <p className="muted"><b>{bizName}</b> is all set up and your opening Balance Sheet is balanced.</p>

      <div className="wizard-done-checks">
        {[
          "Business profile saved",
          "Chart of accounts set up",
          "Opening balances entered",
          "Balance Sheet is balanced",
          "Ready to create invoices",
        ].map(c=>(
          <div key={c} className="wizard-done-check">
            <span className="wizard-done-tick">✓</span> {c}
          </div>
        ))}
      </div>

      <div className="wizard-done-actions">
        <button className="btn" style={{fontSize:15,padding:"12px 28px"}} onClick={()=>onDone("invoices")}>
          Create First Invoice →
        </button>
        <button className="ghost-btn" onClick={()=>onDone("dashboard")}>Go to Dashboard</button>
      </div>
    </div>
  );
}

// ── Main wizard ───────────────────────────────────────────────
export default function SetupWizard({ onComplete }) {
  const [step,    setStep]    = useState(0);
  const [bizType, setBizType] = useState("");
  const [bizForm, setBizForm] = useState({
    bizName:"", bizNameNp:"", panVat:"", phone:"", address:"", city:"",
  });
  const [balForm, setBalForm] = useState({
    cash:"", bank:"", stock:"", debtors:"", creditors:"",
  });
  const [busy, setBusy] = useState(false);
  const [err,  setErr]  = useState(null);

  const saveBizDetails = async () => {
    setBusy(true); setErr(null);
    try {
      const { error } = await supabase.rpc("complete_onboarding", {
        p_biz_name:    bizForm.bizName.trim(),
        p_biz_name_np: bizForm.bizNameNp.trim(),
        p_address:     bizForm.address.trim(),
        p_city:        bizForm.city.trim(),
        p_pan_vat:     bizForm.panVat.trim(),
        p_phone:       bizForm.phone.trim(),
        p_biz_type:    bizType,
      });
      if (error) throw error;
      setStep(2);
    } catch(e) { setErr(e.message); }
    setBusy(false);
  };

  const saveBalances = async () => {
    setBusy(true); setErr(null);
    try {
      const n = (key) => parseFloat(balForm[key]) || 0;
      if (n("stock") > 0.005) {
        throw new Error("Opening stock must be entered item-by-item from Inventory so quantity and value remain reconciled.");
      }

      const { error: seedError } = await supabase.rpc("seed_default_accounts");
      if (seedError) throw seedError;
      const { data: systemAccounts, error: accountError } = await supabase
        .from("accounts")
        .select("id,system_code,account_subtype")
        .or("system_code.in.(cash,bank,ar_control,ap_control),account_subtype.eq.capital")
        .eq("is_active", true);
      if (accountError) throw accountError;

      const byCode = Object.fromEntries((systemAccounts || []).filter((a) => a.system_code).map((a) => [a.system_code, a.id]));
      const capitalId = systemAccounts?.find((a) => a.account_subtype === "capital")?.id;
      const lines = [];
      const addDebit = (accountId, amount, description) => {
        if (amount > 0.005) lines.push({ account_id: accountId, debit: amount, credit: 0, description });
      };
      const addCredit = (accountId, amount, description) => {
        if (amount > 0.005) lines.push({ account_id: accountId, debit: 0, credit: amount, description });
      };
      addDebit(byCode.cash, n("cash"), "Opening cash");
      addDebit(byCode.bank, n("bank"), "Opening bank");
      addDebit(byCode.ar_control, n("debtors"), "Opening receivables control");
      addCredit(byCode.ap_control, n("creditors"), "Opening payables control");

      const totalDebit = lines.reduce((sum, line) => sum + line.debit, 0);
      const totalCredit = lines.reduce((sum, line) => sum + line.credit, 0);
      const difference = Number((totalDebit - totalCredit).toFixed(2));
      if (Math.abs(difference) > 0.005) {
        if (!capitalId) throw new Error("Capital Account was not found.");
        if (difference > 0) addCredit(capitalId, difference, "Opening capital");
        else addDebit(capitalId, -difference, "Opening deficit");
      }

      if (lines.length > 0) {
        const date = new Date().toISOString().slice(0, 10);
        const { error } = await supabase.rpc("post_opening_journal", {
          p_fiscal_year: fiscalYearFor(new Date()),
          p_date: date,
          p_lines: lines,
          p_notes: "Opening balances entered during setup",
        });
        if (error) throw error;
      }
      setStep(3);
    } catch(e) { setErr(e.message); }
    setBusy(false);
  };

  return (
    <div className="wizard-overlay">
      <div className="wizard-card">
        <StepBar step={step} />
        {step===0 && <Step1 value={bizType} onChange={setBizType} onNext={()=>setStep(1)} />}
        {step===1 && <Step2 form={bizForm} onChange={setBizForm} onNext={saveBizDetails} onBack={()=>setStep(0)} busy={busy} err={err} />}
        {step===2 && <Step3 bizType={bizType} form={balForm} onChange={setBalForm} onNext={saveBalances} onBack={()=>setStep(1)} busy={busy} err={err} />}
        {step===3 && <Step4 bizName={bizForm.bizName} onDone={onComplete} />}
      </div>
    </div>
  );
}
