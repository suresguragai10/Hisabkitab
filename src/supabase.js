import { createClient } from "@supabase/supabase-js";
import { SUPABASE_URL, SUPABASE_ANON_KEY } from "./config";

const normalizedUrl = String(SUPABASE_URL || "").trim().replace(/\/+$/, "");
const normalizedKey = String(SUPABASE_ANON_KEY || "").trim();

export const supabase = createClient(normalizedUrl, normalizedKey, {
  auth: {
    persistSession: true,
    autoRefreshToken: true,
    detectSessionInUrl: false,
  },
});

/**
 * Test the Auth API directly, independently of supabase-js login handling.
 * No password, email, session, or secret key is transmitted.
 */
export async function diagnoseAuthServer(timeoutMs = 12000) {
  let parsedUrl;

  try {
    parsedUrl = new URL(normalizedUrl);
  } catch {
    return {
      ok: false,
      kind: "configuration",
      message: "The Supabase project URL in src/config.js is not a valid URL.",
    };
  }

  if (parsedUrl.protocol !== "https:") {
    return {
      ok: false,
      kind: "configuration",
      message: "The Supabase project URL must start with https://.",
    };
  }

  if (!normalizedKey) {
    return {
      ok: false,
      kind: "configuration",
      message: "The Supabase publishable/anon key is empty in src/config.js.",
    };
  }

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), timeoutMs);

  try {
    const response = await fetch(`${normalizedUrl}/auth/v1/settings`, {
      method: "GET",
      mode: "cors",
      cache: "no-store",
      credentials: "omit",
      redirect: "follow",
      headers: {
        Accept: "application/json",
        apikey: normalizedKey,
        Authorization: `Bearer ${normalizedKey}`,
      },
      signal: controller.signal,
    });

    const rawBody = await response.text();
    let payload = null;
    try {
      payload = rawBody ? JSON.parse(rawBody) : null;
    } catch {
      payload = null;
    }

    if (response.ok && payload && typeof payload === "object" && !payload.error) {
      return {
        ok: true,
        kind: "reachable",
        status: response.status,
        host: parsedUrl.host,
      };
    }

    if (response.ok) {
      return {
        ok: false,
        kind: "malformed",
        status: response.status,
        host: parsedUrl.host,
        serverMessage: String(payload?.error || rawBody || "Unexpected empty response").slice(0, 300),
      };
    }

    const serverMessage =
      payload?.message || payload?.msg || payload?.error_description || payload?.error || rawBody;

    return {
      ok: false,
      kind: "http",
      status: response.status,
      host: parsedUrl.host,
      serverMessage: String(serverMessage || "").slice(0, 300),
    };
  } catch (error) {
    return {
      ok: false,
      kind: error?.name === "AbortError" ? "timeout" : "network",
      host: parsedUrl.host,
      browserMessage: error?.message || String(error),
    };
  } finally {
    clearTimeout(timeout);
  }
}
