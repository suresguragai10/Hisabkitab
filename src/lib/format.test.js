import { describe, it, expect } from "vitest";
import { formatMoney } from "./format";

describe("formatMoney", () => {
  it("defaults to 2 forced decimal places, browser-default locale", () => {
    expect(formatMoney(1234.5)).toBe((1234.5).toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 }));
  });

  it("treats null/undefined/NaN as zero", () => {
    expect(formatMoney(null)).toBe((0).toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 }));
    expect(formatMoney(undefined)).toBe(formatMoney(0));
  });

  it("supports a locale override (e.g. en-IN digit grouping)", () => {
    expect(formatMoney(100000, { locale: "en-IN" })).toBe((100000).toLocaleString("en-IN", { minimumFractionDigits: 2, maximumFractionDigits: 2 }));
  });

  it("supports overriding minimum/maximum fraction digits independently (e.g. quantities)", () => {
    expect(formatMoney(1.5, { minimumFractionDigits: 0, maximumFractionDigits: 3 })).toBe(
      (1.5).toLocaleString(undefined, { minimumFractionDigits: 0, maximumFractionDigits: 3 })
    );
  });
});
