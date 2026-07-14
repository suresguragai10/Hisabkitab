// ============================================================
// Phase P1 — Business Profile (stored in DB, not localStorage)
// ============================================================
import { useState, useEffect } from "react";
import { supabase } from "../supabase";

// Load the profile from the database (creates a blank row if first time)
export async function loadBusinessProfile() {
  const { data, error } = await supabase.rpc("get_or_create_business_profile");
  if (error) throw error;
  return data?.[0] || {};
}

// Save the profile to the database
export async function saveBusinessProfile(profile) {
  const { error } = await supabase.rpc("save_business_profile", {
    p_biz_name:       profile.biz_name       || "",
    p_biz_name_np:    profile.biz_name_np    || "",
    p_address:        profile.address         || "",
    p_city:           profile.city            || "",
    p_pan_vat:        profile.pan_vat         || "",
    p_phone:          profile.phone           || "",
    p_email:          profile.email           || "",
    p_invoice_prefix: profile.invoice_prefix  || "",
  });
  if (error) throw error;
}

// React hook — use this in any page that needs the profile
export function useBusinessProfile() {
  const [profile, setProfile] = useState(null);
  const [loading, setLoading] = useState(true);

  const load = async () => {
    try {
      const p = await loadBusinessProfile();
      // One-time migration from localStorage (safe to repeat — just a no-op if already migrated)
      if (!p.biz_name && localStorage.getItem("biz_name")) {
        const migrated = {
          biz_name:  localStorage.getItem("biz_name")    || "",
          address:   localStorage.getItem("biz_address") || "",
          pan_vat:   localStorage.getItem("biz_pan")     || "",
          biz_name_np: "", city: "", phone: "", email: "", invoice_prefix: "",
        };
        await saveBusinessProfile(migrated);
        setProfile({ ...p, ...migrated });
      } else {
        setProfile(p);
      }
    } catch (e) {
      // Fallback to localStorage if DB fails (offline / first-deploy)
      setProfile({
        biz_name:  localStorage.getItem("biz_name")    || "",
        address:   localStorage.getItem("biz_address") || "",
        pan_vat:   localStorage.getItem("biz_pan")     || "",
        biz_name_np: "", city: "", phone: "", email: "", invoice_prefix: "",
      });
    }
    setLoading(false);
  };

  useEffect(() => { load(); }, []);

  const save = async (updated) => {
    setProfile(updated);
    await saveBusinessProfile(updated);
  };

  return { profile, loading, save, reload: load };
}
