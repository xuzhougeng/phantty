import test from "node:test";
import assert from "node:assert/strict";

import {
  applyStickyMods,
  ctrlLetter,
  keyToSequence,
} from "../../src/client/input_sequences";

test("keyToSequence returns terminal escape sequences for special keys", () => {
  assert.equal(keyToSequence("esc"), "\x1b");
  assert.equal(keyToSequence("tab"), "\t");
  assert.equal(keyToSequence("up"), "\x1b[A");
  assert.equal(keyToSequence("down"), "\x1b[B");
  assert.equal(keyToSequence("right"), "\x1b[C");
  assert.equal(keyToSequence("left"), "\x1b[D");
  assert.equal(keyToSequence("bksp"), "\x7f");
  assert.equal(keyToSequence("enter"), "\r");
  assert.equal(keyToSequence("unknown"), null);
});

test("ctrlLetter maps letters to C0 control characters", () => {
  assert.equal(ctrlLetter("a"), "\x01");
  assert.equal(ctrlLetter("c"), "\x03");
  assert.equal(ctrlLetter("z"), "\x1a");
  assert.equal(ctrlLetter("1"), null);
});

test("applyStickyMods applies ctrl and alt to single characters", () => {
  assert.equal(applyStickyMods("c", { ctrl: true, alt: false }), "\x03");
  assert.equal(applyStickyMods("x", { ctrl: false, alt: true }), "\x1bx");
  assert.equal(applyStickyMods("/", { ctrl: true, alt: false }), "/");
  assert.equal(applyStickyMods("long", { ctrl: true, alt: true }), "long");
});
