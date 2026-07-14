import React, { useEffect, useState } from "react";
import { supabase } from "../supabase";
import { useWorkspace } from "../lib/workspace";

const ROLES = [
  { value: "accountant", label: "Accountant", desc: "Full access except team management" },
  { value: "staff",      label: "Staff",       desc: "Can create invoices and purchases only" },
  { value: "viewer",     label: "Viewer",      desc: "Read-only — can view everything, edit nothing" },
];

export default function TeamMembers() {
  const { role } = useWorkspace();
  const [members, setMembers] = useState([]);
  const [loading, setLoading] = useState(true);
  const [err, setErr] = useState(null);
  const [busy, setBusy] = useState(false);
  const [inviteEmail, setInviteEmail] = useState("");
  const [inviteRole, setInviteRole] = useState("accountant");
  const [inviteLink, setInviteLink] = useState(null);
  const [showForm, setShowForm] = useState(false);

  const load = async () => {
    setLoading(true);
    try {
      const { data, error } = await supabase.rpc("list_my_team");
      if (error) throw error;
      setMembers(data || []);
    } catch(e) { setErr(e.message); }
    setLoading(false);
  };

  useEffect(() => { load(); }, []);

  const invite = async () => {
    if (!inviteEmail.trim()) return;
    setBusy(true); setErr(null); setInviteLink(null);
    try {
      const { data: token, error } = await supabase.rpc("invite_member", {
        p_email: inviteEmail.trim().toLowerCase(),
        p_role: inviteRole,
      });
      if (error) throw error;
      const base = window.location.origin + window.location.pathname;
      setInviteLink(`${base}?invite=${token}`);
      await load();
    } catch(e) { setErr(e.message); }
    setBusy(false);
  };

  const remove = async (memberUserId, email) => {
    if (!confirm(`Remove ${email} from your team? They will lose access immediately.`)) return;
    try {
      const { error } = await supabase.rpc("remove_member", { p_member_user_id: memberUserId });
      if (error) throw error;
      await load();
    } catch(e) { setErr(e.message); }
  };

  if (role !== "owner") return (
    <div className="panel">
      <div className="panel-head"><h2>Team Members</h2></div>
      <p className="note">Only the business owner can manage team members.</p>
    </div>
  );

  return (
    <div className="panel">
      <div className="panel-head">
        <h2>Team Members (टीम)</h2>
        <button className="btn" onClick={() => { setShowForm(s=>!s); setInviteLink(null); }}>
          {showForm ? "Cancel" : "+ Invite Member"}
        </button>
      </div>

      {/* Role guide */}
      <div className="team-role-guide">
        {ROLES.map(r => (
          <div key={r.value} className="team-role-pill">
            <span className={"role-badge role-"+r.value}>{r.label}</span>
            <span className="muted" style={{fontSize:12}}>{r.desc}</span>
          </div>
        ))}
      </div>

      {/* Invite form */}
      {showForm && (
        <div className="biz-form" style={{marginBottom:16}}>
          <b style={{display:"block",marginBottom:12}}>Invite a team member</b>
          <div style={{display:"flex",gap:10,flexWrap:"wrap",alignItems:"flex-end"}}>
            <label className="fld" style={{flex:"2 1 200px",margin:0}}>
              Their email address
              <input type="email" placeholder="accountant@example.com"
                value={inviteEmail} onChange={e=>setInviteEmail(e.target.value)} />
            </label>
            <label className="fld" style={{flex:"1 1 140px",margin:0}}>
              Role
              <select value={inviteRole} onChange={e=>setInviteRole(e.target.value)}>
                {ROLES.map(r=><option key={r.value} value={r.value}>{r.label}</option>)}
              </select>
            </label>
            <button className="btn" onClick={invite} disabled={busy||!inviteEmail.trim()} style={{marginTop:20}}>
              {busy ? "Generating…" : "Generate Invite Link"}
            </button>
          </div>

          {err && <p className="msg err" style={{marginTop:8}}>{err}</p>}

          {inviteLink && (
            <div className="invite-link-box">
              <div style={{fontWeight:600,marginBottom:6}}>✓ Invite link generated — copy and send to {inviteEmail}</div>
              <div style={{display:"flex",gap:8,alignItems:"center"}}>
                <input readOnly value={inviteLink} style={{flex:1,fontFamily:"monospace",fontSize:12}}
                  onFocus={e=>e.target.select()} />
                <button className="ghost-btn" onClick={()=>{navigator.clipboard.writeText(inviteLink); alert("Copied!");}}>
                  Copy
                </button>
              </div>
              <p className="muted" style={{fontSize:12,marginTop:6}}>
                They must sign up / log in with <b>{inviteEmail}</b> then open this link. 
                The link is single-use and expires when accepted.
              </p>
            </div>
          )}
        </div>
      )}

      {/* Members list */}
      {loading ? <p className="note">Loading…</p> : members.length === 0 ? (
        <p className="note">No team members yet. Invite your accountant or staff above.</p>
      ) : (
        <table className="tbl">
          <thead>
            <tr>
              <th>Email</th>
              <th>Role</th>
              <th>Status</th>
              <th>Joined</th>
              <th/>
            </tr>
          </thead>
          <tbody>
            {members.map(m => (
              <tr key={m.id}>
                <td>{m.member_email}</td>
                <td><span className={"role-badge role-"+m.role}>{m.role}</span></td>
                <td>
                  <span className={m.status === "active" ? "status-paid" : "status-draft"}>
                    {m.status === "active" ? "Active" : "Pending — awaiting acceptance"}
                  </span>
                </td>
                <td className="muted">{m.joined_at ? new Date(m.joined_at).toLocaleDateString() : "—"}</td>
                <td>
                  {m.member_user_id && (
                    <button className="link" style={{color:"var(--rust)"}}
                      onClick={() => remove(m.member_user_id, m.member_email)}>
                      Remove
                    </button>
                  )}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}

      {/* Permissions table */}
      <div style={{marginTop:24}}>
        <div className="dash-section-title">Permission Summary</div>
        <table className="tbl">
          <thead>
            <tr><th>Feature</th><th>Owner</th><th>Accountant</th><th>Staff</th><th>Viewer</th></tr>
          </thead>
          <tbody>
            {[
              ["Invoices — view",      "✓","✓","✓","✓"],
              ["Invoices — create",    "✓","✓","✓","—"],
              ["Purchases — view",     "✓","✓","✓","✓"],
              ["Purchases — create",   "✓","✓","✓","—"],
              ["Vouchers",             "✓","✓","—","—"],
              ["Reports & Ledger",     "✓","✓","—","✓"],
              ["Chart of Accounts",    "✓","✓","—","—"],
              ["Parties",              "✓","✓","✓","✓"],
              ["Inventory",            "✓","✓","✓","✓"],
              ["Team Management",      "✓","—","—","—"],
            ].map(([feat,...perms])=>(
              <tr key={feat}>
                <td>{feat}</td>
                {perms.map((p,i)=>(
                  <td key={i} className="num" style={{color: p==="✓" ? "var(--green2)" : "var(--ink2)"}}>
                    {p}
                  </td>
                ))}
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}
