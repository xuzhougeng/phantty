import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

import { remoteTabSelectionSidebarAction } from "../../src/client/sidebar_behavior";

const consoleViewUrl = new URL("../../src/client/views/console.ts", import.meta.url);

test("remote tab selection closes the mobile drawer", () => {
  assert.equal(remoteTabSelectionSidebarAction(true), "close-drawer");
});

test("remote tab selection collapses the desktop sidebar", () => {
  assert.equal(remoteTabSelectionSidebarAction(false), "collapse-sidebar");
});

test("remote tab clicks apply the sidebar selection action after switching workspace", async () => {
  const markup = await readFile(consoleViewUrl, "utf8");

  assert.match(markup, /renderRemoteWorkspace\(\);\s+applyRemoteTabSelectionSidebarAction\(\);/);
});
