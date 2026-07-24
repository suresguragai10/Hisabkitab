import { describe, it, expect } from "vitest";
import {
  adToBs,
  bsToAd,
  bsFiscalYearFor,
  toLocalDateString,
  BS_MONTHS_EN,
} from "./nepaliCalendar";

// Shrawan 1, 2083 BS = July 17, 2026 AD, confirmed against an authoritative
// live Nepali date-conversion source while fixing the fiscal-period
// calendar bug (2026-07-23). This is the one fixed, external ground-truth
// point every other assertion here is built around.
const SHRAWAN_1_2083 = { bsYear: 2083, bsMonth: BS_MONTHS_EN.indexOf("Shrawan"), adDate: "2026-07-17" };

describe("bsToAd / adToBs", () => {
  it("matches the verified ground-truth conversion (Shrawan 1, 2083 = 2026-07-17)", () => {
    const ad = bsToAd(SHRAWAN_1_2083.bsYear, SHRAWAN_1_2083.bsMonth, 1);
    expect(toLocalDateString(ad)).toBe(SHRAWAN_1_2083.adDate);
  });

  it("round-trips every month boundary of BS 2083 and 2084 without drift", () => {
    for (const bsYear of [2083, 2084]) {
      for (let bsMonth = 0; bsMonth < 12; bsMonth++) {
        const ad = bsToAd(bsYear, bsMonth, 1);
        const back = adToBs(ad);
        expect(back).toEqual({ year: bsYear, month: bsMonth, day: 1 });
      }
    }
  });

  it("accepts a YYYY-MM-DD string the same way it accepts a Date object", () => {
    const ad = bsToAd(SHRAWAN_1_2083.bsYear, SHRAWAN_1_2083.bsMonth, 1);
    const fromString = adToBs(toLocalDateString(ad));
    const fromDate = adToBs(ad);
    expect(fromString).toEqual(fromDate);
  });

  it("does not shift by a day regardless of the JS Date's local timezone", () => {
    // This is the exact bug class found and fixed this session: parsing a
    // date-only string via `new Date(str)` anchors it to UTC midnight,
    // which lands on the wrong local day in positive-UTC-offset zones.
    const ad = bsToAd(2083, 3, 1); // Shrawan 1, 2083
    expect(ad.getFullYear()).toBe(2026);
    expect(ad.getMonth()).toBe(6); // July, 0-indexed
    expect(ad.getDate()).toBe(17);
  });

  it("returns null for a BS year outside the supported table range", () => {
    expect(bsToAd(1999, 0, 1)).toBeNull();
    expect(bsToAd(2091, 0, 1)).toBeNull();
  });
});

describe("bsFiscalYearFor", () => {
  it("labels a Shrawan date as the start of a new fiscal year", () => {
    // Shrawan 2083 = the first month of fiscal year 2083-84.
    const shrawanStart = bsToAd(2083, BS_MONTHS_EN.indexOf("Shrawan"), 1);
    expect(bsFiscalYearFor(shrawanStart)).toBe("2083-84");
  });

  it("labels an Ashadh date as the end of the previous fiscal year", () => {
    // Ashadh 2083 = the last month of fiscal year 2082-83, not 2083-84.
    const ashadhEnd = bsToAd(2083, BS_MONTHS_EN.indexOf("Ashadh"), 1);
    expect(bsFiscalYearFor(ashadhEnd)).toBe("2082-83");
  });
});

describe("toLocalDateString", () => {
  it("formats as zero-padded YYYY-MM-DD", () => {
    expect(toLocalDateString(new Date(2026, 0, 5))).toBe("2026-01-05");
    expect(toLocalDateString(new Date(2026, 11, 31))).toBe("2026-12-31");
  });
});
