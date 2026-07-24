import React, { useState, useEffect, Component } from "react";
import { supabase, diagnoseAuthServer } from "./supabase";
import { seedDefaultAccountsIfNeeded, checkRateLimit, logRateLimit, listAuditLog } from "./lib/db";
import { getLang, setLang, t } from "./lib/i18n";
import { formatBs } from "./lib/nepaliCalendar";

// ── Global tab error boundary — shows the real error instead of a
//    blank page when any single tab/page crashes. Key it by `tab`
//    so switching tabs clears the error and tries a fresh render. ──
class TabErrorBoundary extends Component {
  constructor(props) { super(props); this.state = { err: null }; }
  static getDerivedStateFromError(err) { return { err }; }
  render() {
    if (this.state.err) {
      return (
        <div className="msg err" style={{margin:"20px 0",whiteSpace:"pre-wrap"}}>
          <b>This page hit an error:</b><br/>
          {this.state.err.message}
          <div style={{marginTop:10,fontSize:12,color:"#555"}}>
            Try switching to another tab and back. If this keeps happening,
            copy this message and share it.
          </div>
        </div>
      );
    }
    return this.props.children;
  }
}

import Dashboard from "./pages/Dashboard";
import TeamMembers from "./pages/TeamMembers";
import TDS from "./pages/TDS";
import VatFiling from "./pages/VatFiling";
import BankReconciliation from "./pages/BankReconciliation";
import Settings from "./pages/Settings";
import CreditDebitNotes from "./pages/CreditDebitNotes";
import SetupWizard from "./pages/SetupWizard";
import { WorkspaceContext, useWorkspaceProvider, NAV_ACCESS } from "./lib/workspace";
import ChartOfAccounts from "./pages/ChartOfAccounts";
import Parties from "./pages/Parties";
import Contacts from "./pages/Contacts";
import Items from "./pages/Items";
import ItemCategories from "./pages/ItemCategories";
import VoucherEntry from "./pages/VoucherEntry";
import VoucherList from "./pages/VoucherList";
import AuditLog from "./pages/AuditLog";
import Invoices from "./pages/Invoices";
import Purchases from "./pages/Purchases";
import Inventory from "./pages/Inventory";
import Reports from "./pages/Reports";
import Ledger from "./pages/Ledger";

// ── Root ──────────────────────────────────────────────────────
export default function App() {
  const [loading, setLoading] = useState(true);
  const [session, setSession] = useState(null);
  const [needsPassword, setNeedsPassword] = useState(false);
  const [recoveryPending, setRecoveryPending] = useState(false);
  const [lang, setLangState] = useState(getLang());

  const toggleLang = () => {
    const next = lang === "en" ? "np" : "en";
    setLang(next);
    setLangState(next);
  };


  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => {
      const s = data.session;
      setSession(s);
      if (s) checkNeedsPassword(s);
      else setLoading(false);
    });
    const { data: sub } = supabase.auth.onAuthStateChange((_event, s) => {
      setSession(s);
      if (s) checkNeedsPassword(s);
      else { setLoading(false); setNeedsPassword(false); setRecoveryPending(false); }
    });
    return () => sub.subscription.unsubscribe();
  }, []);

  // A user "needs password" if they logged in via OTP and have never set one.
  // Supabase stores this as user_metadata.has_password.
  const checkNeedsPassword = (s) => {
    const meta = s?.user?.user_metadata || {};
    setNeedsPassword(!meta.has_password);
    setLoading(false);
  };

  const onPasswordSet = async () => {
    // Refresh session metadata so the flag is updated
    const { data } = await supabase.auth.getUser();
    const meta = data?.user?.user_metadata || {};
    setNeedsPassword(!meta.has_password);
  };

  if (loading) return <Splash />;
  if (!session) return <Login onRecoveryPendingChange={setRecoveryPending} />;
  if (needsPassword || recoveryPending) {
    return (
      <SetPassword
        recovery={recoveryPending}
        onDone={() => { setRecoveryPending(false); onPasswordSet(); }}
      />
    );
  }
  return <Authed session={session} lang={lang} toggleLang={toggleLang} />;
}

// ── Splash ────────────────────────────────────────────────────
function Splash() {
  return (
    <div className="wrap center">
      <Style />
      <div className="logo big"><span>हिसाब</span>HisabKitab</div>
    </div>
  );
}

// Translate low-level failures after independently checking the live Auth API.
async function authErrorMessage(error) {
  if (!error) return "Unable to sign in. Please try again.";

  const message = error.message || "";
  const code = error.code || "";
  const needsConnectionCheck =
    error.name === "AuthRetryableFetchError" ||
    error.name === "AuthInvalidTokenResponseError" ||
    message === "Auth session or user missing" ||
    /fetch failed|failed to fetch|network|offline|load failed/i.test(message);

  if (!needsConnectionCheck) {
    return message || code || "Unable to sign in. Please try again.";
  }

  const diagnostic = await diagnoseAuthServer();

  if (diagnostic.kind === "configuration") {
    return diagnostic.message;
  }

  if (diagnostic.kind === "timeout") {
    return `The Supabase server ${diagnostic.host} did not respond within 12 seconds. Check whether the project is paused and whether your network blocks supabase.co.`;
  }

  if (diagnostic.kind === "network") {
    return `Your browser cannot connect to ${diagnostic.host}. Verify the Project URL in src/config.js, then check DNS, firewall, VPN, ad-blocker, or ISP blocking. Browser detail: ${diagnostic.browserMessage || "network request failed"}`;
  }

  if (diagnostic.kind === "malformed") {
    return `A cache, proxy, or browser extension replaced the Supabase response. Remove all site data for this website and open it again. Response detail: ${diagnostic.serverMessage || "unexpected response"}`;
  }

  if (diagnostic.kind === "http") {
    if (diagnostic.status === 401 || diagnostic.status === 403) {
      return "Supabase rejected the API key. Copy the current Project URL and Publishable key from Supabase Dashboard → Connect into src/config.js, rebuild, and redeploy.";
    }
    if (diagnostic.status === 404) {
      return "The Supabase project URL does not point to an active Auth API. Copy the exact Project URL from Supabase Dashboard → Connect into src/config.js.";
    }
    if ([500, 502, 503, 504, 520, 522, 524, 540, 544].includes(diagnostic.status)) {
      return `The Supabase project is paused or unhealthy (HTTP ${diagnostic.status}). Restore/check the project in the Supabase Dashboard, then try again.`;
    }
    return `Supabase Auth returned HTTP ${diagnostic.status}${diagnostic.serverMessage ? `: ${diagnostic.serverMessage}` : "."}`;
  }

  if (diagnostic.ok && (error.name === "AuthInvalidTokenResponseError" || message === "Auth session or user missing")) {
    return "The Auth server is reachable, but the login response is being altered before Supabase receives it. Clear this website's storage, disable request-modifying browser extensions, and reload.";
  }

  if (diagnostic.ok) {
    return `${message || "Authentication failed."} The Auth server itself is reachable.`;
  }

  return message || "Unable to sign in. Please try again.";
}

