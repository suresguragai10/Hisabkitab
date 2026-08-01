import React, { useState, useEffect, Component, Suspense, lazy } from "react";
import "./App.css";
import { HashRouter, Routes, Route, Navigate, NavLink, useNavigate, useLocation } from "react-router-dom";
import { supabase, diagnoseAuthServer } from "./supabase";
import { seedDefaultAccountsIfNeeded, checkRateLimit, logRateLimit, listAuditLog } from "./lib/db";
import { getLang, setLang, t } from "./lib/i18n";
import { formatBs } from "./lib/nepaliCalendar";
import {
  Home, FileText, Receipt, Undo2, FileQuestion, ShoppingCart, Users, Tag,
  FolderTree, Package, Landmark, NotebookPen, BookOpen, Library, BarChart3,
  ScrollText, Percent, UserCog, Settings as SettingsIcon, ShieldCheck,
  ClipboardList, Menu, X,
} from "lucide-react";

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

// Page components are lazy-loaded per route (audit item 6 -- Vite's own
// build warning flagged one 740KB+ eagerly-bundled chunk containing all
// 19 pages at once). Splitting them means a user visiting Dashboard
// doesn't download Reports/ChartOfAccounts/TDS/etc. code until they
// actually navigate there.
const Dashboard = lazy(() => import("./pages/Dashboard"));
const TeamMembers = lazy(() => import("./pages/TeamMembers"));
const TDS = lazy(() => import("./pages/TDS"));
const VatFiling = lazy(() => import("./pages/VatFiling"));
const BankReconciliation = lazy(() => import("./pages/BankReconciliation"));
const Settings = lazy(() => import("./pages/Settings"));
const CreditDebitNotes = lazy(() => import("./pages/CreditDebitNotes"));
const SetupWizard = lazy(() => import("./pages/SetupWizard"));
import { WorkspaceContext, useWorkspaceProvider, NAV_ACCESS } from "./lib/workspace";
const ChartOfAccounts = lazy(() => import("./pages/ChartOfAccounts"));
const Parties = lazy(() => import("./pages/Parties"));
const Contacts = lazy(() => import("./pages/Contacts"));
const Items = lazy(() => import("./pages/Items"));
const ItemCategories = lazy(() => import("./pages/ItemCategories"));
const VoucherEntry = lazy(() => import("./pages/VoucherEntry"));
const VoucherList = lazy(() => import("./pages/VoucherList"));
const AuditLog = lazy(() => import("./pages/AuditLog"));
const Invoices = lazy(() => import("./pages/Invoices"));
const Purchases = lazy(() => import("./pages/Purchases"));
const Inventory = lazy(() => import("./pages/Inventory"));
const Reports = lazy(() => import("./pages/Reports"));
const Ledger = lazy(() => import("./pages/Ledger"));
const SalesOrdersRFQ = lazy(() => import("./pages/SalesOrdersRFQ"));
import DialogHost from "./components/DialogHost";
import { confirmDialog, showToast } from "./lib/dialogs";

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


  // A user "needs password" if they logged in via OTP and have never set one.
  // Supabase stores this as user_metadata.has_password.
  const checkNeedsPassword = (s) => {
    const meta = s?.user?.user_metadata || {};
    setNeedsPassword(!meta.has_password);
    setLoading(false);
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
  return (
    <HashRouter>
      <Authed session={session} lang={lang} toggleLang={toggleLang} />
    </HashRouter>
  );
}

