import { describe, it, expect } from "vitest";
import { confirmDialog, promptDialog, subscribeDialog, getDialogState } from "./dialogs";

describe("confirmDialog", () => {
  it("resolves true/false based on what the subscriber calls resolve with", async () => {
    const unsubscribe = subscribeDialog((state) => {
      if (state) state.resolve(true);
    });
    await expect(confirmDialog("Delete this?")).resolves.toBe(true);
    unsubscribe();
  });

  it("clears dialog state after resolving, so a stale dialog can't reappear", async () => {
    const unsubscribe = subscribeDialog((state) => {
      if (state) state.resolve(false);
    });
    await confirmDialog("Delete this?");
    expect(getDialogState()).toBeNull();
    unsubscribe();
  });
});

describe("promptDialog", () => {
  it("resolves with the value the subscriber submits", async () => {
    const unsubscribe = subscribeDialog((state) => {
      if (state) state.resolve("a real reason");
    });
    await expect(promptDialog("Why?")).resolves.toBe("a real reason");
    unsubscribe();
  });

  it("resolves null when cancelled", async () => {
    const unsubscribe = subscribeDialog((state) => {
      if (state) state.resolve(null);
    });
    await expect(promptDialog("Why?")).resolves.toBeNull();
    unsubscribe();
  });
});
