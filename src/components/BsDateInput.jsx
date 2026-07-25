import React, { useState, useEffect } from "react";
import { adToBs, bsToAd, daysInBsMonth, BS_MIN_YEAR, BS_MAX_YEAR, BS_MONTHS_EN, BS_MONTHS_NP, formatDualDate, toLocalDateString } from "../lib/nepaliCalendar";
import { getLang } from "../lib/i18n";

// ============================================================
// BsDateInput — shows a BS date picker with dual AD/BS display.
// Props:
//   value: AD date string "YYYY-MM-DD"
//   onChange: called with new AD date string "YYYY-MM-DD"
//   lang: "en" | "np"
// ============================================================

// Today's BS date, used whenever conversion fails so the picker never
// crashes -- adToBs returns null for a date outside the supported
// table (e.g. bad data), and "today" is always safely in range.
function safeBs(adValue) {
  return (adValue ? adToBs(adValue) : null) || adToBs(new Date());
}

export default function BsDateInput({ value, onChange, lang }) {
  const l = lang || getLang();
  const monthNames = l === "np" ? BS_MONTHS_NP : BS_MONTHS_EN;

  const bs = safeBs(value);

  const [bsYear, setBsYear] = useState(bs.year);
  const [bsMonth, setBsMonth] = useState(bs.month);
  const [bsDay, setBsDay] = useState(bs.day);

  const monthLength = daysInBsMonth(bsYear, bsMonth) || 30;

  // When BS fields change, convert to AD and call onChange
  useEffect(() => {
    const ad = bsToAd(bsYear, bsMonth, bsDay);
    if (ad) {
      const adStr = toLocalDateString(ad);
      onChange && onChange(adStr);
    }
  }, [bsYear, bsMonth, bsDay]);

  // If the selected month/year has fewer days than the current
  // selection, pull the day back into range instead of leaving an
  // invalid date silently in place.
  useEffect(() => {
    if (bsDay > monthLength) setBsDay(monthLength);
  }, [monthLength]);

  // When value prop changes externally, sync BS fields
  useEffect(() => {
    if (value) {
      const b = safeBs(value);
      setBsYear(b.year);
      setBsMonth(b.month);
      setBsDay(b.day);
    }
  }, [value]);

  // A window around today's BS year is plenty for everyday invoice/bill
  // dates -- clamped to what the table actually supports, so the picker
  // can never offer a year beyond BS_MAX_YEAR (unlike the old fixed
  // 2075-2094 range, which silently overshot it by 4 years).
  const todayYear = adToBs(new Date())?.year ?? BS_MIN_YEAR;
  const yearsLow = Math.max(BS_MIN_YEAR, todayYear - 10);
  const yearsHigh = Math.min(BS_MAX_YEAR, todayYear + 10);
  const years = Array.from({ length: yearsHigh - yearsLow + 1 }, (_, i) => yearsLow + i);
  const days = Array.from({ length: monthLength }, (_, i) => i + 1);

  const dual = value ? formatDualDate(value, l) : "";

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
