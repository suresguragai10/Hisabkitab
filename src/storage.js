/* =========================================================================
   storage.js  —  swappable persistence layer
   -------------------------------------------------------------------------
   The app only ever talks to: storage.get / storage.set / storage.delete
   Default implementation = browser localStorage (free, per-device).

   TO USE A REAL CLOUD DB (multi-device login):
   Replace the three functions below with calls to Supabase/Firebase/your API.
   As long as you keep the same signatures, nothing else in the app changes.

   Supabase example (pseudo):
     async get(key)        -> select value from kv where key = ?
     async set(key, value) -> upsert into kv (key, value)
     async delete(key)     -> delete from kv where key = ?
   ========================================================================= */

const PREFIX = "hisabkitab:";

export const storage = {
  async get(key) {
    try {
      const raw = localStorage.getItem(PREFIX + key);
      return raw == null ? null : { key, value: raw };
    } catch {
      return null;
    }
  },

  async set(key, value) {
    try {
      localStorage.setItem(PREFIX + key, value);
      return { key, value };
    } catch {
      return null;
    }
  },

  async delete(key) {
    try {
      localStorage.removeItem(PREFIX + key);
      return { key, deleted: true };
    } catch {
      return { key, deleted: false };
    }
  },
};

export default storage;
