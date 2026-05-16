import test from "node:test";
import assert from "node:assert/strict";

import {
  readSavedDesktopPanelMode,
  readSavedMobileVisualZoom,
  readSavedSidebarCollapsed,
  saveDesktopPanelMode,
  saveMobileVisualZoom,
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

test("desktop panel mode preference round-trips through storage", () => {
  installLocalStorage();

  assert.equal(readSavedDesktopPanelMode(), "layout");

  saveDesktopPanelMode("single");
  assert.equal(readSavedDesktopPanelMode(), "single");

  saveDesktopPanelMode("layout");
  assert.equal(readSavedDesktopPanelMode(), "layout");
});

test("desktop panel mode ignores invalid stored values", () => {
  installLocalStorage();

  store.set("phantty.remote.desktopPanelMode", "wide");

  assert.equal(readSavedDesktopPanelMode(), "layout");
});

test("mobile visual zoom preference round-trips through storage", () => {
  installLocalStorage();

  assert.equal(readSavedMobileVisualZoom(), 1);

  saveMobileVisualZoom(0.5);
  assert.equal(readSavedMobileVisualZoom(), 0.5);

  saveMobileVisualZoom(0.25);
  assert.equal(readSavedMobileVisualZoom(), 0.25);
});

test("mobile visual zoom ignores invalid stored values", () => {
  installLocalStorage();

  store.set("phantty.remote.mobileVisualZoom", "0.9");

  assert.equal(readSavedMobileVisualZoom(), 1);
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
