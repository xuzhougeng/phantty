import test from "node:test";
import assert from "node:assert/strict";

import { REMOTE_TERMINAL_SCROLLBACK } from "../../src/client/terminal_options";

test("remote xterm keeps enough scrollback for synced history", () => {
  assert.ok(REMOTE_TERMINAL_SCROLLBACK >= 5000);
});
