import React, { useState, useEffect } from "react";
import { supabase } from "./supabase";
import { seedDefaultAccountsIfNeeded } from "./lib/db";
import Dashboard from "./pages/Dashboard";
import ChartOfAccounts from "./pages/ChartOfAccounts";
import Parties from "./pages/Parties";
import VoucherEntry from "./pages/VoucherEntry";
import VoucherList from "./pages/VoucherList";
import Ledger from "./pages/Ledger";

export default function App() {
  const [loading, setLoading] = useState(true);
  const [session, setSession] = useState(null);

  useEffect(() => {
    // get existing session on load
    supabase.auth.getSession().then(({ data }) => {
      setSession(data.session);
      setLoading(false);
    });
    // listen for auth changes (login / logout / token refresh)
    const { data: sub } = supabase.auth.onAuthStateChange((_event, s) => {
      setSession(s);
    });
    return () => sub.subscription.unsubscribe();
  }, []);

  if (loading) return <Splash />;
  if (!session) return <Login />;
  return <Authed session={session} />;
}

function Splash() {
  return (
    <div className="wrap center">
      <Style />
      <div className="logo big"><span>हिसाब</span>HisabKitab</div>
    </div>
  );
}

function Login() {
  const [step, setStep] = useState("email"); // 'email' | 'code'
  const [email, setEmail] = useState("");
  const [code, setCode] = useState("");
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState(null);
  const [err, setErr] = useState(null);

  const sendCode = async () => {
    setErr(null); setMsg(null);
    const e = email.trim().toLowerCase();
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(e)) { setErr("Enter a valid email address."); return; }
    setBusy(true);
    const { error } = await supabase.auth.signInWithOtp({
      email: e,
      options: { shouldCreateUser: true }, // create the account on first login
    });
    setBusy(false);
    if (error) { setErr(error.message); return; }
    setStep("code");
    setMsg("We sent a 6-digit code to " + e + ". Check your inbox (and spam).");
  };

  const verify = async () => {
    setErr(null);
    const token = code.trim();
    if (token.length < 6) { setErr("Enter the 6-digit code."); return; }
    setBusy(true);
    const { error } = await supabase.auth.verifyOtp({
      email: email.trim().toLowerCase(),
      token,
      type: "email",
    });
    setBusy(false);
    if (error) { setErr(error.message); return; }
    // onAuthStateChange will flip us into the app automatically
  };

  return (
    <div className="wrap center">
      <Style />
      <div className="card">
        <div className="logo"><span>हिसाब</span>HisabKitab</div>
        <p className="sub">Cloud accounting for Nepali business. Sign in with your email — no password needed.</p>

        {step === "email" && (
          <>
            <label className="fld">Email address
              <input type="email" value={email} placeholder="you@example.com"
                onChange={(e) => setEmail(e.target.value)}
                onKeyDown={(e) => e.key === "Enter" && sendCode()} autoFocus />
            </label>
            <button className="btn full" onClick={sendCode} disabled={busy}>
              {busy ? "Sending…" : "Send login code"}
            </button>
          </>
        )}

        {step === "code" && (
          <>
            <label className="fld">6-digit code
              <input inputMode="numeric" value={code} placeholder="123456"
                onChange={(e) => setCode(e.target.value.replace(/\D/g, "").slice(0, 6))}
                onKeyDown={(e) => e.key === "Enter" && verify()} autoFocus />
            </label>
            <button className="btn full" onClick={verify} disabled={busy}>
              {busy ? "Verifying…" : "Verify & sign in"}
            </button>
            <button className="link" onClick={() => { setStep("email"); setCode(""); setMsg(null); setErr(null); }}>
              ← Use a different email
            </button>
            <button className="link" onClick={sendCode} disabled={busy}>Resend code</button>
          </>
        )}

        {msg && <p className="msg ok">{msg}</p>}
        {err && <p className="msg err">{err}</p>}
        <p className="note">Codes may take a minute and can land in spam. On the free tier, only a few emails per hour can be sent.</p>
      </div>
    </div>
  );
}

const TABS = [
  { key: "dashboard", label: "Dashboard" },
  { key: "vouchers", label: "Vouchers" },
  { key: "ledger", label: "Ledger" },
  { key: "parties", label: "Parties" },
  { key: "accounts", label: "Chart of Accounts" },
];

