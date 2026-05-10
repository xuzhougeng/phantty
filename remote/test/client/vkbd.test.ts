import test from "node:test";
import assert from "node:assert/strict";

import { bindVirtualKeyboard, renderVirtualKeyboardMarkup, setVirtualKeyboardSender } from "../../src/client/vkbd";
import { state } from "../../src/client/state";

type Listener = (event: { preventDefault(): void }) => void;

class FakeButton {
  dataset: Record<string, string>;
  private listeners = new Map<string, Listener[]>();

  constructor(dataset: Record<string, string>) {
    this.dataset = dataset;
  }

  addEventListener(type: string, listener: Listener): void {
    this.listeners.set(type, [...(this.listeners.get(type) ?? []), listener]);
  }

  click(): void {
    const event = { preventDefault() {} };
    for (const listener of this.listeners.get("click") ?? []) listener(event);
  }

  touchTap(): void {
    const event = { preventDefault() {} };
    for (const listener of this.listeners.get("touchstart") ?? []) listener(event);
    for (const listener of this.listeners.get("touchend") ?? []) listener(event);
  }
}

class FakeKeyboard {
  dataset: Record<string, string> = { modCtrl: "false", modAlt: "false" };

  constructor(private buttons: FakeButton[]) {}

  querySelectorAll(selector: string): FakeButton[] {
    if (selector === ".vkbd-key") return this.buttons;
    if (selector === "[data-vk-mod]") return this.buttons.filter((button) => button.dataset.vkMod);
    return [];
  }
}

class FakeTextArea {
  focusCalls = 0;
  blurCalls = 0;

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
};

test("sticky modifiers clear after special keys", () => {
  const ctrl = new FakeButton({ vkMod: "ctrl", active: "false" });
  const enter = new FakeButton({ vkKey: "enter" });
  const text = new FakeButton({ vkText: "c" });
  const keyboard = new FakeKeyboard([ctrl, enter, text]);

  Object.defineProperty(globalThis, "document", {
    configurable: true,
    value: {
      querySelector(selector: string): FakeKeyboard | null {
        return selector === "#vkbd" ? keyboard : null;
      },
    },
  });

  const sent: string[] = [];
  state.selectedSurfaceId = "surface-a";
  setVirtualKeyboardSender((_surfaceId, data) => sent.push(data));
  bindVirtualKeyboard(() => {});

  ctrl.click();
  enter.click();
  text.click();

  assert.deepEqual(sent, ["\r", "c"]);
  assert.equal(keyboard.dataset.modCtrl, "false");
  assert.equal(ctrl.dataset.active, "false");
});

test("virtual keyboard markup keeps the compact control key set", () => {
  const markup = renderVirtualKeyboardMarkup();

  for (const label of ["Esc", "Tab", "↑", "←", "↓", "→", "^C", "⌫", "⏎", "IME"]) {
    assert.match(markup, new RegExp(`>${escapeRegExp(label)}<`));
  }

  for (const label of ["Ctrl", "Alt", "^D", "^L", "^R", "^Z", "Type"]) {
    assert.doesNotMatch(markup, new RegExp(`>${escapeRegExp(label)}<`));
  }

  assert.doesNotMatch(markup, /data-vk-text=/);
  assert.doesNotMatch(markup, /data-vk-mod=/);
});

test("IME key toggles the mobile text input focus target", () => {
  const ime = new FakeButton({ vkKey: "ime", active: "false" });
  const keyboard = new FakeKeyboard([ime]);

  setupDocument(keyboard, true);

  state.selectedSurfaceId = "surface-a";
  bindVirtualKeyboard(() => {});

  ime.click();
  assert.equal(fakeDocument.textarea.focusCalls, 1);
  assert.equal(fakeDocument.activeElement, fakeDocument.textarea);
  assert.equal(ime.dataset.active, "true");

  ime.click();
  assert.equal(fakeDocument.textarea.blurCalls, 1);
  assert.equal(fakeDocument.activeElement, null);
  assert.equal(ime.dataset.active, "false");
});

test("touch activation dispatches virtual keys without a synthesized click", () => {
  const enter = new FakeButton({ vkKey: "enter" });
  const keyboard = new FakeKeyboard([enter]);

  Object.defineProperty(globalThis, "document", {
    configurable: true,
    value: {
      querySelector(selector: string): FakeKeyboard | null {
        return selector === "#vkbd" ? keyboard : null;
      },
    },
  });

  const sent: string[] = [];
  state.selectedSurfaceId = "surface-a";
  setVirtualKeyboardSender((_surfaceId, data) => sent.push(data));
  bindVirtualKeyboard(() => {});

  enter.touchTap();

  assert.deepEqual(sent, ["\r"]);
});

test("touch activation suppresses the following synthesized click", () => {
  const enter = new FakeButton({ vkKey: "enter" });
  const keyboard = new FakeKeyboard([enter]);

  Object.defineProperty(globalThis, "document", {
    configurable: true,
    value: {
      querySelector(selector: string): FakeKeyboard | null {
        return selector === "#vkbd" ? keyboard : null;
      },
    },
  });

  const sent: string[] = [];
  state.selectedSurfaceId = "surface-a";
  setVirtualKeyboardSender((_surfaceId, data) => sent.push(data));
  bindVirtualKeyboard(() => {});

  enter.touchTap();
  enter.click();

  assert.deepEqual(sent, ["\r"]);
});

function setupDocument(keyboard: FakeKeyboard, mobile: boolean): void {
  fakeDocument.activeElement = null;
  fakeDocument.textarea = new FakeTextArea();
  Object.defineProperty(globalThis, "document", {
    configurable: true,
    value: {
      get activeElement() {
        return fakeDocument.activeElement;
      },
      querySelector(selector: string): FakeKeyboard | FakeTextArea | null {
        if (selector === "#vkbd") return keyboard;
        if (selector === "#mobile-text-input") return fakeDocument.textarea;
        return null;
      },
    },
  });
  Object.defineProperty(globalThis, "window", {
    configurable: true,
    value: {
      matchMedia: () => ({ matches: mobile }),
    },
  });
}

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}