// ── Login — email+password with OTP fallback ──────────────────
function Login({ onRecoveryPendingChange }) {
  const [mode, setMode] = useState("password"); // 'password' | 'otp' | 'forgot'
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [code, setCode] = useState("");
  const [step, setStep] = useState("email"); // for OTP: 'email' | 'code'
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState(null);
  const [err, setErr] = useState(null);

  const reset = () => { setErr(null); setMsg(null); };

  // ── Password login ──
  const loginWithPassword = async () => {
    reset();
    if (!email.trim()) { setErr("Enter your email."); return; }
    if (!password) { setErr("Enter your password."); return; }
    const e = email.trim().toLowerCase();
    const allowed = await checkRateLimit(e, "login_attempt");
    if (!allowed) { setErr("Too many failed attempts. Please wait 15 minutes."); return; }
    setBusy(true);
    const { error } = await supabase.auth.signInWithPassword({ email: e, password });
    await logRateLimit(e, "login_attempt", !error);
    setBusy(false);
    if (error) setErr(await authErrorMessage(error));
  };

  // ── OTP send ──
  const sendOtp = async () => {
    reset();
    const e = email.trim().toLowerCase();
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(e)) { setErr("Enter a valid email."); return; }
    const allowed = await checkRateLimit(e, "otp_request");
    if (!allowed) { setErr("Too many requests. Please wait 15 minutes before trying again."); return; }
    setBusy(true);
    const { error } = await supabase.auth.signInWithOtp({ email: e, options: { shouldCreateUser: true } });
    await logRateLimit(e, "otp_request", !error);
    setBusy(false);
    if (error) { setErr(await authErrorMessage(error)); return; }
    setStep("code");
    setMsg("6-digit code sent to " + e + ". Check inbox and spam.");
  };

  // ── OTP verify ──
  const verifyOtp = async () => {
    reset();
    const token = code.trim();
    if (token.length < 6) { setErr("Enter the 6-digit code."); return; }
    setBusy(true);
    const { error } = await supabase.auth.verifyOtp({
      email: email.trim().toLowerCase(), token, type: "email",
    });
    setBusy(false);
    if (error) setErr(await authErrorMessage(error));
  };

  // ── Forgot password (sends OTP to reset) ──
  const sendReset = async () => {
    reset();
    const e = email.trim().toLowerCase();
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(e)) { setErr("Enter a valid email."); return; }
    setBusy(true);
    const { error } = await supabase.auth.signInWithOtp({ email: e, options: { shouldCreateUser: false } });
    setBusy(false);
    if (error) { setErr(await authErrorMessage(error)); return; }
    onRecoveryPendingChange?.(true);
    setStep("code");
    setMsg("Reset code sent to " + e + ". Enter it to log in, then set a new password.");
  };

  return (
    <div className="wrap center">
      <Style />
      <div className="card">
        <div className="logo"><span>हिसाब</span>HisabKitab</div>
        <p className="sub">Cloud accounting for Nepali business.</p>

        {/* ── Password mode ── */}
        {mode === "password" && (
          <>
            <label className="fld">Email
              <input type="email" value={email} placeholder="you@example.com"
                onChange={e => setEmail(e.target.value)}
                onKeyDown={e => e.key === "Enter" && loginWithPassword()} autoFocus />
            </label>
            <label className="fld">Password
              <input type="password" value={password} placeholder="Your password"
                onChange={e => setPassword(e.target.value)}
                onKeyDown={e => e.key === "Enter" && loginWithPassword()} />
            </label>
            <button className="btn full" onClick={loginWithPassword} disabled={busy}>
              {busy ? "Signing in…" : "Sign in"}
            </button>
            <button className="link" onClick={() => { setMode("forgot"); setStep("email"); reset(); }}>
              Forgot password?
            </button>
            <button className="link" onClick={() => { setMode("otp"); setStep("email"); reset(); }}>
              Sign in with OTP code instead
            </button>
          </>
        )}

        {/* ── OTP mode ── */}
        {mode === "otp" && step === "email" && (
          <>
            <label className="fld">Email
              <input type="email" value={email} placeholder="you@example.com"
                onChange={e => setEmail(e.target.value)}
                onKeyDown={e => e.key === "Enter" && sendOtp()} autoFocus />
            </label>
            <button className="btn full" onClick={sendOtp} disabled={busy}>
              {busy ? "Sending…" : "Send login code"}
            </button>
            <button className="link" onClick={() => { setMode("password"); reset(); }}>← Back to password</button>
          </>
        )}
        {mode === "otp" && step === "code" && (
          <>
            <label className="fld">6-digit code
              <input inputMode="numeric" value={code} placeholder="123456"
                onChange={e => setCode(e.target.value.replace(/\D/g,"").slice(0,6))}
                onKeyDown={e => e.key === "Enter" && verifyOtp()} autoFocus />
            </label>
            <button className="btn full" onClick={verifyOtp} disabled={busy}>
              {busy ? "Verifying…" : "Verify & sign in"}
            </button>
            <button className="link" onClick={() => { setStep("email"); setCode(""); reset(); }}>← Change email</button>
            <button className="link" onClick={sendOtp} disabled={busy}>Resend code</button>
          </>
        )}

        {/* ── Forgot password mode ── */}
        {mode === "forgot" && step === "email" && (
          <>
            <p className="sub">Enter your email to receive a login code. After signing in you can set a new password.</p>
            <label className="fld">Email
              <input type="email" value={email} placeholder="you@example.com"
                onChange={e => setEmail(e.target.value)}
                onKeyDown={e => e.key === "Enter" && sendReset()} autoFocus />
            </label>
            <button className="btn full" onClick={sendReset} disabled={busy}>
              {busy ? "Sending…" : "Send reset code"}
            </button>
            <button className="link" onClick={() => { onRecoveryPendingChange?.(false); setMode("password"); reset(); }}>← Back to sign in</button>
          </>
        )}
        {mode === "forgot" && step === "code" && (
          <>
            <label className="fld">6-digit code
              <input inputMode="numeric" value={code} placeholder="123456"
                onChange={e => setCode(e.target.value.replace(/\D/g,"").slice(0,6))}
                onKeyDown={e => e.key === "Enter" && verifyOtp()} autoFocus />
            </label>
            <button className="btn full" onClick={verifyOtp} disabled={busy}>
              {busy ? "Verifying…" : "Verify & continue"}
            </button>
            <button className="link" onClick={() => { setStep("email"); setCode(""); reset(); }}>← Change email</button>
          </>
        )}

        {msg && <p className="msg ok">{msg}</p>}
        {err && <p className="msg err">{err}</p>}
      </div>
    </div>
  );
}