function Authed({ session }) {
  const userId = session.user.id;
  const [busy, setBusy] = useState(false);
  const [tab, setTab] = useState("dashboard");
  const [seeding, setSeeding] = useState(true);
  const [seedErr, setSeedErr] = useState(null);
  const [refreshKey, setRefreshKey] = useState(0);

  const signOut = async () => { setBusy(true); await supabase.auth.signOut(); setBusy(false); };
  const bump = () => setRefreshKey((k) => k + 1);

  useEffect(() => {
    seedDefaultAccountsIfNeeded()
      .catch((e) => setSeedErr(e.message))
      .finally(() => setSeeding(false));
  }, [userId]);

  return (
    <div className="wrap">
      <Style />
      <header className="top">
        <div className="logo"><span>हिसाब</span>HisabKitab</div>
        <nav className="tabs">
          {TABS.map((t) => (
            <button key={t.key} className={"tab" + (tab === t.key ? " active" : "")} onClick={() => setTab(t.key)}>
              {t.label}
            </button>
          ))}
        </nav>
        <button className="ghost" onClick={signOut} disabled={busy}>Sign out</button>
      </header>
      <main className="app-main">
        {seeding && <p className="note">Setting up your books…</p>}
        {seedErr && <p className="msg err">Couldn't set up default accounts: {seedErr}</p>}
        {!seeding && (
          <>
            {tab === "dashboard" && <Dashboard refreshKey={refreshKey} />}
            {tab === "vouchers" && (
              <>
                <VoucherEntry userId={userId} onSaved={bump} />
                <VoucherList refreshKey={refreshKey} />
              </>
            )}
            {tab === "ledger" && <Ledger />}
            {tab === "parties" && <Parties userId={userId} onChanged={bump} />}
            {tab === "accounts" && <ChartOfAccounts userId={userId} onChanged={bump} />}
          </>
        )}
      </main>
    </div>
  );
}

function Style() {
  return <style>{`
  :root{--ink:#10211b;--ink2:#3a4f47;--paper:#f6f4ec;--card:#fffdf7;--line:#e2ddcd;--green:#1f6f54;--green2:#15543f;--gold:#b9892f;--rust:#a23b22;}
  *{box-sizing:border-box}
  body{margin:0}
  .wrap{font-family:'Inter','Segoe UI',system-ui,sans-serif;color:var(--ink);background:radial-gradient(1200px 400px at 80% -10%,#eef3ec 0,transparent 60%),var(--paper);min-height:100vh}
  .center{display:flex;align-items:center;justify-content:center;padding:20px}
  .center.col{flex-direction:column}
  .logo{font-family:Georgia,serif;font-size:24px;display:flex;align-items:center;gap:10px;font-weight:700}
  .logo span{background:var(--gold);color:#211c0e;padding:4px 9px;border-radius:8px;font-size:18px}
  .logo.big{font-size:32px}
  .card{background:var(--card);border:1px solid var(--line);border-radius:18px;padding:30px;max-width:400px;width:100%;box-shadow:0 18px 50px #10211b14}
  .card.wide{max-width:560px}
  .sub{color:var(--ink2);font-size:14px;margin:12px 0 18px}
  .fld{display:flex;flex-direction:column;gap:6px;font-size:13px;color:var(--ink2);font-weight:600;margin-bottom:14px}
  input{font-family:inherit;font-size:16px;padding:11px 13px;border:1px solid var(--line);border-radius:10px;background:#fff;color:var(--ink);width:100%}
  input:focus{outline:2px solid #1f6f5555;border-color:var(--green)}
  .btn{background:var(--green);color:#fff;border:none;padding:12px 16px;border-radius:10px;font-size:15px;cursor:pointer}
  .btn:hover{background:var(--green2)}.btn:disabled{opacity:.5;cursor:default}
  .btn.full{width:100%}
  .link{display:block;background:none;border:none;color:var(--green);cursor:pointer;font-size:13px;margin:10px auto 0;text-align:center}
  .msg{font-size:13px;padding:10px 12px;border-radius:9px;margin-top:14px}
  .msg.ok{background:#1f6f5414;color:var(--green2)}
  .msg.err{background:#a23b2214;color:var(--rust)}
  .note{font-size:11.5px;color:#9a9483;margin-top:14px;line-height:1.5}
  .top{display:flex;justify-content:space-between;align-items:center;padding:14px 22px;background:var(--green2);color:#f3efe2}
  .ghost{background:transparent;border:1px solid #ffffff55;color:#f3efe2;padding:8px 14px;border-radius:8px;cursor:pointer}
  h1{font-family:Georgia,serif;font-size:24px;margin:0}
  .idbox{margin-top:18px;border-top:1px solid var(--line);padding-top:14px;display:flex;flex-direction:column;gap:8px}
  .idbox div{display:flex;justify-content:space-between;gap:12px;font-size:12.5px;color:var(--ink2)}
  .idbox code{font-family:ui-monospace,monospace;font-size:11.5px;background:#00000008;padding:3px 7px;border-radius:6px;word-break:break-all;text-align:right}

  /* ---- App shell (Phase 6b) ---- */
  .top{flex-wrap:wrap;gap:10px}
  .tabs{display:flex;gap:4px;flex-wrap:wrap}
  .tab{background:transparent;border:1px solid #ffffff2a;color:#dcd6c3;padding:7px 13px;border-radius:8px;cursor:pointer;font-size:13px}
  .tab:hover{background:#ffffff14}
  .tab.active{background:#f3efe2;color:var(--green2);font-weight:700}
  .app-main{max-width:1080px;margin:0 auto;padding:22px 18px 60px;display:flex;flex-direction:column;gap:20px}
  .panel{background:var(--card);border:1px solid var(--line);border-radius:16px;padding:22px;box-shadow:0 12px 34px #10211b0f}
  .panel-head{display:flex;justify-content:space-between;align-items:center;margin-bottom:16px;gap:12px;flex-wrap:wrap}
  .panel-head h2{font-family:Georgia,serif;margin:0;font-size:20px}
  .sub-head{font-size:14px;margin:18px 0 8px;color:var(--ink2)}

  .inline-form{display:flex;flex-wrap:wrap;gap:10px;margin-bottom:18px;align-items:center}
  .inline-form input, .inline-form select{width:auto;flex:1 1 140px}
  .grid-form{display:grid;grid-template-columns:repeat(2,1fr);gap:10px;margin-bottom:18px}
  .grid-form .wide-field{grid-column:1 / -1}
  .grid-form input, .grid-form select{width:100%}
  .wide-field{flex:1 1 100%}

  .tbl{width:100%;border-collapse:collapse;font-size:13.5px}
  .tbl th{text-align:left;font-size:11.5px;text-transform:uppercase;letter-spacing:.04em;color:#9a9483;padding:8px 10px;border-bottom:1px solid var(--line)}
  .tbl td{padding:9px 10px;border-bottom:1px solid #10211b0d;vertical-align:top}
  .tbl tfoot td{border-top:2px solid var(--line);border-bottom:none;font-weight:600}
  .tbl .num{text-align:right;font-variant-numeric:tabular-nums}
  .tbl select, .tbl input{width:100%}
  .num-input{text-align:right}
  .muted{color:var(--ink2)}
  .tag{display:inline-block;margin-left:8px;font-size:10.5px;background:#1f6f5414;color:var(--green2);padding:2px 7px;border-radius:6px}
  .tag-void{background:#a23b2214;color:var(--rust)}
  tr.voided{opacity:.55;text-decoration:line-through}

  .acct-group{margin-bottom:16px}
  .acct-group-title{font-size:12px;font-weight:700;color:var(--gold);text-transform:uppercase;letter-spacing:.05em;margin-bottom:6px}

  .voucher-header{display:flex;gap:14px;flex-wrap:wrap;margin-bottom:16px}
  .voucher-header .fld{flex:1 1 160px}
  .voucher-lines{margin-bottom:10px}
  .voucher-actions{margin-top:14px}
  .msg-inline{font-size:12px}
  .msg-inline.err{color:var(--rust)}

  .stat-row{display:flex;gap:14px;flex-wrap:wrap;margin-bottom:8px}
  .stat{flex:1 1 130px;background:#10211b08;border-radius:12px;padding:14px;text-align:center}
  .stat span{display:block;font-size:24px;font-weight:700;color:var(--green2);font-family:Georgia,serif}
  `}</style>;
}
