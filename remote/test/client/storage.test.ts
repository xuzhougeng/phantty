import test from "node:test";
import assert from "node:assert/strict";

import {
  readSavedSidebarCollapsed,
  saveSidebarCollapsed,
} from "../../src/client/storage";

const store = new Map<string, string>();

test("sidebar collapsed preference round-trips through storage", () => {
  installLocalStorage();

  saveSidebarCollapsed(true);
  assert.equal(readSavedSidebarCollapsed(), true);

  saveSidebarCollapsed(false);
  assert.equal(readSavedSidebarCollapsed(), false);
});

test("sidebar collapsed preference is nullable when unset", () => {
  installLocalStorage();

  assert.equal(readSavedSidebarCollapsed(), null);
});

function installLocalStorage(): void {
  store.clear();
  Object.defineProperty(globalThis, "localStorage", {
    configurable: true,
    value: {
      getItem(key: string): string | null {
        return store.get(key) ?? null;
      },
      setItem(key: string, value: string): void {
        store.set(key, value);
      },
    },
  });
}
