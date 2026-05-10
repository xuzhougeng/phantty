import test from "node:test";
import assert from "node:assert/strict";

import {
  bindMobileTextInput,
  focusMobileTextInput,
  renderMobileTextInputMarkup,
  setMobileTextInputSender,
  toggleMobileTextInput,
} from "../../src/client/mobile_text_input";
import { state } from "../../src/client/state";

type Listener = (event: Record<string, unknown>) => void;

function preventableEvent(fields: Record<string, unknown>): Record<string, unknown> & { prevented: boolean } {
  return {
    ...fields,
    prevented: false,
    preventDefault() {
      this.prevented = true;
    },
  };
}

class FakeTextArea {
  value = "";
  focusCalls = 0;
  blurCalls = 0;
  private listeners = new Map<string, Listener[]>();

  addEventListener(type: string, listener: Listener): void {
    this.listeners.set(type, [...(this.listeners.get(type) ?? []), listener]);
  }

  dispatch(type: string, event: Record<string, unknown> = {}): void {
    for (const listener of this.listeners.get(type) ?? []) listener(event);
  }

  focus(): void {
    this.focusCalls += 1;
    fakeDocument.activeElement = this;
  }

  blur(): void {
    this.blurCalls += 1;
    if (fakeDocument.activeElement === this) fakeDocument.activeElement = null;
  }
}

const fakeDocument = {
  activeElement: null as FakeTextArea | null,
  textarea: new FakeTextArea(),
  querySelector(selector: string): FakeTextArea | null {
    return selector === "#mobile-text-input" ? this.textarea : null;
  },
};

function setup(mobile: boolean): { textarea: FakeTextArea; sent: string[] } {
  fakeDocument.activeElement = null;
  fakeDocument.textarea = new FakeTextArea();
  Object.defineProperty(globalThis, "document", {
    configurable: true,
    value: fakeDocument,
  });
  Object.defineProperty(globalThis, "window", {
    configurable: true,
    value: {
      matchMedia: () => ({ matches: mobile }),
    },
  });

  const sent: string[] = [];
  state.selectedSurfaceId = "surface-a";
  setMobileTextInputSender((_surfaceId, data) => sent.push(data));
  bindMobileTextInput();
  return { textarea: fakeDocument.textarea, sent };
}

test("focusMobileTextInput does not focus the hidden textarea on desktop", () => {
  const { textarea } = setup(false);

  assert.equal(focusMobileTextInput(), false);
  assert.equal(textarea.focusCalls, 0);
  assert.equal(fakeDocument.activeElement, null);
});

test("mobile text input is excluded from tab order", () => {
  assert.match(renderMobileTextInputMarkup(), /tabindex="-1"/);
});

test("desktop hidden text input events do not dispatch terminal bytes", () => {
  const { textarea, sent } = setup(false);

  textarea.value = "abc";
  textarea.dispatch("input");
  textarea.dispatch("beforeinput", preventableEvent({ inputType: "insertLineBreak" }));
  textarea.dispatch("beforeinput", preventableEvent({ inputType: "deleteContentBackward" }));
  textarea.dispatch("keydown", preventableEvent({ key: "Enter" }));
  textarea.dispatch("keydown", preventableEvent({ key: "Backspace" }));

  assert.deepEqual(sent, []);
});

test("focusMobileTextInput focuses the hidden textarea on mobile", () => {
  const { textarea } = setup(true);

  assert.equal(focusMobileTextInput(), true);
  assert.equal(textarea.focusCalls, 1);
  assert.equal(fakeDocument.activeElement, textarea);
});

test("toggleMobileTextInput opens and closes the mobile IME target", () => {
  const { textarea } = setup(true);

  assert.equal(toggleMobileTextInput(), true);
  assert.equal(textarea.focusCalls, 1);
  assert.equal(fakeDocument.activeElement, textarea);

  assert.equal(toggleMobileTextInput(), false);
  assert.equal(textarea.blurCalls, 1);
  assert.equal(fakeDocument.activeElement, null);
});

test("mobile text input dispatches committed composition text exactly once", () => {
  const { textarea, sent } = setup(true);

  textarea.dispatch("compositionstart");
  textarea.value = "n";
  textarea.dispatch("input");
  textarea.value = "你";
  textarea.dispatch("compositionend");

  assert.deepEqual(sent, ["你"]);
  assert.equal(textarea.value, "");
});

test("mobile text input does not dispatch control bytes while composing", () => {
  const { textarea, sent } = setup(true);

  textarea.dispatch("compositionstart");
  const beforeInputBackspace = preventableEvent({
    inputType: "deleteContentBackward",
    isComposing: true,
  });
  textarea.dispatch("beforeinput", beforeInputBackspace);
  const keydownBackspace = preventableEvent({ key: "Backspace", isComposing: true });
  textarea.dispatch("keydown", keydownBackspace);
  const keydownEnter = preventableEvent({ key: "Enter", isComposing: true });
  textarea.dispatch("keydown", keydownEnter);

  assert.deepEqual(sent, []);
  assert.equal(beforeInputBackspace.prevented, false);
  assert.equal(keydownBackspace.prevented, false);
  assert.equal(keydownEnter.prevented, false);

  textarea.value = "你";
  textarea.dispatch("compositionend");
  assert.deepEqual(sent, ["你"]);
});

test("mobile text input ignores trailing input with already committed composition text", () => {
  const { textarea, sent } = setup(true);

  textarea.dispatch("compositionstart");
  textarea.value = "n";
  textarea.dispatch("input");
  textarea.value = "你";
  textarea.dispatch("compositionend");
  textarea.value = "你";
  textarea.dispatch("input");

  assert.deepEqual(sent, ["你"]);
  assert.equal(textarea.value, "");
});

test("mobile text input sends later same-valued input after composition suppression expires", async () => {
  const { textarea, sent } = setup(true);

  textarea.dispatch("compositionstart");
  textarea.value = "你";
  textarea.dispatch("compositionend");

  await new Promise((resolve) => setTimeout(resolve, 0));

  textarea.value = "你";
  textarea.dispatch("input");

  assert.deepEqual(sent, ["你", "你"]);
  assert.equal(textarea.value, "");
});