// ── Splash ────────────────────────────────────────────────────
function Splash() {
  return (
    <div className="wrap center">
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
// Grouping follows the audit's recommended sidebar (docs/AUDIT_TRACKER.md
// section 3): Banking and Tax & Compliance split out of Accounting/Reports,
// Audit Log moved under Settings. Contacts stays unified (one page already
// handles customer/vendor/both) rather than forced into separate
// Customers/Suppliers entries, since that split doesn't match how parties
// are actually modeled here. Credit/Debit Notes gets two nav entries
// (Sales and Purchases) pointing at the same page via `route`, since one
// shared page correctly handles both but the audit's complaint --
// "purchase debit notes may follow a different workflow" than sales
// credit notes -- is about *findability*, not the page itself.
const NAV_SECTIONS = [
  { section: "Overview", tabs: [
    { key: "dashboard", i18n: "dashboard", icon: Home, access: ()=>true },
  ]},
  { section: "Sales", tabs: [
    { key: "sales-orders", i18n: "salesOrders", icon: FileText, label: "Sales Orders", access: ()=>true },
    { key: "invoices",  i18n: "invoices",  icon: Receipt, access: ()=>true },
    { key: "notes-cn",  route: "notes", i18n: "notes", icon: Undo2,  label: "Credit Notes", access: r=>["owner","accountant","staff"].includes(r) },
  ]},
  { section: "Purchases", tabs: [
    { key: "rfq", i18n: "rfq", icon: FileQuestion, label: "RFQ / Quotations", access: ()=>true },
    { key: "purchases", i18n: "purchases", icon: ShoppingCart, access: ()=>true },
    { key: "notes-dn",  route: "notes", i18n: "notes", icon: Undo2,  label: "Debit Notes", access: r=>["owner","accountant","staff"].includes(r) },
  ]},
  // P3 Masters Unification — "Contacts" replaces "Parties" and gets its
  // own section. "Items" splits from Inventory: the master lives here,
  // controlled stock movement and reconciliation UI stays in Inventory.
  { section: "Contacts", tabs: [
    { key: "contacts", i18n: "contacts", icon: Users, label: "Contacts", access: ()=>true },
  ]},
  { section: "Items & Stock", tabs: [
    { key: "items",       i18n: "items",       icon: Tag,        label: "Items",      access: ()=>true },
    { key: "categories",  i18n: "categories",  icon: FolderTree, label: "Categories", access: ()=>true },
    { key: "inventory",   i18n: "inventory",   icon: Package,    access: ()=>true },
  ]},
  { section: "Banking", tabs: [
    { key: "recon", i18n: "recon", icon: Landmark, label: "Bank Reconciliation", access: r=>["owner","accountant"].includes(r) },
  ]},
  { section: "Accounting", tabs: [
    { key: "vouchers", i18n: "vouchers",        icon: NotebookPen, access: r=>["owner","accountant"].includes(r) },
    { key: "ledger",   i18n: "ledger",          icon: BookOpen,    access: r=>["owner","accountant","viewer"].includes(r) },
    { key: "accounts", i18n: "chartOfAccounts", icon: Library,     label: "Chart of Accounts", access: r=>["owner","accountant"].includes(r) },
  ]},
  { section: "Reports", tabs: [
    { key: "reports", i18n: "reports", icon: BarChart3, access: r=>["owner","accountant","viewer"].includes(r) },
  ]},
  { section: "Tax & Compliance", tabs: [
    { key: "vat", i18n: "vat", icon: ScrollText, label: "VAT Filing", access: r=>["owner","accountant","viewer"].includes(r) },
    { key: "tds", i18n: "tds", icon: Percent,    label: "TDS", access: r=>["owner","accountant"].includes(r) },
  ]},
  { section: "Settings", tabs: [
    { key: "team",     i18n: "team",     icon: UserCog,     label: "Team", access: r=>r==="owner" },
    { key: "settings", i18n: "settings", icon: SettingsIcon, label: "Settings", access: r=>["owner","accountant"].includes(r) },
    { key: "audit",    i18n: "auditLog", icon: ShieldCheck, label: "Audit Log", access: r=>["owner","accountant"].includes(r) },
  ]},
];

// Flat list retained for any code that still needs ALL_TABS shape
const ALL_TABS = NAV_SECTIONS.flatMap(s => s.tabs);

function Authed({ session, lang, toggleLang }) {
  const userId = session.user.id;
  const [busy, setBusy] = useState(false);
  const location = useLocation();
  const navigate = useNavigate();
  // The URL is the single source of truth for which page is showing --
  // this gives real browser Back/Forward, refresh-safe pages, and
  // bookmarkable/shareable links (audit item 4.6), instead of the old
  // in-memory tab state that reset to Dashboard on every reload.
  const tab = location.pathname.replace(/^\/+/, "") || "dashboard";
  const goTab = (key) => navigate("/" + key);
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
      .then(async biz => {
        await confirmDialog(`Welcome! You now have access to ${biz}.`, { confirmLabel: "Continue" });
        window.history.replaceState({}, "", window.location.pathname);
        window.location.reload();
      })
      .catch(e => showToast("Invite error: " + e.message, "error"));
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

      {/* Mobile menu toggle */}
      <button className="sidebar-toggle no-print" onClick={()=>setSidebarOpen(s=>!s)}
        aria-label={sidebarOpen ? "Close menu" : "Open menu"} aria-expanded={sidebarOpen}>
        {sidebarOpen ? <X size={20} /> : <Menu size={20} />}
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
                  <NavLink key={tk.key} to={"/" + (tk.route || tk.key)}
                    className={({ isActive }) => "sidebar-item" + (isActive ? " active" : "")}
                    onClick={() => setSidebarOpen(false)}>
                    <span className="sidebar-item-icon"><tk.icon size={16} strokeWidth={2} /></span>
                    <span>{tk.label || t(tk.i18n, lang)}</span>
                  </NavLink>
                ))}
              </div>
            );
          })}
        </nav>

        <div className="sidebar-footer">
          {workspace.activeWS && (
            <div className="ws-badge" title={"Working as "+workspace.role+" in "+workspace.activeWS.biz_name}>
              <ClipboardList size={14} /> {workspace.activeWS.biz_name}
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
        <Suspense fallback={null}>
          <SetupWizard onComplete={(navTo) => { setOnboarding(false); if(navTo) goTab(navTo); }} />
        </Suspense>
      )}
      <main className="app-main app-main-sidebar">
        {seeding && <p className="note">{t("loading", lang)}</p>}
        {seedErr && <p className="msg err">Could not set up default accounts: {seedErr}</p>}
        {!seeding && (
          <TabErrorBoundary key={tab}>
            <Suspense fallback={<p className="note">{t("loading", lang)}</p>}>
            <Routes>
              <Route path="/" element={<Navigate to="/dashboard" replace />} />
              <Route path="/dashboard" element={<Dashboard refreshKey={refreshKey} lang={lang} onNav={goTab} />} />
              <Route path="/sales-orders" element={<SalesOrdersRFQ docType="so" lang={lang} />} />
              <Route path="/invoices" element={<Invoices userId={userId} lang={lang} />} />
              <Route path="/rfq" element={<SalesOrdersRFQ docType="rfq" lang={lang} />} />
              <Route path="/purchases" element={<Purchases userId={userId} lang={lang} />} />
              <Route path="/inventory" element={<Inventory userId={userId} lang={lang} />} />
              <Route path="/reports" element={<Reports lang={lang} />} />
              <Route path="/vouchers" element={
                <>
                  <VoucherEntry userId={userId} onSaved={bump} lang={lang} />
                  <VoucherList refreshKey={refreshKey} lang={lang} />
                </>
              } />
              <Route path="/ledger" element={<Ledger lang={lang} />} />
              {/* P3 Masters — new unified pages */}
              <Route path="/contacts" element={<Contacts userId={userId} onChanged={bump} lang={lang} />} />
              <Route path="/items" element={<Items onChanged={bump} lang={lang} />} />
              <Route path="/categories" element={<ItemCategories onChanged={bump} lang={lang} />} />
              {/* Kept for backward-compat during migration — no nav entry */}
              <Route path="/parties" element={<Parties userId={userId} onChanged={bump} lang={lang} />} />
              <Route path="/accounts" element={<ChartOfAccounts userId={userId} onChanged={bump} lang={lang} />} />
              <Route path="/vat" element={<VatFiling />} />
              <Route path="/tds" element={<TDS userId={userId} />} />
              <Route path="/notes" element={<CreditDebitNotes />} />
              <Route path="/recon" element={<BankReconciliation />} />
              <Route path="/settings" element={<Settings />} />
              <Route path="/team" element={<TeamMembers />} />
              <Route path="/audit" element={<AuditLog lang={lang} />} />
              <Route path="*" element={<Navigate to="/dashboard" replace />} />
            </Routes>
            </Suspense>
          </TabErrorBoundary>
        )}
      </main>
      <DialogHost />
    </div>
    </WorkspaceContext.Provider>
  );
}
