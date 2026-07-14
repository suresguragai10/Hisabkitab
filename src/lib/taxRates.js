// ============================================================
// taxRates.js — loads VAT and TDS rates from the database.
// Falls back to Nepal's current statutory rates if DB is
// unavailable, so nothing crashes for existing users.
// ============================================================
import { useState, useEffect } from "react";
import { supabase } from "../supabase";

// Nepal statutory defaults (used if DB load fails)
export const DEFAULT_VAT_RATE = 13;

export const DEFAULT_TDS_TYPES = [
  { type: "rent",         label: "Rent",                       rate: 10   },
  { type: "professional", label: "Professional / Consulting",  rate: 15   },
  { type: "commission",   label: "Commission",                  rate: 15   },
  { type: "contractor",   label: "Contractor / Service",        rate: 1.5  },
  { type: "interest",     label: "Bank Interest",               rate: 5    },
  { type: "dividend",     label: "Dividend",                    rate: 5    },
  { type: "other",        label: "Other / Default",             rate: 10   },
];

// Fetch current effective rates from the database
export async function fetchTaxRates() {
  const { data, error } = await supabase.rpc("get_tax_rates");
  if (error || !data) return null;
  return data;
}

// Hook: returns { vatRate, tdsTypes, loading }
// vatRate  — the effective standard VAT rate (number, e.g. 13)
// tdsTypes — array of { type, label, rate } for TDS dropdowns
export function useTaxRates() {
  const [vatRate,  setVatRate]  = useState(DEFAULT_VAT_RATE);
  const [tdsTypes, setTdsTypes] = useState(DEFAULT_TDS_TYPES);
  const [loading,  setLoading]  = useState(true);

  useEffect(() => {
    fetchTaxRates()
      .then(rows => {
        if (!rows) return; // keep defaults
        const vat = rows.find(r => r.rate_type === "vat" && r.transaction_type === "standard");
        if (vat) setVatRate(Number(vat.rate));

        const tds = rows.filter(r => r.rate_type === "tds");
        if (tds.length > 0) {
          setTdsTypes(tds.map(r => ({ type: r.transaction_type, label: r.label, rate: Number(r.rate) })));
        }
      })
      .catch(() => {}) // keep defaults on error
      .finally(() => setLoading(false));
  }, []);

  return { vatRate, tdsTypes, loading };
}
