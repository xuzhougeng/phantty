import { isMobileRemoteShell } from "./mobile_layout";
import { activeSurfaceIdForInput } from "./state";

type Sender = (surfaceId: string, data: string) => void;

let sender: Sender = () => {
  // no-op until transport registers
};

let inputEl: HTMLTextAreaElement | null = null;
let isComposing = false;
let pendingCommittedComposition: string | null = null;
let pendingCommittedCompositionTimer: ReturnType<typeof setTimeout> | null = null;

export function setMobileTextInputSender(send: Sender): void {
  sender = send;
}

export function renderMobileTextInputMarkup(): string {
  return `
    <textarea
      id="mobile-text-input"
      class="mobile-text-input"
      aria-label="Terminal text input"
      autocomplete="off"
      autocapitalize="off"
      autocorrect="off"
      spellcheck="false"
      tabindex="-1"
      rows="1"
    ></textarea>
  `;
}

export function bindMobileTextInput(): void {
  inputEl = document.querySelector<HTMLTextAreaElement>("#mobile-text-input");
  isComposing = false;
  clearPendingCommittedComposition();
  if (!inputEl) return;

  inputEl.addEventListener("beforeinput", (event) => {
    const inputEvent = event as InputEvent;
    if (!shouldHandleMobileInput() || isComposing || inputEvent.isComposing) return;
    if (inputEvent.inputType === "insertLineBreak") {
      event.preventDefault();
      dispatchText("\r");
      clearInputValue();
      return;
    }
    if (inputEvent.inputType === "deleteContentBackward") {
      event.preventDefault();
      dispatchText("\x7f");
      clearInputValue();
    }
  });

  inputEl.addEventListener("keydown", (event) => {
    if (!shouldHandleMobileInput() || isComposing || event.isComposing) return;
    if (event.key === "Enter") {
      event.preventDefault();
      dispatchText("\r");
      clearInputValue();
      return;
    }
    if (event.key === "Backspace" && !inputEl?.value) {
      event.preventDefault();
      dispatchText("\x7f");
    }
  });

  inputEl.addEventListener("compositionstart", () => {
    if (!shouldHandleMobileInput()) return;
    isComposing = true;
    clearPendingCommittedComposition();
  });

  inputEl.addEventListener("input", () => {
    if (!shouldHandleMobileInput() || isComposing) return;
    if (!inputEl?.value) return;
    if (pendingCommittedComposition === inputEl.value) {
      clearPendingCommittedComposition();
      clearInputValue();
      return;
    }
    clearPendingCommittedComposition();
    dispatchText(inputEl.value);
    clearInputValue();
  });

  inputEl.addEventListener("compositionend", () => {
    isComposing = false;
    if (!shouldHandleMobileInput()) {
      clearPendingCommittedComposition();
      return;
    }
    if (!inputEl?.value) return;
    const committedText = inputEl.value;
    armPendingCommittedComposition(committedText);
    dispatchText(committedText);
    clearInputValue();
  });
}

export function focusMobileTextInput(): boolean {
  if (!isMobileRemoteShell()) return false;
  const input = inputEl ?? document.querySelector<HTMLTextAreaElement>("#mobile-text-input");
  if (!input) return false;
  inputEl = input;
  input.focus({ preventScroll: true });
  return document.activeElement === input;
}

export function toggleMobileTextInput(): boolean {
  if (!isMobileRemoteShell()) return false;
  const input = inputEl ?? document.querySelector<HTMLTextAreaElement>("#mobile-text-input");
  if (!input) return false;
  inputEl = input;
  if (document.activeElement === input) {
    input.blur();
    return false;
  }
  input.focus({ preventScroll: true });
  return document.activeElement === input;
}

function dispatchText(text: string): void {
  if (!shouldHandleMobileInput()) return;
  const surfaceId = activeSurfaceIdForInput();
  if (!surfaceId || !text) return;
  sender(surfaceId, text);
}

function clearInputValue(): void {
  if (inputEl) inputEl.value = "";
}

function armPendingCommittedComposition(text: string): void {
  clearPendingCommittedComposition();
  pendingCommittedComposition = text;
  pendingCommittedCompositionTimer = setTimeout(() => {
    pendingCommittedComposition = null;
    pendingCommittedCompositionTimer = null;
  }, 0);
}

function clearPendingCommittedComposition(): void {
  pendingCommittedComposition = null;
  if (pendingCommittedCompositionTimer !== null) {
    clearTimeout(pendingCommittedCompositionTimer);
    pendingCommittedCompositionTimer = null;
  }
}

function shouldHandleMobileInput(): boolean {
  return isMobileRemoteShell();
}
