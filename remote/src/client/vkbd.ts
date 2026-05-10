import { applyStickyMods, ctrlLetter, keyToSequence } from "./input_sequences";
import { focusMobileTextInput, toggleMobileTextInput } from "./mobile_text_input";
import { activeSurfaceIdForInput, state } from "./state";

const kbdMods = { ctrl: false, alt: false };

type Sender = (surfaceId: string, data: string) => void;
let sender: Sender = () => {
  // no-op until transport registers
};

export function setVirtualKeyboardSender(send: Sender): void {
  sender = send;
}

export function renderVirtualKeyboardMarkup(): string {
  const key = (attrs: string, label: string, cls = ""): string =>
    `<button type="button" class="vkbd-key${cls ? ` ${cls}` : ""}" ${attrs}>${label}</button>`;
  return `
    <section class="vkbd" id="vkbd" data-mod-ctrl="false" data-mod-alt="false">
      <div class="vkbd-rows">
        <div class="vkbd-row">
          ${key('data-vk-key="esc"', "Esc")}
          ${key('data-vk-key="tab"', "Tab")}
          ${key('data-vk-key="up"', "↑")}
          ${key('data-vk-key="left"', "←")}
          ${key('data-vk-key="down"', "↓")}
          ${key('data-vk-key="right"', "→")}
        </div>
        <div class="vkbd-row">
          ${key('data-vk-ctrl="c"', "^C", "vkbd-pill")}
          ${key('data-vk-key="bksp"', "⌫")}
          ${key('data-vk-key="enter"', "⏎")}
          ${key('data-vk-key="ime" data-active="false"', "IME", "vkbd-wide vkbd-mod")}
        </div>
      </div>
    </section>
  `;
}

export function bindVirtualKeyboard(onHide: () => void): void {
  const vkbd = document.querySelector<HTMLElement>("#vkbd");
  if (!vkbd) return;

  const keepFocus = (event: Event) => event.preventDefault();

  vkbd.querySelectorAll<HTMLButtonElement>(".vkbd-key").forEach((button) => {
    let ignoreNextClick = false;
    let ignoreClickTimer: ReturnType<typeof setTimeout> | null = null;

    const armClickSuppression = (): void => {
      ignoreNextClick = true;
      if (ignoreClickTimer !== null) clearTimeout(ignoreClickTimer);
      ignoreClickTimer = setTimeout(() => {
        ignoreNextClick = false;
        ignoreClickTimer = null;
      }, 700);
    };

    button.addEventListener("mousedown", keepFocus);
    button.addEventListener("touchstart", keepFocus, { passive: false });
    button.addEventListener("touchend", (event) => {
      event.preventDefault();
      armClickSuppression();
      dispatchVirtualKey(button, onHide);
    }, { passive: false });
    button.addEventListener("click", (event) => {
      event.preventDefault();
      if (ignoreNextClick) {
        ignoreNextClick = false;
        if (ignoreClickTimer !== null) {
          clearTimeout(ignoreClickTimer);
          ignoreClickTimer = null;
        }
        return;
      }
      dispatchVirtualKey(button, onHide);
    });
  });
}

function dispatchVirtualKey(button: HTMLButtonElement, onHide: () => void): void {
  const vkbd = document.querySelector<HTMLElement>("#vkbd");
  if (!vkbd) return;

  if (button.dataset.vkMod) {
    const mod = button.dataset.vkMod as "ctrl" | "alt";
    kbdMods[mod] = !kbdMods[mod];
    button.dataset.active = String(kbdMods[mod]);
    vkbd.dataset[mod === "ctrl" ? "modCtrl" : "modAlt"] = String(kbdMods[mod]);
    return;
  }

  const surfaceId = activeSurfaceIdForInput();
  if (!surfaceId) return;

  if (button.dataset.vkKey === "type") {
    if (!focusMobileTextInput()) state.surfaceViews.get(surfaceId)?.term.focus();
    return;
  }

  if (button.dataset.vkKey === "ime") {
    button.dataset.active = String(toggleMobileTextInput());
    return;
  }

  if (button.dataset.vkKey === "hide") {
    onHide();
    return;
  }

  if (button.dataset.vkCtrl) {
    const seq = ctrlLetter(button.dataset.vkCtrl);
    if (seq) sender(surfaceId, seq);
    clearStickyMods();
    return;
  }

  if (button.dataset.vkText !== undefined) {
    const text = applyStickyMods(button.dataset.vkText, kbdMods);
    sender(surfaceId, text);
    clearStickyMods();
    return;
  }

  if (button.dataset.vkKey) {
    const seq = keyToSequence(button.dataset.vkKey);
    if (seq) {
      sender(surfaceId, seq);
      clearStickyMods();
    }
  }
}

function clearStickyMods(): void {
  if (!kbdMods.ctrl && !kbdMods.alt) return;
  kbdMods.ctrl = false;
  kbdMods.alt = false;
  const vkbd = document.querySelector<HTMLElement>("#vkbd");
  if (vkbd) {
    vkbd.dataset.modCtrl = "false";
    vkbd.dataset.modAlt = "false";
    vkbd.querySelectorAll<HTMLButtonElement>("[data-vk-mod]").forEach((btn) => {
      btn.dataset.active = "false";
    });
  }
}