// ── Set Password — shown after first OTP login ────────────────
function SetPassword({ onDone, recovery = false }) {
  const [password, setPassword] = useState("");
  const [confirm, setConfirm] = useState("");
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState(null);
  const [ok, setOk] = useState(false);

  const save = async () => {
    setErr(null);
    if (password.length < 8) { setErr("Password must be at least 8 characters."); return; }
    if (password !== confirm) { setErr("Passwords do not match."); return; }
    setBusy(true);
    const { error } = await supabase.auth.updateUser({
      password,
      data: { has_password: true },
    });
    setBusy(false);
    if (error) { setErr(await authErrorMessage(error)); return; }
    setOk(true);
    setTimeout(onDone, 1500);
  };

  return (
    <div className="wrap center">
      <Style />
      <div className="card">
        <div className="logo"><span>हिसाब</span>HisabKitab</div>
        <h2 style={{marginTop:16,marginBottom:4}}>{recovery ? "Set New Password" : "Set your password"}</h2>
        <p className="sub">
          {recovery
            ? "Enter a new password to finish resetting your account."
            : "You only do this once. Next time you can log in with email + password directly."}
        </p>
        {ok ? (
          <p className="msg ok">✓ Password saved! Taking you to your books…</p>
        ) : (
          <>
            <label className="fld">New password
              <input type="password" value={password} placeholder="Min 8 characters"
                onChange={e => setPassword(e.target.value)} autoFocus />
            </label>
            <label className="fld">Confirm password
              <input type="password" value={confirm} placeholder="Repeat password"
                onChange={e => setConfirm(e.target.value)}
                onKeyDown={e => e.key === "Enter" && save()} />
            </label>
            {err && <p className="msg err">{err}</p>}
            <button className="btn full" onClick={save} disabled={busy}>
              {busy ? "Saving…" : "Set password & continue"}
            </button>
            {!recovery && <button className="link" onClick={onDone}>Skip for now</button>}
          </>
        )}
      </div>
    </div>
  );
}

// ── Main app ──────────────────────────────────────────────────
const NAV_SECTIONS = [
  { section: "Overview", tabs: [
    { key: "dashboard", i18n: "dashboard", icon: "🏠", access: ()=>true },
  ]},
  { section: "Sales", tabs: [
    { key: "invoices",  i18n: "invoices",  icon: "🧾", access: ()=>true },
    { key: "notes",     i18n: "notes",     icon: "↩",  label: "Credit/Debit Notes", access: r=>["owner","accountant","staff"].includes(r) },
  ]},
  { section: "Purchases", tabs: [
    { key: "purchases", i18n: "purchases", icon: "🛒", access: ()=>true },
  ]},
  // P3 Masters Unification — "Contacts" replaces "Parties" and gets its
  // own section. "Items" splits from Inventory: the master lives here,
  // controlled stock movement and reconciliation UI stays in Inventory.
  { section: "Contacts", tabs: [
    { key: "contacts", i18n: "contacts", icon: "👥", label: "Contacts", access: ()=>true },
  ]},
  { section: "Items & Stock", tabs: [
    { key: "items",       i18n: "items",       icon: "🏷",  label: "Items",      access: ()=>true },
    { key: "categories",  i18n: "categories",  icon: "🗂",  label: "Categories", access: ()=>true },
    { key: "inventory",   i18n: "inventory",   icon: "📦",  access: ()=>true },
  ]},
  { section: "Accounting", tabs: [
    { key: "vouchers", i18n: "vouchers",        icon: "📝", access: r=>["owner","accountant"].includes(r) },
    { key: "ledger",   i18n: "ledger",          icon: "📖", access: r=>["owner","accountant","viewer"].includes(r) },
    { key: "accounts", i18n: "chartOfAccounts", icon: "📚", label: "Chart of Accounts", access: r=>["owner","accountant"].includes(r) },
    { key: "recon",    i18n: "recon",           icon: "🏦", label: "Bank Reconciliation", access: r=>["owner","accountant"].includes(r) },
  ]},
  { section: "Reports & Compliance", tabs: [
    { key: "reports", i18n: "reports", icon: "📊", access: r=>["owner","accountant","viewer"].includes(r) },
    { key: "vat",     i18n: "vat",     icon: "🧾", label: "VAT Filing", access: r=>["owner","accountant","viewer"].includes(r) },
    { key: "tds",     i18n: "tds",     icon: "📋", label: "TDS", access: r=>["owner","accountant"].includes(r) },
    { key: "audit",   i18n: "auditLog", icon: "🔒", label: "Audit Log", access: r=>["owner","accountant"].includes(r) },
  ]},
  { section: "Admin", tabs: [
    { key: "team",     i18n: "team",     icon: "🧑‍💼", label: "Team", access: r=>r==="owner" },
    { key: "settings", i18n: "settings", icon: "⚙",  label: "Settings", access: r=>["owner","accountant"].includes(r) },
  ]},
];

// Flat list retained for any code that still needs ALL_TABS shape
const ALL_TABS = NAV_SECTIONS.flatMap(s => s.tabs);

