import React, { useState, useEffect } from "react";
import { adToBs, bsToAd, BS_MONTHS_EN, BS_MONTHS_NP, formatDualDate } from "../lib/nepaliCalendar";
import { getLang } from "../lib/i18n";

// ============================================================
// BsDateInput — shows a BS date picker with dual AD/BS display.
// Props:
//   value: AD date string "YYYY-MM-DD"
//   onChange: called with new AD date string "YYYY-MM-DD"
//   lang: "en" | "np"
// ============================================================

export default function BsDateInput({ value, onChange, lang }) {
  const l = lang || getLang();
  const monthNames = l === "np" ? BS_MONTHS_NP : BS_MONTHS_EN;

  const today = new Date();
  const bs = value ? adToBs(new Date(value)) : adToBs(today);

  const [bsYear, setBsYear] = useState(bs.year);
  const [bsMonth, setBsMonth] = useState(bs.month);
  const [bsDay, setBsDay] = useState(bs.day);

  // When BS fields change, convert to AD and call onChange
  useEffect(() => {
    const ad = bsToAd(bsYear, bsMonth, bsDay);
    if (ad) {
      const adStr = ad.toISOString().slice(0, 10);
      onChange && onChange(adStr);
    }
  }, [bsYear, bsMonth, bsDay]);

  // When value prop changes externally, sync BS fields
  useEffect(() => {
    if (value) {
      const b = adToBs(new Date(value));
      setBsYear(b.year);
      setBsMonth(b.month);
      setBsDay(b.day);
    }
  }, [value]);

  const years = Array.from({ length: 20 }, (_, i) => 2075 + i);
  const days = Array.from({ length: 32 }, (_, i) => i + 1);

  const dual = value ? formatDualDate(new Date(value), l) : "";

  return (
    <div className="bs-date-wrap">
      <div className="bs-date-selects">
        <select value={bsYear} onChange={e => setBsYear(Number(e.target.value))}>
          {years.map(y => <option key={y} value={y}>{y}</option>)}
        </select>
        <select value={bsMonth} onChange={e => setBsMonth(Number(e.target.value))}>
          {monthNames.map((m, i) => <option key={i} value={i}>{m}</option>)}
        </select>
        <select value={bsDay} onChange={e => setBsDay(Number(e.target.value))}>
          {days.map(d => <option key={d} value={d}>{d}</option>)}
        </select>
      </div>
      {dual && <div className="bs-dual-label">{dual}</div>}
    </div>
  );
}
