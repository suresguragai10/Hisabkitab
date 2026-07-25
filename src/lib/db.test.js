import { describe, it, expect, vi } from "vitest";

// Never let a test reach the real network -- createVoucher's valid-input
// path calls supabase.rpc(), which would otherwise hit the live production
// Supabase project these credentials point to.
vi.mock("../supabase", () => ({
  supabase: {
    rpc: vi.fn(() => Promise.resolve({ data: "mock-voucher-id", error: null })),
    from: vi.fn(() => ({
      select: vi.fn(() => ({
        eq: vi.fn(() => ({
          single: vi.fn(() => Promise.resolve({ data: { id: "mock-voucher-id" }, error: null })),
        })),
      })),
    })),
  },
}));

const { createVoucher } = await import("./db");

// createVoucher validates locally and throws before ever calling
// supabase.rpc(), so these guard clauses are testable without a live
// database connection -- this is the client-side half of the audit's
// "every voucher balances" invariant. The server-side half
// (post_voucher's own debit/credit check) can't be exercised here;
// it needs a real Postgres connection this environment doesn't have.
describe("createVoucher balance validation", () => {
  const header = { voucher_type: "journal", fiscal_year: "2082-83", voucher_date: "2026-01-01" };

  it("rejects fewer than two lines", async () => {
    await expect(
      createVoucher(null, header, [{ accountId: "a", debit: 100, credit: 0 }])
    ).rejects.toThrow("at least two lines");
  });

  it("rejects unbalanced debit/credit totals", async () => {
    await expect(
      createVoucher(null, header, [
        { accountId: "a", debit: 100, credit: 0 },
        { accountId: "b", debit: 0, credit: 90 },
      ])
    ).rejects.toThrow(/must be equal/);
  });

  it("rejects a zero-amount voucher even when balanced", async () => {
    await expect(
      createVoucher(null, header, [
        { accountId: "a", debit: 0, credit: 0 },
        { accountId: "b", debit: 0, credit: 0 },
      ])
    ).rejects.toThrow("greater than zero");
  });

  it("tolerates sub-paisa rounding noise but not a real imbalance", async () => {
    await expect(
      createVoucher(null, header, [
        { accountId: "a", debit: 100.001, credit: 0 },
        { accountId: "b", debit: 0, credit: 100.002 },
      ])
    ).resolves.not.toThrow();
  });
});
