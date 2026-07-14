// ============================================================
// workspace.js — multi-user workspace & role management
// ============================================================
import { useState, useEffect, createContext, useContext } from "react";
import { supabase } from "../supabase";

// ── Context ───────────────────────────────────────────────────
export const WorkspaceContext = createContext(null);

export function useWorkspace() {
  const ctx = useContext(WorkspaceContext);
  // Safe default when context is not yet provided
  return ctx || { role: "owner", workspaces: [], activeWS: null, loading: false,
                  refresh: ()=>{}, switchWorkspace: ()=>{}, acceptInvite: ()=>{} };
}

// ── Provider hook — call once at the top of App ───────────────
export function useWorkspaceProvider() {
  const [role,       setRole]       = useState("owner"); // owner|accountant|staff|viewer
  const [workspaces, setWorkspaces] = useState([]);      // workspaces I'm a member of
  const [activeWS,   setActiveWS]   = useState(null);    // {owner_user_id, biz_name} or null
  const [loading,    setLoading]    = useState(true);

  const refresh = async () => {
    setLoading(true);
    try {
      const [roleRes, wsRes] = await Promise.all([
        supabase.rpc("get_my_role"),
        supabase.rpc("list_my_workspaces"),
      ]);
      setRole(roleRes.data || "owner");
      setWorkspaces(wsRes.data || []);

      // Figure out which workspace is active
      const { data: pref } = await supabase
        .from("user_workspace_pref")
        .select("active_workspace")
        .maybeSingle();

      if (pref?.active_workspace) {
        const ws = (wsRes.data || []).find(w => w.owner_user_id === pref.active_workspace);
        setActiveWS(ws || null);
      } else {
        setActiveWS(null);
      }
    } catch (e) {
      console.error("workspace load error", e);
    }
    setLoading(false);
  };

  useEffect(() => { refresh(); }, []);

  const switchWorkspace = async (ownerUserId) => {
    await supabase.rpc("switch_workspace", { p_owner_id: ownerUserId });
    await refresh();
    window.location.reload(); // reload so all queries use new workspace
  };

  const acceptInvite = async (token) => {
    const { data, error } = await supabase.rpc("accept_invite", { p_token: token });
    if (error) throw error;
    await refresh();
    return data; // business name for welcome message
  };

  return { role, workspaces, activeWS, loading, refresh, switchWorkspace, acceptInvite };
}

// ── Role permission helpers ───────────────────────────────────
export const ROLE_CAN = {
  // what each role is allowed to do
  createInvoice:   r => ["owner","accountant","staff"].includes(r),
  createPurchase:  r => ["owner","accountant","staff"].includes(r),
  createVoucher:   r => ["owner","accountant"].includes(r),
  viewReports:     r => ["owner","accountant","viewer"].includes(r),
  viewLedger:      r => ["owner","accountant","viewer"].includes(r),
  manageAccounts:  r => ["owner","accountant"].includes(r),
  manageParties:   r => ["owner","accountant","staff"].includes(r),
  manageInventory: r => ["owner","accountant","staff"].includes(r),
  manageTeam:      r => r === "owner",
  editBizProfile:  r => r === "owner",
};

export const NAV_ACCESS = {
  dashboard:  () => true,
  invoices:   () => true,
  purchases:  () => true,
  parties:    () => true,
  inventory:  () => true,
  vouchers:   r  => ROLE_CAN.createVoucher(r),
  ledger:     r  => ROLE_CAN.viewLedger(r),
  reports:    r  => ROLE_CAN.viewReports(r),
  accounts:   r  => ROLE_CAN.manageAccounts(r),
  team:       r  => ROLE_CAN.manageTeam(r),
};