function Authed({ session, lang, toggleLang }) {
  const userId = session.user.id;
  const [busy, setBusy] = useState(false);
  const [tab, setTab] = useState("dashboard");
  const [sidebarOpen, setSidebarOpen] = useState(false);
  const [seeding, setSeeding] = useState(true);
  const [seedErr, setSeedErr] = useState(null);
  const [refreshKey, setRefreshKey] = useState(0);
  const workspace = useWorkspaceProvider();
  const role = workspace.role;
  const [onboarding, setOnboarding] = useState(null); // null=loading, true=show, false=done

  const signOut = async () => { setBusy(true); await supabase.auth.signOut(); setBusy(false); };
  const bump = () => setRefreshKey((k) => k + 1);

  // Today in BS for header display
  const todayBs = formatBs(new Date(), lang);

  // Detect invite token in URL — placed here so workspace hook is available
  useEffect(() => {
    const token = new URLSearchParams(window.location.search).get("invite");
    if (!token) return;
    workspace.acceptInvite(token)
      .then(biz => {
        alert("Welcome! You now have access to " + biz + ". Reloading…");
        window.history.replaceState({}, "", window.location.pathname);
        window.location.reload();
      })
      .catch(e => alert("Invite error: " + e.message));
  }, []); // eslint-disable-line

  useEffect(() => {
    seedDefaultAccountsIfNeeded()
      .catch((e) => setSeedErr(e.message))
      .finally(() => {
        setSeeding(false);
        // Check if onboarding is needed (new user with no profile)
        supabase.from("business_profile")
          .select("onboarding_completed")
          .maybeSingle()
          .then(({ data }) => {
            setOnboarding(!data || !data.onboarding_completed);
          })
          .catch(() => setOnboarding(false));
      });
  }, [userId]);

  return (
    <WorkspaceContext.Provider value={workspace}>
    <div className="wrap wrap-sidebar">
      <Style />

      {/* Mobile menu toggle */}
      <button className="sidebar-toggle no-print" onClick={()=>setSidebarOpen(s=>!s)}>
        {sidebarOpen ? "✕" : "☰"}
      </button>

      <aside className={"sidebar" + (sidebarOpen ? " sidebar-open" : "")}>
        <div className="sidebar-logo"><span>हिसाब</span>HisabKitab</div>

        <nav className="sidebar-nav">
          {NAV_SECTIONS.map(sec => {
            const visibleTabs = sec.tabs.filter(tk => tk.access(role));
            if (visibleTabs.length === 0) return null;
            return (
              <div key={sec.section} className="sidebar-section">
                <div className="sidebar-section-title">{sec.section}</div>
                {visibleTabs.map(tk => (
                  <button key={tk.key}
                    className={"sidebar-item" + (tab === tk.key ? " active" : "")}
                    onClick={() => { setTab(tk.key); setSidebarOpen(false); }}>
                    <span className="sidebar-item-icon">{tk.icon}</span>
                    <span>{tk.label || t(tk.i18n, lang)}</span>
                  </button>
                ))}
              </div>
            );
          })}
        </nav>

        <div className="sidebar-footer">
          {workspace.activeWS && (
            <div className="ws-badge" title={"Working as "+workspace.role+" in "+workspace.activeWS.biz_name}>
              📋 {workspace.activeWS.biz_name}
              <button className="ws-switch-btn" onClick={()=>workspace.switchWorkspace(session.user.id)}>← Own</button>
            </div>
          )}
          {workspace.workspaces.length > 0 && !workspace.activeWS && (
            <select className="ws-select" onChange={e => e.target.value && workspace.switchWorkspace(e.target.value)} defaultValue="">
              <option value="">Switch workspace…</option>
              {workspace.workspaces.map(ws=>(
                <option key={ws.owner_user_id} value={ws.owner_user_id}>{ws.biz_name} ({ws.role})</option>
              ))}
            </select>
          )}
          <div className="sidebar-footer-row">
            <span className="bs-today">{todayBs}</span>
            <button className="lang-toggle" onClick={toggleLang} title="भाषा / Language">
              {lang === "en" ? "🇳🇵 NP" : "🇬🇧 EN"}
            </button>
          </div>
          <button className="ghost sidebar-signout" onClick={signOut} disabled={busy}>{t("signOut", lang)}</button>
        </div>
      </aside>

      {/* Overlay for mobile when sidebar is open */}
      {sidebarOpen && <div className="sidebar-backdrop no-print" onClick={()=>setSidebarOpen(false)} />}

      {/* Setup wizard overlay — shown for new users before they start */}
      {!seeding && onboarding === true && (
        <SetupWizard onComplete={(navTo) => { setOnboarding(false); if(navTo) setTab(navTo); }} />
      )}
      <main className="app-main app-main-sidebar">
        {seeding && <p className="note">{t("loading", lang)}</p>}
        {seedErr && <p className="msg err">Couldn't set up default accounts: {seedErr}</p>}
        {!seeding && (
          <TabErrorBoundary key={tab}>
            {tab === "dashboard" && <Dashboard refreshKey={refreshKey} lang={lang} onNav={setTab} />}
            {tab === "invoices" && <Invoices userId={userId} lang={lang} />}
            {tab === "purchases" && <Purchases userId={userId} lang={lang} />}
            {tab === "inventory" && <Inventory userId={userId} lang={lang} />}
            {tab === "reports" && <Reports lang={lang} />}
            {tab === "vouchers" && (
              <>
                <VoucherEntry userId={userId} onSaved={bump} lang={lang} />
                <VoucherList refreshKey={refreshKey} lang={lang} />
              </>
            )}
            {tab === "ledger" && <Ledger lang={lang} />}
            {/* P3 Masters — new unified pages */}
            {tab === "contacts"   && <Contacts userId={userId} onChanged={bump} lang={lang} />}
            {tab === "items"      && <Items onChanged={bump} lang={lang} />}
            {tab === "categories" && <ItemCategories onChanged={bump} lang={lang} />}
            {/* Kept for backward-compat during migration — no nav entry */}
            {tab === "parties" && <Parties userId={userId} onChanged={bump} lang={lang} />}
            {tab === "accounts" && <ChartOfAccounts userId={userId} onChanged={bump} lang={lang} />}
            {tab === "vat"   && <VatFiling />}
            {tab === "tds"   && <TDS userId={userId} />}
            {tab === "notes"     && <CreditDebitNotes />}
            {tab === "recon"     && <BankReconciliation />}
            {tab === "settings"  && <Settings />}
            {tab === "team" && <TeamMembers />}
            {tab === "audit" && <AuditLog lang={lang} />}
          </TabErrorBoundary>
        )}
      </main>
    </div>
    </WorkspaceContext.Provider>
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
  input,textarea{font-family:inherit;font-size:16px;padding:11px 13px;border:1px solid var(--line);border-radius:10px;background:#fff;color:var(--ink);width:100%}
  textarea{resize:vertical;line-height:1.45}
  input:focus,textarea:focus{outline:2px solid #1f6f5555;border-color:var(--green)}
  select{font-family:inherit;font-size:14px;padding:9px 12px;border:1px solid var(--line);border-radius:10px;background:#fff;color:var(--ink);width:100%}
  .btn{background:var(--green);color:#fff;border:none;padding:12px 16px;border-radius:10px;font-size:15px;cursor:pointer}
  .btn:hover{background:var(--green2)}.btn:disabled{opacity:.5;cursor:default}
  .btn.full{width:100%}
  .link{display:block;background:none;border:none;color:var(--green);cursor:pointer;font-size:13px;margin:10px auto 0;text-align:center}
  .msg{font-size:13px;padding:10px 12px;border-radius:9px;margin-top:14px}
  .msg.ok{background:#1f6f5414;color:var(--green2)}
  .msg.err{background:#a23b2214;color:var(--rust)}
  .note{font-size:11.5px;color:#9a9483;margin-top:14px;line-height:1.5}
  .top{display:flex;justify-content:space-between;align-items:center;padding:14px 22px;background:var(--green2);color:#f3efe2;flex-wrap:wrap;gap:10px}
  .ghost{background:transparent;border:1px solid #ffffff55;color:#f3efe2;padding:8px 14px;border-radius:8px;cursor:pointer}
  h1{font-family:Georgia,serif;font-size:24px;margin:0}
  h2{font-family:Georgia,serif;font-size:20px;margin:0}

  /* ---- App shell ---- */
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
  .inline-form input,.inline-form select{width:auto;flex:1 1 140px}
  .grid-form{display:grid;grid-template-columns:repeat(2,1fr);gap:10px;margin-bottom:18px}
  .grid-form .wide-field{grid-column:1 / -1}
  .grid-form input,.grid-form select{width:100%}
  .wide-field{flex:1 1 100%}
  .tbl{width:100%;border-collapse:collapse;font-size:13.5px}
  .tbl th{text-align:left;font-size:11.5px;text-transform:uppercase;letter-spacing:.04em;color:#9a9483;padding:8px 10px;border-bottom:1px solid var(--line)}
  .tbl td{padding:9px 10px;border-bottom:1px solid #10211b0d;vertical-align:top}
  .tbl tfoot td{border-top:2px solid var(--line);border-bottom:none;font-weight:600}
  .tbl .num{text-align:right;font-variant-numeric:tabular-nums}
  .tbl select,.tbl input{width:100%}
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
  .voucher-actions{margin-top:14px;display:flex;align-items:center;justify-content:space-between;gap:12px;flex-wrap:wrap}
  .voucher-entry-head{align-items:flex-start}
  .voucher-help{margin:5px 0 0;color:var(--ink2);font-size:12.5px;line-height:1.45;max-width:620px}
  .voucher-balance{min-width:150px;padding:9px 12px;border-radius:10px;border:1px solid var(--line);text-align:right;background:#10211b05}
  .voucher-balance span{display:block;font-size:10px;text-transform:uppercase;letter-spacing:.06em;color:var(--ink2);margin-bottom:2px}
  .voucher-balance strong{font-size:14px;font-variant-numeric:tabular-nums}
  .voucher-balance.balanced{background:#1f6f5410;border-color:#1f6f5440;color:var(--green2)}
  .voucher-balance.unbalanced{background:#a23b2208;color:var(--rust)}
  .voucher-meta-grid{display:grid;grid-template-columns:1fr 1.4fr .8fr;gap:12px;margin-bottom:14px}
  .voucher-meta-grid .fld{margin:0}
  .voucher-narration-field{grid-column:1 / -1}
  .table-scroll{overflow-x:auto;width:100%;-webkit-overflow-scrolling:touch}
  .voucher-entry-table{min-width:820px}
  .voucher-entry-table input,.voucher-entry-table select{font-size:13px;padding:8px 9px}
  .voucher-entry-table .voucher-account-cell{min-width:220px}
  .voucher-line-number{width:42px;text-align:center;color:#9a9483}
  .voucher-remove-cell{width:46px;text-align:center}
  .icon-btn{width:32px;height:32px;border-radius:8px;border:1px solid var(--line);background:#fff;color:var(--ink2);cursor:pointer;font-size:18px;line-height:1;display:inline-flex;align-items:center;justify-content:center}
  .icon-btn:hover{background:#10211b08}
  .icon-btn.danger{color:var(--rust)}
  .icon-btn:disabled{opacity:.35;cursor:default}
  .voucher-submit-actions{display:flex;gap:10px;align-items:center}
  .voucher-list-table{min-width:800px}
  .voucher-type{display:inline-block;font-size:10.5px;font-weight:700;text-transform:uppercase;letter-spacing:.04em;padding:3px 7px;border-radius:6px;background:#10211b0a;color:var(--ink2)}
  .voucher-type-journal{background:#b9892f18;color:#8a6520}
  .voucher-type-payment,.voucher-type-purchase{background:#a23b2212;color:var(--rust)}
  .voucher-type-receipt,.voucher-type-sales{background:#1f6f5414;color:var(--green2)}
  .voucher-type-contra{background:#2c3e5012;color:#2c3e50}
  .voucher-number{font-size:11px;color:var(--ink2);margin-top:4px}
  .voucher-account-list{min-width:180px;max-width:320px;line-height:1.4}
  .voucher-list-actions{text-align:right;white-space:nowrap}
  .danger-link{color:var(--rust);margin:0 0 0 auto}
  .managed-label{font-size:10.5px;color:#9a9483;white-space:nowrap}
  .empty-state{display:flex;flex-direction:column;gap:5px;align-items:center;text-align:center;padding:30px 16px;border:1px dashed var(--line);border-radius:12px;color:var(--ink2)}
  .empty-state strong{color:var(--ink);font-size:14px}
  .empty-state span{font-size:12px}
  .modal-copy{font-size:13px;line-height:1.5;margin:0 0 16px}
  .modal-actions{display:flex;justify-content:flex-end;gap:10px;margin-top:16px}
  .danger-btn{background:var(--rust)}
  .danger-btn:hover{background:#842f1c}
  @media(max-width:760px){.voucher-meta-grid{grid-template-columns:1fr}.voucher-narration-field{grid-column:auto}.voucher-balance{width:100%;text-align:left}.voucher-actions{align-items:stretch}.voucher-submit-actions{width:100%}.voucher-submit-actions button{flex:1}}
  .msg-inline{font-size:12px}
  .msg-inline.err{color:var(--rust)}
  .stat-row{display:flex;gap:14px;flex-wrap:wrap;margin-bottom:8px}
  .stat{flex:1 1 130px;background:#10211b08;border-radius:12px;padding:14px;text-align:center}
  .stat span{display:block;font-size:24px;font-weight:700;color:var(--green2);font-family:Georgia,serif}
  .ghost-btn{background:transparent;border:1px solid var(--line);color:var(--ink2);padding:8px 14px;border-radius:8px;cursor:pointer;font-size:13px}
  .biz-form{background:#10211b08;border-radius:12px;padding:16px;margin-bottom:18px;display:flex;flex-direction:column;gap:10px}
  .inv-form{display:flex;flex-direction:column;gap:8px;margin-bottom:20px;padding:18px;background:#10211b05;border-radius:12px;border:1px solid var(--line)}
  .inv-form-top{display:grid;grid-template-columns:repeat(3,1fr);gap:10px;margin-bottom:14px}
  .inv-lines-tbl input{font-size:13px;padding:6px 8px}
  .status-draft{color:#9a9483}
  .status-posted{color:var(--green2);font-weight:700}
  .status-sent,.status-open{color:var(--gold)}
  .status-partial{color:#a66b00;font-weight:700}
  .status-overdue{color:var(--rust);font-weight:700}
  .status-paid{color:var(--green2);font-weight:700}
  .status-cancelled,.status-credited{color:var(--rust);text-decoration:line-through}
  .payment-reversal-box{background:#fef0ee;border:1px solid #e6b9b1;border-radius:10px;padding:12px;display:grid;grid-template-columns:160px 1fr;gap:10px;align-items:end}
  .payment-reversal-box .modal-actions{grid-column:1/-1;margin-top:0}
  @media(max-width:760px){.payment-reversal-box{grid-template-columns:1fr}}
  .print-overlay{background:var(--paper);min-height:100vh;padding:20px}
  .print-actions{display:flex;gap:12px;margin-bottom:20px;align-items:center}
  .invoice-paper{background:#fff;max-width:820px;margin:0 auto;padding:40px;border:1px solid #ddd;font-family:'Inter',sans-serif;font-size:13px;color:#111}
  .inv-header{display:flex;justify-content:space-between;align-items:flex-start;margin-bottom:24px;padding-bottom:16px;border-bottom:2px solid #15543f}
  .inv-biz-name{font-size:20px;font-weight:700;color:#15543f}
  .inv-biz-sub{color:#555;font-size:12px}
  .inv-title{font-size:22px;font-weight:700;color:#15543f;text-align:right}
  .inv-title-sub{font-size:13px;color:#555;text-align:right}
  .inv-meta{display:flex;justify-content:space-between;margin-bottom:20px}
  .inv-meta-right div{display:flex;gap:12px;justify-content:flex-end;margin-bottom:4px}
  .inv-meta-right span{color:#555;min-width:90px;text-align:right}
  .inv-table{width:100%;border-collapse:collapse;margin-bottom:16px;font-size:12px}
  .inv-table th{background:#15543f;color:#fff;padding:7px 8px;text-align:left}
  .inv-table td{padding:6px 8px;border-bottom:1px solid #eee}
  .inv-table tfoot td{border-top:2px solid #15543f;border-bottom:none;padding-top:8px}
  .inv-table .r{text-align:right}
  .inv-total-row td{font-size:14px;background:#f0f7f4}
  .inv-words{font-size:12px;color:#333;padding:10px;background:#f9f9f9;border-radius:6px;margin-bottom:12px}
  .inv-notes{font-size:12px;color:#555;margin-bottom:20px}
  .inv-footer{display:flex;justify-content:space-between;align-items:flex-end;margin-top:30px;padding-top:16px;border-top:1px solid #ddd}
  .inv-sign{text-align:center;font-size:12px;color:#555}
  .inv-sign-line{width:160px;border-top:1px solid #333;margin-bottom:6px}
  .inv-footer-note{font-size:12px;color:#888}
  @media print{.no-print{display:none!important}.invoice-paper{border:none;padding:20px;max-width:100%}.print-overlay{padding:0}}
  .filter-tabs{display:flex;gap:6px;margin:14px 0 8px;flex-wrap:wrap}
  .filter-tab{background:transparent;border:1px solid var(--line);color:var(--ink2);padding:5px 12px;border-radius:20px;cursor:pointer;font-size:12.5px}
  .filter-tab.active{background:var(--green2);color:#fff;border-color:var(--green2)}
  .overdue{color:var(--rust);font-weight:600}
  .alert-bar{background:#a23b2214;color:var(--rust);padding:10px 14px;border-radius:10px;font-size:13px;margin-bottom:14px}
  .low-stock-row{background:#a23b220a}
  .low-stock-val{color:var(--rust);font-weight:700}
  .mov-in{color:var(--green2);font-weight:600}
  .mov-out{color:var(--rust);font-weight:600}
  .mov-adj{color:var(--gold);font-weight:600}
  .report-letterhead{margin-bottom:16px;padding-bottom:12px;border-bottom:2px solid #15543f}
  .report-wrap{padding:4px 0}
  .report-title{font-family:Georgia,serif;font-size:20px;font-weight:700;margin-bottom:4px}
  .report-period{font-size:13px;color:var(--ink2);margin-bottom:16px}
  .report-section{margin-bottom:20px}
  .report-section-title{font-size:12px;font-weight:700;text-transform:uppercase;letter-spacing:.06em;color:var(--gold);margin-bottom:8px}
  .net-result{display:flex;justify-content:space-between;padding:14px 16px;border-radius:10px;font-size:16px;font-weight:700;margin-top:8px}
  .net-result.profit{background:#1f6f5418;color:var(--green2)}
  .net-result.loss{background:#a23b2218;color:var(--rust)}
  .net-result.neutral{background:#10211b0a;color:var(--ink)}
  .bs-grid{display:grid;grid-template-columns:1fr 1fr;gap:24px}
  .vat-grid{display:grid;grid-template-columns:1fr 1fr;gap:24px}
  .vat-card{background:#10211b05;border:1px solid var(--line);border-radius:12px;padding:16px}
  .vat-card-title{font-weight:700;font-size:14px;margin-bottom:6px}
  .vat-card-amount{font-size:22px;font-weight:700;color:var(--green2);font-family:Georgia,serif;margin-bottom:4px}
  @media(max-width:680px){.bs-grid,.vat-grid{grid-template-columns:1fr}}
  @media print{.no-print{display:none!important}}

  /* ---- Phase 8: Language toggle + BS calendar ---- */
  .header-right{display:flex;align-items:center;gap:8px;flex-wrap:wrap}
  .lang-toggle{background:#ffffff22;border:1px solid #ffffff44;color:#f3efe2;padding:6px 12px;border-radius:8px;cursor:pointer;font-size:12.5px;white-space:nowrap}
  .lang-toggle:hover{background:#ffffff33}
  .bs-today{font-size:12px;color:#d4cdb8;white-space:nowrap;padding:0 4px}
  .bs-date-wrap{display:flex;flex-direction:column;gap:4px}
  .bs-date-selects{display:flex;gap:6px}
  .bs-date-selects select{flex:1;font-size:13px;padding:7px 8px}
  .bs-dual-label{font-size:11px;color:var(--ink2);padding:2px 2px}

  /* PWA install banner */
  .pwa-banner{background:var(--green2);color:#f3efe2;padding:10px 18px;display:flex;justify-content:space-between;align-items:center;font-size:13px;gap:12px}
  .pwa-banner button{background:#ffffff22;border:1px solid #ffffff44;color:#f3efe2;padding:6px 14px;border-radius:8px;cursor:pointer;font-size:13px}

  /* Nepali font support */
  @import url('https://fonts.googleapis.com/css2?family=Noto+Sans+Devanagari:wght@400;600;700&display=swap');
  body{font-family:'Inter','Noto Sans Devanagari','Segoe UI',system-ui,sans-serif}

  /* ── Sidebar Navigation ── */
  .wrap-sidebar{display:flex;min-height:100vh}
  .sidebar{width:250px;flex-shrink:0;background:var(--green2);color:#f3efe2;display:flex;flex-direction:column;height:100vh;position:sticky;top:0;overflow-y:auto}
  .sidebar-logo{font-family:Georgia,serif;font-size:20px;font-weight:700;padding:20px 18px 16px;display:flex;align-items:center;gap:8px;border-bottom:1px solid #ffffff1a}
  .sidebar-logo span{background:var(--gold);color:#211c0e;padding:3px 8px;border-radius:6px;font-size:15px}
  .sidebar-nav{flex:1;overflow-y:auto;padding:12px 10px}
  .sidebar-section{margin-bottom:14px}
  .sidebar-section-title{font-size:10.5px;font-weight:800;letter-spacing:.08em;text-transform:uppercase;color:#d4cdb8;opacity:.7;padding:6px 10px 4px}
  .sidebar-item{display:flex;align-items:center;gap:10px;width:100%;text-align:left;background:transparent;border:none;color:#e8e3d3;padding:9px 10px;border-radius:8px;cursor:pointer;font-size:13.5px;margin-bottom:2px;transition:background .12s}
  .sidebar-item:hover{background:#ffffff14}
  .sidebar-item.active{background:#f3efe2;color:var(--green2);font-weight:700}
  .sidebar-item-icon{font-size:15px;width:18px;text-align:center;flex-shrink:0}
  .sidebar-footer{padding:14px 14px 16px;border-top:1px solid #ffffff1a;display:flex;flex-direction:column;gap:8px}
  .sidebar-footer-row{display:flex;justify-content:space-between;align-items:center}
  .sidebar-signout{width:100%;justify-content:center}
  .sidebar-toggle{display:none}
  .sidebar-backdrop{display:none}
  .app-main-sidebar{flex:1;max-width:1100px;margin:0;padding:22px 24px 60px}

  @media (max-width: 880px) {
    .sidebar{position:fixed;left:0;top:0;transform:translateX(-100%);transition:transform .2s;z-index:9997;box-shadow:4px 0 24px #00000030}
    .sidebar.sidebar-open{transform:translateX(0)}
    .sidebar-toggle{display:block;position:fixed;top:14px;left:14px;z-index:9996;background:var(--green2);color:#f3efe2;border:none;border-radius:8px;width:40px;height:40px;font-size:18px;cursor:pointer;box-shadow:0 2px 10px #00000030}
    .sidebar-backdrop{display:block;position:fixed;inset:0;background:#00000050;z-index:9995}
    .app-main-sidebar{padding:70px 16px 40px}
  }

  /* ── Payment Modal ── */
  .modal-overlay{position:fixed;inset:0;background:#00000060;display:flex;align-items:center;justify-content:center;z-index:9998;padding:20px}
  .modal-card{background:#fff;border-radius:16px;width:100%;max-width:460px;max-height:88vh;overflow-y:auto;padding:24px;box-shadow:0 20px 60px #00000040}
  .modal-head{display:flex;justify-content:space-between;align-items:center;margin-bottom:16px}
  .modal-head h3{margin:0;font-family:Georgia,serif;font-size:17px}
  .pay-summary{background:#f8f8f6;border-radius:10px;padding:12px 16px;margin-bottom:16px}
  .pay-summary-row{display:flex;justify-content:space-between;font-size:13px;padding:3px 0}
  .pay-balance{font-weight:700;font-size:15px;color:var(--rust);border-top:1px solid var(--line);margin-top:6px;padding-top:8px}
  .pay-form-grid{display:grid;grid-template-columns:1fr;gap:10px;margin-bottom:8px}
  .pay-form-grid .fld{margin:0}

  /* ── Setup Wizard ── */
  .wizard-overlay{position:fixed;inset:0;background:linear-gradient(135deg,#1f6f54 0%,#10211b 100%);display:flex;align-items:center;justify-content:center;z-index:9999;padding:20px}
  .wizard-card{background:#fff;border-radius:20px;width:100%;max-width:640px;max-height:90vh;overflow-y:auto;box-shadow:0 24px 80px #00000060}
  .wizard-steps{display:flex;padding:24px 24px 0;gap:0;border-bottom:1px solid var(--line);margin-bottom:0}
  .wizard-step{flex:1;display:flex;flex-direction:column;align-items:center;gap:6px;padding-bottom:16px;position:relative}
  .wizard-step:not(:last-child)::after{content:"";position:absolute;top:12px;left:60%;width:80%;height:2px;background:var(--line)}
  .wizard-step.done::after{background:var(--green)}
  .wizard-step-dot{width:26px;height:26px;border-radius:50%;background:var(--line);color:#fff;display:flex;align-items:center;justify-content:center;font-size:12px;font-weight:700;z-index:1}
  .wizard-step.active .wizard-step-dot{background:var(--green)}
  .wizard-step.done .wizard-step-dot{background:var(--green2)}
  .wizard-step-label{font-size:11px;color:var(--ink2);text-align:center;font-weight:500}
  .wizard-step.active .wizard-step-label{color:var(--green2);font-weight:700}
  .wizard-body{padding:28px}
  .wizard-body h2{font-family:Georgia,serif;font-size:22px;color:var(--ink);margin:0 0 6px}
  .wizard-welcome{text-align:center;margin-bottom:24px}
  .wizard-logo{font-size:28px;font-weight:800;color:var(--green2);font-family:Georgia,serif;margin-bottom:8px}
  .wizard-logo span{color:var(--gold)}
  .wizard-type-grid{display:grid;grid-template-columns:1fr 1fr;gap:12px;margin:20px 0}
  .wizard-type-card{border:2px solid var(--line);border-radius:12px;padding:16px;cursor:pointer;transition:all .15s;text-align:center}
  .wizard-type-card:hover{border-color:var(--green);background:#e8f5f008}
  .wizard-type-card.selected{border-color:var(--green);background:#e8f5f0}
  .wizard-type-icon{font-size:32px;margin-bottom:6px}
  .wizard-type-label{font-weight:700;font-size:14px;color:var(--ink);margin-bottom:4px}
  .wizard-type-desc{font-size:11px;color:var(--ink2);line-height:1.4}
  .wizard-form{display:grid;grid-template-columns:1fr 1fr;gap:12px;margin:16px 0}
  .wizard-form .fld{margin:0}
  .wizard-footer{display:flex;justify-content:space-between;align-items:center;margin-top:20px;padding-top:16px;border-top:1px solid var(--line)}
  .wizard-bs-preview{margin:16px 0;padding:16px;background:#f8f8f6;border-radius:12px;border:1px solid var(--line)}
  .wizard-bs-title{font-size:12px;font-weight:700;color:var(--ink2);text-transform:uppercase;letter-spacing:.05em;margin-bottom:10px}
  .wizard-bs-row{display:flex;justify-content:space-between;font-size:13px;padding:4px 0}
  .wizard-bs-divider{border-top:1px solid var(--line);margin:8px 0}
  .wizard-bs-capital{font-size:14px;border-top:2px solid var(--green);margin-top:6px;padding-top:8px}
  .wizard-bs-check{font-size:12px;margin-top:4px;font-weight:600}
  .wizard-done{text-align:center}
  .wizard-confetti{font-size:64px;margin-bottom:8px}
  .wizard-done-checks{display:inline-flex;flex-direction:column;gap:8px;text-align:left;margin:20px auto;background:#e8f5f0;padding:16px 24px;border-radius:12px}
  .wizard-done-check{font-size:14px;color:var(--ink)}
  .wizard-done-tick{color:var(--green2);font-weight:700;margin-right:8px}
  .wizard-done-actions{display:flex;gap:12px;justify-content:center;margin-top:20px;flex-wrap:wrap}

  /* ── Settings ── */
  .settings-info-box{padding:12px 16px;background:#f0f7f4;border-left:4px solid var(--green);border-radius:0 8px 8px 0;margin-bottom:16px;font-size:13px;color:var(--ink2);line-height:1.5}

  /* ── Bank Reconciliation ── */
  .recon-card{padding:10px 12px;border:1px solid var(--line);border-radius:8px;cursor:pointer;transition:all .15s;background:var(--card)}
  .recon-card:hover{border-color:var(--green);background:#e8f5f0}
  .recon-matched{background:#e8f5f020;border-color:#1f6f5440;cursor:default;opacity:.75}
  .recon-selected{border-color:var(--gold)!important;background:#fdf6e3!important;box-shadow:0 0 0 2px var(--gold)40}
  .recon-voucher{cursor:default}
  .recon-matchable{cursor:pointer!important}
  .recon-matchable:hover{background:#e8f5f0!important;border-color:var(--green)!important}

  /* ── TDS ── */
  .tds-calc-box{margin:12px 0;padding:14px 16px;background:#fff9f0;border:1px solid var(--gold);border-radius:8px}
  .tds-calc-row{display:flex;justify-content:space-between;padding:4px 0;font-size:14px}
  .tds-calc-total{border-top:1px solid var(--gold);margin-top:6px;padding-top:10px;font-size:15px;color:var(--green2)}

  /* ── Workspace & Team ── */
  .ws-badge{background:#b9892f22;border:1px solid var(--gold);color:var(--gold);padding:4px 10px;border-radius:20px;font-size:12px;font-weight:600;display:flex;align-items:center;gap:6px}
  .ws-switch-btn{background:none;border:none;color:var(--gold);cursor:pointer;font-size:11px;text-decoration:underline;padding:0}
  .ws-select{background:#ffffff22;border:1px solid #ffffff44;color:#f3efe2;padding:5px 10px;border-radius:8px;font-size:12px;cursor:pointer}
  .ws-select option{background:#1f6f54;color:#f3efe2}
  .role-badge{padding:2px 10px;border-radius:12px;font-size:11px;font-weight:700;text-transform:uppercase;letter-spacing:.05em}
  .role-owner{background:#1f6f5420;color:#1f6f54}
  .role-accountant{background:#2c3e5020;color:#2c3e50}
  .role-staff{background:#b9892f20;color:#8a6520}
  .role-viewer{background:#95a5a620;color:#7f8c8d}
  .team-role-guide{display:flex;flex-wrap:wrap;gap:12px;margin-bottom:16px;padding:12px;background:#f8f8f6;border-radius:8px}
  .team-role-pill{display:flex;align-items:center;gap:8px}
  .invite-link-box{margin-top:12px;padding:14px;background:#e8f5f0;border:1px solid var(--green);border-radius:8px}

  /* ── Dashboard ── */
  .dash-section-title{font-size:11px;font-weight:800;letter-spacing:.08em;text-transform:uppercase;color:var(--ink2);margin:8px 0 10px 0}
  .dash-cards{display:flex;flex-wrap:wrap;gap:12px}
  .dash-actions{display:flex;flex-wrap:wrap;gap:8px;margin-bottom:4px}

  /* ── Vertical Balance Sheet ── */
  .bs-vert{display:flex;flex-direction:column;gap:0}
  .bs-block{margin-bottom:28px}
  .bs-block-hd{font-size:11px;font-weight:800;letter-spacing:.1em;text-transform:uppercase;color:var(--green2);background:#1f6f5410;padding:8px 12px;border-left:4px solid var(--green);margin-bottom:12px}
  .bs-sub-hd{font-size:12px;font-weight:700;color:var(--gold);text-transform:uppercase;letter-spacing:.05em;margin:10px 0 4px 0;padding-bottom:4px;border-bottom:1px solid var(--line)}
  .bs-row{display:flex;justify-content:space-between;align-items:baseline;padding:5px 8px;font-size:13.5px;border-bottom:1px solid #10211b08}
  .bs-row:hover{background:#10211b04}
  .bs-net-row{font-style:italic;color:var(--ink2)}
  .bs-amt{font-variant-numeric:tabular-nums;min-width:110px;text-align:right}
  .bs-grp{display:block;font-size:10.5px;color:var(--ink2);font-weight:400;margin-top:1px}
  .bs-subtotal{display:flex;justify-content:space-between;align-items:baseline;padding:7px 8px;background:#10211b06;font-size:13.5px;border-top:1px solid var(--line);margin-top:2px}
  .bs-grand{display:flex;justify-content:space-between;align-items:baseline;padding:10px 12px;background:var(--green2);color:#f3efe2;font-size:15px;font-weight:700;font-family:Georgia,serif;margin-top:12px;border-radius:8px}
  `}</style>;
}
