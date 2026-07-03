import { createClient } from "@supabase/supabase-js";
import { SUPABASE_URL, SUPABASE_ANON_KEY } from "./config";

export const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
  auth: {
    persistSession: true,       // keep the user logged in across reloads
    autoRefreshToken: true,     // refresh the token automatically
    detectSessionInUrl: false,  // we use OTP codes, not magic-link redirects
  },
});
