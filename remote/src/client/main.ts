import { Terminal } from "@xterm/xterm";
import { FitAddon } from "@xterm/addon-fit";
import "@xterm/xterm/css/xterm.css";
import "./styles.css";

type MeResponse = { authenticated: boolean; username?: string };

type LayoutSurface = {
  id: string;
  title?: string;
  focused?: boolean;
  snapshot?: string;
  cols?: number;
  rows?: number;
  cursorX?: number;
  cursorY?: number;
  x?: number;
  y?: number;
  w?: number;
  h?: number;
};

type LayoutTab = {
  index: number;
  title?: string;
  focusedSurfaceId?: string;
  surfaces: LayoutSurface[];
};

type RelayMessage = {
  type?: unknown;
  data?: unknown;
  encoding?: unknown;
  message?: unknown;
  surfaceId?: unknown;
  activeTab?: unknown;
  tabs?: unknown;
};

type SurfaceView = {
  panel: HTMLElement;
  title: HTMLSpanElement;
  meta: HTMLElement;
  host: HTMLDivElement;
  term: Terminal;
  fit: FitAddon;
  decoder: TextDecoder;
  disposeInput: { dispose(): void };
  disposeMiddleClickGesture: (() => void) | null;
  resizeObserver: ResizeObserver | null;
  fitQueued: boolean;
  hasLiveOutput: boolean;
  snapshotApplied: boolean;
  opened: boolean;
  pendingOutput: string;
  remoteCols: number | null;
  remoteRows: number | null;
};

const SESSION_KEY_STORAGE_KEY = "phantty.remote.sessionKey";
const KBD_VISIBLE_STORAGE_KEY = "phantty.remote.kbdVisible";
const THEME_STORAGE_KEY = "phantty.remote.theme";

type ThemeMode = "dark" | "light";

const THEME_TERMINAL_PALETTES: Record<ThemeMode, {
  background: string;
  foreground: string;
  cursor: string;
  selectionBackground: string;
}> = {
  dark: {
    background: "#090f17",
    foreground: "#dce7f3",
    cursor: "#ffd479",
    selectionBackground: "#334155",
  },
  light: {
    background: "#fbf6ec",
    foreground: "#1c2330",
    cursor: "#b97a3d",
    selectionBackground: "#d6cdb8",
  },
};

let themeMode: ThemeMode = readSavedTheme();
applyThemeAttribute(themeMode);

function readSavedTheme(): ThemeMode {
  try {
    const raw = localStorage.getItem(THEME_STORAGE_KEY);
    if (raw === "light" || raw === "dark") return raw;
  } catch {
    // localStorage may be unavailable.
  }
  return "dark";
}

function applyThemeAttribute(mode: ThemeMode): void {
  if (mode === "light") {
    document.documentElement.dataset.theme = "light";
  } else {
    delete document.documentElement.dataset.theme;
  }
}

function setTheme(mode: ThemeMode): void {
  themeMode = mode;
  applyThemeAttribute(mode);
  try {
    localStorage.setItem(THEME_STORAGE_KEY, mode);
  } catch {
    // Storage may be unavailable.
  }
  const palette = THEME_TERMINAL_PALETTES[mode];
  for (const view of surfaceViews.values()) {
    view.term.options.theme = palette;
  }
  updateThemeToggleButtons();
}

function toggleTheme(): void {
  setTheme(themeMode === "dark" ? "light" : "dark");
}

function updateThemeToggleButtons(): void {
  const label = themeMode === "dark" ? "Switch to light theme" : "Switch to dark theme";
  const icon = themeMode === "dark" ? iconSun() : iconMoon();
  document.querySelectorAll<HTMLButtonElement>("[data-theme-toggle]").forEach((button) => {
    button.setAttribute("aria-label", label);
    button.title = label;
    button.innerHTML = icon;
  });
}

function bindThemeToggleButtons(): void {
  document.querySelectorAll<HTMLButtonElement>("[data-theme-toggle]").forEach((button) => {
    button.addEventListener("click", toggleTheme);
  });
  updateThemeToggleButtons();
}
const HEARTBEAT_INTERVAL_MS = 25_000;
const HEARTBEAT_WATCHDOG_MS = 50_000;
const RECONNECT_MIN_DELAY_MS = 1_000;
const RECONNECT_MAX_DELAY_MS = 30_000;

const appRoot = document.querySelector<HTMLElement>("#app");

if (!appRoot) {
  throw new Error("Missing app root");
}

const app: HTMLElement = appRoot;
const encoder = new TextEncoder();

let socket: WebSocket | null = null;
let layoutState: { activeTab: number; tabs: LayoutTab[] } | null = null;
let selectedTabIndex = 0;
let selectedSurfaceId: string | null = null;
let surfaceViews = new Map<string, SurfaceView>();
let notices: string[] = [];
let hasSeenLayout = false;
let kbdVisible = readSavedKbdVisible() ?? true;
let drawerOpen = false;
const kbdMods = { ctrl: false, alt: false };

let activeSessionKey: string | null = null;
let reconnectAttempts = 0;
let reconnectTimer: ReturnType<typeof setTimeout> | null = null;
let pingTimer: ReturnType<typeof setInterval> | null = null;
let watchdogTimer: ReturnType<typeof setInterval> | null = null;
let lastMessageAt = 0;

function api(path: string, init?: RequestInit): Promise<Response> {
  return fetch(path, {
    credentials: "same-origin",
    headers: { "content-type": "application/json", ...(init?.headers ?? {}) },
    ...init,
  });
}

async function loadMe(): Promise<MeResponse> {
  try {
    const res = await api("/api/me");
    if (!res.ok) return { authenticated: false };
    return (await res.json()) as MeResponse;
  } catch {
    return { authenticated: false };
  }
}

function renderLogin(message = ""): void {
  app.innerHTML = `
    <section class="shell auth-shell">
      ${themeToggleMarkup("theme-toggle-floating")}
      <div class="brand">Phantty Remote</div>
      <form class="panel auth-panel" id="login-form">
        <h1>Sign in to your relay</h1>
        <p>Single-user access is required before any local session key can be used.</p>
        <label>
          Username
          <input name="username" autocomplete="username" required />
        </label>
        <label>
          Password
          <input name="password" type="password" autocomplete="current-password" required />
        </label>
        <button type="submit">Sign in</button>
        <output class="form-message">${escapeText(message)}</output>
      </form>
    </section>
  `;

  const form = document.querySelector<HTMLFormElement>("#login-form");
  form?.addEventListener("submit", async (event) => {
    event.preventDefault();
    const data = new FormData(form);
    const res = await api("/api/login", {
      method: "POST",
      body: JSON.stringify({
        username: String(data.get("username") ?? ""),
        password: String(data.get("password") ?? ""),
      }),
    });
    if (!res.ok) {
      renderLogin("Login failed");
      return;
    }
    renderConsole();
  });

  bindThemeToggleButtons();
}

function renderConsole(): void {
  const savedSessionKey = readSavedSessionKey();
  app.innerHTML = `
    <section class="console-shell" data-kbd-visible="${kbdVisible}" data-drawer-open="${drawerOpen}">
      <div class="sidebar-backdrop" id="sidebar-backdrop"></div>
      <aside class="sidebar" id="sidebar">
        <div class="sidebar-head">
          <div class="brand">Phantty Remote</div>
          <div class="sidebar-head-actions">
            ${themeToggleMarkup()}
            <button type="button" class="icon-button" id="drawer-close" aria-label="Close menu">
              ${iconClose()}
            </button>
          </div>
        </div>
        <form id="connect-form" class="panel">
          <h1>Connect session</h1>
          <p>Enter the key generated by this Phantty instance.</p>
          <label>
            Session key
            <input name="session" spellcheck="false" autocomplete="off" value="${escapeText(savedSessionKey)}" required />
          </label>
          <div class="form-actions">
            <button type="submit">Connect</button>
            <button type="button" class="secondary-button" id="clear-session-button">Clear saved</button>
          </div>
        </form>
        <div class="panel status-panel">
          <span class="status-dot" id="status-dot"></span>
          <span id="status-text">Not connected</span>
        </div>
        <div class="panel remote-tabs-panel">
          <div class="panel-label">Tabs</div>
          <div id="remote-tabs" class="remote-tabs empty">Waiting for layout...</div>
        </div>
        <div class="panel notice-panel">
          <div class="panel-label">Relay</div>
          <div id="notice-log" class="notice-log">No relay events yet.</div>
        </div>
        <button class="ghost-button" id="logout-button">Sign out</button>
      </aside>
      <section class="workspace">
        <header class="mobile-bar">
          <button type="button" class="icon-button" id="drawer-open" aria-label="Open menu">
            ${iconMenu()}
          </button>
          <span class="mobile-bar-title" id="mobile-workspace-title">Phantty Remote</span>
          <span class="status-pip" id="mobile-status-pip" data-state="offline" title="Disconnected"></span>
          <button type="button" class="icon-button" id="kbd-toggle" aria-label="Toggle keyboard">
            ${iconKeyboard()}
          </button>
        </header>
        <div class="surface-strip" id="surface-strip"></div>
        <section class="terminal-panel">
          <div class="terminal-toolbar">
            <span id="workspace-title">Remote workspace</span>
            <div class="terminal-actions">
              <span class="control-state" id="control-state" data-state="granted">Input enabled</span>
              <span class="toolbar-hint">Click a panel, then type</span>
            </div>
          </div>
          <div id="remote-panels" class="panels-stage empty">
            <div class="empty-state">Connected panels will appear here.</div>
          </div>
        </section>
      </section>
      ${renderVirtualKeyboardMarkup()}
    </section>
  `;

  document.querySelector<HTMLButtonElement>("#logout-button")?.addEventListener("click", async () => {
    await api("/api/logout", { method: "POST" });
    disconnect();
    disposeSurfaceViews();
    renderLogin();
  });

  document.querySelector<HTMLFormElement>("#connect-form")?.addEventListener("submit", (event) => {
    event.preventDefault();
    const form = event.currentTarget as HTMLFormElement;
    const data = new FormData(form);
    const sessionKey = String(data.get("session") ?? "").trim();
    saveSessionKey(sessionKey);
    setDrawerOpen(false);
    connect(sessionKey);
  });

  const sessionInput = document.querySelector<HTMLInputElement>("#connect-form input[name='session']");
  sessionInput?.addEventListener("input", () => saveSessionKey(sessionInput.value.trim()));
  sessionInput?.addEventListener("change", () => saveSessionKey(sessionInput.value.trim()));

  document.querySelector<HTMLButtonElement>("#clear-session-button")?.addEventListener("click", () => {
    clearSessionKey();
    if (sessionInput) sessionInput.value = "";
    addNotice("Saved session key cleared.");
  });

  bindMobileChrome();
  bindVirtualKeyboard();
  bindThemeToggleButtons();
  updateInputUi();
  if (savedSessionKey) queueMicrotask(() => connect(savedSessionKey));
}

function iconMenu(): string {
  return `<svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M4 7h16M4 12h16M4 17h16"/></svg>`;
}

function iconClose(): string {
  return `<svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M6 6l12 12M6 18L18 6"/></svg>`;
}

function iconKeyboard(): string {
  return `<svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><rect x="2.5" y="6" width="19" height="12" rx="2.4"/><path d="M6 10h.01M10 10h.01M14 10h.01M18 10h.01M6 14h12"/></svg>`;
}

function iconSun(): string {
  return `<svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M2 12h2M20 12h2M4.93 4.93l1.41 1.41M17.66 17.66l1.41 1.41M4.93 19.07l1.41-1.41M17.66 6.34l1.41-1.41"/></svg>`;
}

function iconMoon(): string {
  return `<svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><path d="M21 12.8A9 9 0 1 1 11.2 3a7 7 0 0 0 9.8 9.8z"/></svg>`;
}

function themeToggleMarkup(extraClass = ""): string {
  return `<button type="button" class="icon-button theme-toggle${extraClass ? ` ${extraClass}` : ""}" data-theme-toggle aria-label="Toggle theme" title="Toggle theme"></button>`;
}

function renderVirtualKeyboardMarkup(): string {
  const key = (attrs: string, label: string, cls = ""): string =>
    `<button type="button" class="vkbd-key${cls ? ` ${cls}` : ""}" ${attrs}>${label}</button>`;
  return `
    <section class="vkbd" id="vkbd" data-mod-ctrl="false" data-mod-alt="false">
      <div class="vkbd-rows">
        <div class="vkbd-row">
          ${key('data-vk-key="esc"', "Esc")}
          ${key('data-vk-key="tab"', "Tab")}
          ${key('data-vk-mod="ctrl" data-active="false"', "Ctrl", "vkbd-mod")}
          ${key('data-vk-mod="alt" data-active="false"', "Alt", "vkbd-mod")}
          ${key('data-vk-key="up"', "↑")}
          ${key('data-vk-key="left"', "←")}
          ${key('data-vk-key="down"', "↓")}
          ${key('data-vk-key="right"', "→")}
        </div>
        <div class="vkbd-row">
          ${key('data-vk-text="|"', "|")}
          ${key('data-vk-text="\\"', "\\")}
          ${key('data-vk-text="/"', "/")}
          ${key('data-vk-text="~"', "~")}
          ${key('data-vk-text="\`"', "`")}
          ${key('data-vk-text="-"', "-")}
          ${key('data-vk-text="_"', "_")}
          ${key('data-vk-text="="', "=")}
          ${key('data-vk-text="*"', "*")}
        </div>
        <div class="vkbd-row">
          ${key('data-vk-ctrl="c"', "^C", "vkbd-pill")}
          ${key('data-vk-ctrl="d"', "^D", "vkbd-pill")}
          ${key('data-vk-ctrl="l"', "^L", "vkbd-pill")}
          ${key('data-vk-ctrl="r"', "^R", "vkbd-pill")}
          ${key('data-vk-ctrl="z"', "^Z", "vkbd-pill")}
          ${key('data-vk-key="bksp"', "⌫")}
          ${key('data-vk-key="enter"', "⏎")}
          ${key('data-vk-key="type"', "Type", "vkbd-wide")}
        </div>
      </div>
    </section>
  `;
}

function bindMobileChrome(): void {
  document.querySelector<HTMLButtonElement>("#drawer-open")?.addEventListener("click", () => {
    setDrawerOpen(true);
  });
  document.querySelector<HTMLButtonElement>("#drawer-close")?.addEventListener("click", () => {
    setDrawerOpen(false);
  });
  document.querySelector<HTMLDivElement>("#sidebar-backdrop")?.addEventListener("click", () => {
    setDrawerOpen(false);
  });
  document.querySelector<HTMLButtonElement>("#kbd-toggle")?.addEventListener("click", () => {
    setKbdVisible(!kbdVisible);
  });
}

function setDrawerOpen(open: boolean): void {
  drawerOpen = open;
  const shell = document.querySelector<HTMLElement>(".console-shell");
  if (shell) shell.dataset.drawerOpen = String(open);
}

function setKbdVisible(visible: boolean): void {
  kbdVisible = visible;
  saveKbdVisible(visible);
  const shell = document.querySelector<HTMLElement>(".console-shell");
  if (shell) shell.dataset.kbdVisible = String(visible);
  for (const view of surfaceViews.values()) scheduleFit(view);
}

function bindVirtualKeyboard(): void {
  const vkbd = document.querySelector<HTMLElement>("#vkbd");
  if (!vkbd) return;

  const keepFocus = (event: Event) => event.preventDefault();

  vkbd.querySelectorAll<HTMLButtonElement>(".vkbd-key").forEach((button) => {
    button.addEventListener("mousedown", keepFocus);
    button.addEventListener("touchstart", keepFocus, { passive: false });
    button.addEventListener("click", (event) => {
      event.preventDefault();
      dispatchVirtualKey(button);
    });
  });
}

function dispatchVirtualKey(button: HTMLButtonElement): void {
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
    surfaceViews.get(surfaceId)?.term.focus();
    return;
  }

  if (button.dataset.vkKey === "hide") {
    setKbdVisible(false);
    return;
  }

  if (button.dataset.vkCtrl) {
    const letter = button.dataset.vkCtrl.toLowerCase();
    if (letter.length === 1 && letter >= "a" && letter <= "z") {
      sendInputBytes(surfaceId, String.fromCharCode(letter.charCodeAt(0) - 96));
    }
    return;
  }

  if (button.dataset.vkText !== undefined) {
    let text = button.dataset.vkText;
    if (kbdMods.ctrl && text.length === 1) {
      const lower = text.toLowerCase();
      if (lower >= "a" && lower <= "z") {
        text = String.fromCharCode(lower.charCodeAt(0) - 96);
      }
    } else if (kbdMods.alt && text.length === 1) {
      text = `\x1b${text}`;
    }
    sendInputBytes(surfaceId, text);
    clearStickyMods();
    return;
  }

  if (button.dataset.vkKey) {
    const seq = keyToSequence(button.dataset.vkKey);
    if (seq) sendInputBytes(surfaceId, seq);
  }
}

function keyToSequence(key: string): string | null {
  switch (key) {
    case "esc":
      return "\x1b";
    case "tab":
      return "\t";
    case "up":
      return "\x1b[A";
    case "down":
      return "\x1b[B";
    case "right":
      return "\x1b[C";
    case "left":
      return "\x1b[D";
    case "bksp":
      return "\x7f";
    case "enter":
      return "\r";
    default:
      return null;
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

function activeSurfaceIdForInput(): string | null {
  return selectedSurfaceId ?? currentTab()?.surfaces[0]?.id ?? null;
}

function connect(sessionKey: string): void {
  if (!sessionKey) return;
  activeSessionKey = sessionKey;
  cancelReconnect();
  socket?.close();
  disposeSurfaceViews();
  layoutState = null;
  selectedSurfaceId = null;
  notices = [];
  hasSeenLayout = false;
  saveSessionKey(sessionKey);
  renderRemoteWorkspace();
  updateInputUi();

  const protocol = location.protocol === "https:" ? "wss:" : "ws:";
  const ws = new WebSocket(`${protocol}//${location.host}/ws/browser?session=${encodeURIComponent(sessionKey)}`);
  socket = ws;
  setStatus("connecting", "Connecting...");
  updateInputUi();

  ws.addEventListener("open", () => {
    if (socket !== ws) return;
    reconnectAttempts = 0;
    setStatus("online", "Connected");
    addNotice("Connected. Waiting for Phantty layout...");
    updateInputUi();
    startHeartbeat(ws);
  });

  ws.addEventListener("close", () => {
    const wasActive = socket === ws;
    if (!wasActive) return;
    stopHeartbeat();
    socket = null;
    if (activeSessionKey === sessionKey) {
      scheduleReconnect();
    } else {
      setStatus("offline", "Disconnected");
    }
    updateInputUi();
  });

  ws.addEventListener("error", () => {
    if (socket === ws) {
      try { ws.close(); } catch { /* ignore */ }
    }
  });

  ws.addEventListener("message", (event) => {
    if (socket !== ws) return;
    if (typeof event.data !== "string") return;
    lastMessageAt = Date.now();
    const message = safeJson(event.data);
    if (!message) return;

    if (message.type === "pong" || message.type === "ping") {
      if (message.type === "ping") safeSocketSend(ws, { type: "pong" });
      return;
    }

    if (isLayoutMessage(message)) {
      layoutState = normalizeLayout(message);
      if (!hasSeenLayout) {
        selectedTabIndex = layoutState.activeTab;
        hasSeenLayout = true;
      } else if (!layoutState.tabs.some((tab) => tab.index === selectedTabIndex)) {
        selectedTabIndex = layoutState.activeTab;
      }
      const activeTab = currentTab();
      if (!selectedSurfaceId || !activeTab?.surfaces.some((surface) => surface.id === selectedSurfaceId)) {
        selectedSurfaceId = activeTab?.focusedSurfaceId ?? activeTab?.surfaces[0]?.id ?? selectedSurfaceId;
      }
      reconcileSurfaceViews();
      renderRemoteWorkspace();
      return;
    }

    if (message.type === "output" && typeof message.data === "string") {
      writeLegacyOutput(message.data);
    } else if (
      message.type === "output-bytes" &&
      message.encoding === "hex" &&
      typeof message.data === "string"
    ) {
      const surfaceId = typeof message.surfaceId === "string" ? message.surfaceId : selectedSurfaceId;
      const bytes = decodeHex(message.data);
      if (surfaceId && bytes) writeSurfaceBytes(surfaceId, bytes);
    } else if (message.type === "notice" && typeof message.message === "string") {
      addNotice(message.message);
    }
  });
}

function disconnect(): void {
  activeSessionKey = null;
  cancelReconnect();
  stopHeartbeat();
  reconnectAttempts = 0;
  if (socket) {
    try { socket.close(); } catch { /* ignore */ }
    socket = null;
  }
  setStatus("offline", "Disconnected");
}

function startHeartbeat(ws: WebSocket): void {
  stopHeartbeat();
  lastMessageAt = Date.now();
  pingTimer = setInterval(() => {
    if (ws.readyState !== WebSocket.OPEN) return;
    safeSocketSend(ws, { type: "ping", at: Date.now() });
  }, HEARTBEAT_INTERVAL_MS);
  watchdogTimer = setInterval(() => {
    if (ws.readyState !== WebSocket.OPEN) return;
    if (Date.now() - lastMessageAt > HEARTBEAT_WATCHDOG_MS) {
      try { ws.close(4000, "heartbeat timeout"); } catch { /* ignore */ }
    }
  }, 5_000);
}

function stopHeartbeat(): void {
  if (pingTimer !== null) {
    clearInterval(pingTimer);
    pingTimer = null;
  }
  if (watchdogTimer !== null) {
    clearInterval(watchdogTimer);
    watchdogTimer = null;
  }
}

function scheduleReconnect(): void {
  if (!activeSessionKey) return;
  cancelReconnect();
  const exponent = Math.min(reconnectAttempts, 5);
  const delay = Math.min(RECONNECT_MAX_DELAY_MS, RECONNECT_MIN_DELAY_MS * 2 ** exponent);
  reconnectAttempts += 1;
  setStatus("connecting", `Reconnecting in ${Math.round(delay / 1000)}s...`);
  reconnectTimer = setTimeout(() => {
    reconnectTimer = null;
    if (activeSessionKey) connect(activeSessionKey);
  }, delay);
}

function cancelReconnect(): void {
  if (reconnectTimer !== null) {
    clearTimeout(reconnectTimer);
    reconnectTimer = null;
  }
}

function safeSocketSend(ws: WebSocket, payload: unknown): void {
  try {
    ws.send(JSON.stringify(payload));
  } catch {
    // Ignore — close handler will retry via reconnect.
  }
}

function renderRemoteWorkspace(): void {
  renderRemoteTabs();
  renderRemotePanels();
  renderSurfaceStrip();
  renderNotices();
  updateInputUi();
}

function renderSurfaceStrip(): void {
  const strip = document.querySelector<HTMLDivElement>("#surface-strip");
  if (!strip) return;
  const tab = currentTab();
  const surfaces = tab?.surfaces ?? [];
  if (surfaces.length <= 1) {
    strip.replaceChildren();
    return;
  }
  strip.innerHTML = surfaces
    .map((surface) => {
      const active = surface.id === selectedSurfaceId ? " active" : "";
      const label = escapeText(surface.title || shortSurfaceId(surface.id));
      return `<button type="button" class="surface-chip${active}" data-surface-id="${escapeText(surface.id)}">${label}</button>`;
    })
    .join("");
  strip.querySelectorAll<HTMLButtonElement>("[data-surface-id]").forEach((button) => {
    button.addEventListener("click", () => {
      selectedSurfaceId = button.dataset.surfaceId ?? selectedSurfaceId;
      renderRemoteWorkspace();
      const view = selectedSurfaceId ? surfaceViews.get(selectedSurfaceId) : undefined;
      if (view) {
        view.term.focus();
        scheduleFit(view);
      }
    });
  });
}

function renderRemoteTabs(): void {
  const tabsRoot = document.querySelector<HTMLDivElement>("#remote-tabs");
  if (!tabsRoot) return;

  if (!layoutState || layoutState.tabs.length === 0) {
    tabsRoot.className = "remote-tabs empty";
    tabsRoot.textContent = "Waiting for layout...";
    return;
  }

  tabsRoot.className = "remote-tabs";
  tabsRoot.innerHTML = layoutState.tabs
    .map((tab) => {
      const active = tab.index === selectedTabIndex ? " active" : "";
      const title = escapeText(tab.title || `Tab ${tab.index + 1}`);
      return `<button type="button" class="tab-chip${active}" data-tab-index="${tab.index}">${title}<span>${tab.surfaces.length}</span></button>`;
    })
    .join("");

  tabsRoot.querySelectorAll<HTMLButtonElement>("[data-tab-index]").forEach((button) => {
    button.addEventListener("click", () => {
      selectedTabIndex = Number(button.dataset.tabIndex);
      const activeTab = currentTab();
      selectedSurfaceId = activeTab?.focusedSurfaceId ?? activeTab?.surfaces[0]?.id ?? selectedSurfaceId;
      renderRemoteWorkspace();
    });
  });
}

function renderRemotePanels(): void {
  const panelsRoot = document.querySelector<HTMLDivElement>("#remote-panels");
  const titleRoot = document.querySelector<HTMLSpanElement>("#workspace-title");
  if (!panelsRoot) return;

  const tab = currentTab();
  if (!tab || tab.surfaces.length === 0) {
    panelsRoot.className = "panels-stage empty";
    delete panelsRoot.dataset.mobileMode;
    panelsRoot.replaceChildren(emptyState("No panels for this tab yet."));
    const fallback = "Remote workspace";
    if (titleRoot) titleRoot.textContent = fallback;
    const mobileTitleRoot = document.querySelector<HTMLSpanElement>("#mobile-workspace-title");
    if (mobileTitleRoot) mobileTitleRoot.textContent = fallback;
    return;
  }

  const tabTitle = tab.title || `Tab ${tab.index + 1}`;
  if (titleRoot) titleRoot.textContent = tabTitle;
  const mobileTitleRoot = document.querySelector<HTMLSpanElement>("#mobile-workspace-title");
  if (mobileTitleRoot) mobileTitleRoot.textContent = tabTitle;
  panelsRoot.className = "panels-stage";
  panelsRoot.dataset.mobileMode = "single";
  panelsRoot.querySelectorAll(".empty-state").forEach((node) => node.remove());
  const visible = new Set(tab.surfaces.map((surface) => surface.id));

  for (const surface of tab.surfaces) {
    const view = ensureSurfaceView(surface.id);
    view.panel.className = `remote-panel${surface.id === selectedSurfaceId ? " selected" : ""}`;
    view.panel.style.left = `${(surface.x ?? 0) * 100}%`;
    view.panel.style.top = `${(surface.y ?? 0) * 100}%`;
    view.panel.style.width = `${Math.max(0.05, surface.w ?? 1) * 100}%`;
    view.panel.style.height = `${Math.max(0.05, surface.h ?? 1) * 100}%`;
    view.panel.dataset.surfaceId = surface.id;
    view.title.textContent = surface.title || shortSurfaceId(surface.id);
    view.meta.textContent = surface.focused ? "focused" : shortSurfaceId(surface.id);
    view.remoteCols = validPositiveInteger(surface.cols);
    view.remoteRows = validPositiveInteger(surface.rows);

    if (view.panel.parentElement !== panelsRoot) {
      panelsRoot.appendChild(view.panel);
    }

    if (!view.opened) {
      view.term.open(view.host);
      view.opened = true;
      view.resizeObserver = new ResizeObserver(() => scheduleFit(view));
      view.resizeObserver.observe(view.host);
      flushPendingOutput(view);
    }
    updateSurfaceCursor(view, surface.id);
    applyInitialSnapshot(view, surface);
    scheduleFit(view);

    if (surface.id === selectedSurfaceId && document.activeElement && view.panel.contains(document.activeElement)) {
      view.term.focus();
    }
  }

  for (const [surfaceId, view] of surfaceViews) {
    if (!visible.has(surfaceId) && view.panel.parentElement === panelsRoot) {
      view.panel.remove();
    }
  }
}

function ensureSurfaceView(surfaceId: string): SurfaceView {
  const existing = surfaceViews.get(surfaceId);
  if (existing) return existing;

  const host = document.createElement("div");
  host.className = "terminal-host";
  const panel = document.createElement("section");
  panel.className = "remote-panel";
  panel.dataset.surfaceId = surfaceId;
  const header = document.createElement("div");
  header.className = "panel-header";
  const title = document.createElement("span");
  const meta = document.createElement("small");
  header.appendChild(title);
  header.appendChild(meta);
  const mount = document.createElement("div");
  mount.className = "terminal-mount";
  mount.appendChild(host);
  panel.appendChild(header);
  panel.appendChild(mount);
  panel.addEventListener("pointerdown", () => {
    selectedSurfaceId = surfaceId;
    renderRemotePanels();
  });
  panel.addEventListener("click", () => {
    selectedSurfaceId = surfaceId;
    renderRemotePanels();
    ensureSurfaceView(surfaceId).term.focus();
  });

  const fit = new FitAddon();
  const term = new Terminal({
    cursorBlink: true,
    cursorInactiveStyle: "outline",
    cursorStyle: "bar",
    cursorWidth: 2,
    convertEol: true,
    disableStdin: false,
    fontFamily: '"JetBrains Mono", "Cascadia Mono", monospace',
    fontSize: 13,
    scrollback: 0,
    theme: THEME_TERMINAL_PALETTES[themeMode],
  });
  term.loadAddon(fit);

  const view: SurfaceView = {
    panel,
    title,
    meta,
    host,
    term,
    fit,
    decoder: new TextDecoder(),
    disposeInput: term.onData((data) => sendInputBytes(surfaceId, data)),
    disposeMiddleClickGesture: null,
    resizeObserver: null,
    fitQueued: false,
    hasLiveOutput: false,
    snapshotApplied: false,
    opened: false,
    pendingOutput: "",
    remoteCols: null,
    remoteRows: null,
  };
  view.disposeMiddleClickGesture = bindTwoFingerMiddleClick(view);
  surfaceViews.set(surfaceId, view);
  return view;
}

function bindTwoFingerMiddleClick(view: SurfaceView): () => void {
  const host = view.host;
  const MOVE_THRESHOLD = 14;
  const TIME_THRESHOLD = 700;
  let active = false;
  let startTime = 0;
  let centroid: { x: number; y: number } | null = null;

  const onTouchStart = (event: TouchEvent): void => {
    if (event.touches.length === 2) {
      active = true;
      startTime = Date.now();
      const a = event.touches[0];
      const b = event.touches[1];
      centroid = { x: (a.clientX + b.clientX) / 2, y: (a.clientY + b.clientY) / 2 };
    } else if (event.touches.length > 2) {
      active = false;
      centroid = null;
    }
  };

  const onTouchMove = (event: TouchEvent): void => {
    if (!active || !centroid) return;
    if (event.touches.length !== 2) {
      active = false;
      return;
    }
    const a = event.touches[0];
    const b = event.touches[1];
    const cx = (a.clientX + b.clientX) / 2;
    const cy = (a.clientY + b.clientY) / 2;
    if (Math.hypot(cx - centroid.x, cy - centroid.y) > MOVE_THRESHOLD) {
      active = false;
    }
  };

  const onTouchEnd = (event: TouchEvent): void => {
    if (!active || !centroid) {
      if (event.touches.length === 0) {
        active = false;
        centroid = null;
      }
      return;
    }
    if (event.touches.length >= 2) return;
    const within = Date.now() - startTime <= TIME_THRESHOLD;
    const point = centroid;
    active = false;
    centroid = null;
    if (!within) return;
    event.preventDefault();
    dispatchMiddleClick(host, point.x, point.y);
  };

  const onTouchCancel = (): void => {
    active = false;
    centroid = null;
  };

  host.addEventListener("touchstart", onTouchStart, { passive: true });
  host.addEventListener("touchmove", onTouchMove, { passive: true });
  host.addEventListener("touchend", onTouchEnd, { passive: false });
  host.addEventListener("touchcancel", onTouchCancel, { passive: true });

  return () => {
    host.removeEventListener("touchstart", onTouchStart);
    host.removeEventListener("touchmove", onTouchMove);
    host.removeEventListener("touchend", onTouchEnd);
    host.removeEventListener("touchcancel", onTouchCancel);
  };
}

function dispatchMiddleClick(host: HTMLElement, clientX: number, clientY: number): void {
  const target =
    host.querySelector<HTMLElement>(".xterm-screen") ??
    host.querySelector<HTMLElement>(".xterm") ??
    host;
  const baseInit: MouseEventInit = {
    bubbles: true,
    cancelable: true,
    composed: true,
    view: window,
    clientX,
    clientY,
    screenX: clientX,
    screenY: clientY,
    button: 1,
  };
  target.dispatchEvent(new MouseEvent("mousedown", { ...baseInit, buttons: 4 }));
  target.dispatchEvent(new MouseEvent("mouseup", { ...baseInit, buttons: 0 }));
  target.dispatchEvent(new MouseEvent("auxclick", { ...baseInit, buttons: 0, detail: 1 }));
}

function reconcileSurfaceViews(): void {
  if (!layoutState) return;
  const live = new Set(layoutState.tabs.flatMap((tab) => tab.surfaces.map((surface) => surface.id)));
  for (const [surfaceId, view] of surfaceViews) {
    if (!live.has(surfaceId)) {
      view.resizeObserver?.disconnect();
      view.disposeInput.dispose();
      view.disposeMiddleClickGesture?.();
      view.term.dispose();
      surfaceViews.delete(surfaceId);
    }
  }
}

function disposeSurfaceViews(): void {
  for (const view of surfaceViews.values()) {
    view.resizeObserver?.disconnect();
    view.disposeInput.dispose();
    view.disposeMiddleClickGesture?.();
    view.term.dispose();
  }
  surfaceViews = new Map();
}

function writeSurfaceBytes(surfaceId: string, bytes: Uint8Array): void {
  const view = ensureSurfaceView(surfaceId);
  view.hasLiveOutput = true;
  writeSurfaceText(view, view.decoder.decode(bytes, { stream: true }));
}

function writeLegacyOutput(data: string): void {
  const surfaceId = selectedSurfaceId ?? currentTab()?.surfaces[0]?.id ?? "legacy";
  const view = ensureSurfaceView(surfaceId);
  view.hasLiveOutput = true;
  writeSurfaceText(view, data);
}

function sendInputBytes(surfaceId: string, data: string): void {
  if (!socket || socket.readyState !== WebSocket.OPEN) return;
  socket.send(
    JSON.stringify({
      type: "input-bytes",
      surfaceId,
      encoding: "hex",
      data: encodeHex(encoder.encode(data)),
    }),
  );
}

function updateInputUi(): void {
  const connected = socket?.readyState === WebSocket.OPEN;
  const label = document.querySelector<HTMLSpanElement>("#control-state");
  const hint = document.querySelector<HTMLSpanElement>(".toolbar-hint");

  if (label) {
    label.dataset.state = connected ? "granted" : "idle";
    label.textContent = connected ? "Input enabled" : "Input ready";
  }
  if (hint) {
    hint.textContent = connected ? "Click a panel, then type" : "Connect a session to begin";
  }

  for (const [surfaceId, view] of surfaceViews) {
    view.term.options.disableStdin = false;
    updateSurfaceCursor(view, surfaceId);
  }
}

function updateSurfaceCursor(view: SurfaceView, surfaceId: string): void {
  const selected = surfaceId === selectedSurfaceId;
  view.term.options.cursorBlink = selected;
  view.term.options.cursorInactiveStyle = selected ? "outline" : "none";
}

function scheduleFit(view: SurfaceView): void {
  if (view.fitQueued) return;
  view.fitQueued = true;
  requestAnimationFrame(() => {
    view.fitQueued = false;
    if (!view.host.isConnected) return;
    try {
      if (view.remoteCols && view.remoteRows) {
        if (view.term.cols !== view.remoteCols || view.term.rows !== view.remoteRows) {
          view.term.resize(view.remoteCols, view.remoteRows);
        }
      } else {
        view.fit.fit();
      }
      view.term.refresh(0, Math.max(0, view.term.rows - 1));
    } catch {
      // xterm can briefly report zero-sized panels while layout is settling.
    }
  });
}

function applyInitialSnapshot(view: SurfaceView, surface: LayoutSurface): void {
  if (view.snapshotApplied || view.hasLiveOutput || !surface.snapshot) return;
  view.snapshotApplied = true;
  requestAnimationFrame(() => {
    if (!view.host.isConnected || view.hasLiveOutput) return;
    try {
      if (view.remoteCols && view.remoteRows) {
        view.term.resize(view.remoteCols, view.remoteRows);
      } else {
        view.fit.fit();
      }
    } catch {
      // xterm can briefly report zero-sized panels while layout is settling.
    }
    view.term.reset();
    view.term.write(surface.snapshot + cursorMoveSequence(surface));
    view.term.refresh(0, Math.max(0, view.term.rows - 1));
  });
}

function writeSurfaceText(view: SurfaceView, text: string): void {
  if (!text) return;
  if (!view.opened) {
    view.pendingOutput = capPendingOutput(view.pendingOutput + text);
    return;
  }
  flushPendingOutput(view);
  view.term.write(text);
}

function flushPendingOutput(view: SurfaceView): void {
  if (!view.opened || !view.pendingOutput) return;
  const pending = view.pendingOutput;
  view.pendingOutput = "";
  view.term.write(pending);
}

function capPendingOutput(value: string): string {
  const limit = 128 * 1024;
  return value.length > limit ? value.slice(value.length - limit) : value;
}

function cursorMoveSequence(surface: LayoutSurface): string {
  const x = validNonNegativeInteger(surface.cursorX);
  const y = validNonNegativeInteger(surface.cursorY);
  if (x === null || y === null) return "";
  return `\x1b[${y + 1};${x + 1}H`;
}

function validPositiveInteger(value: unknown): number | null {
  const next = validNonNegativeInteger(value);
  return next !== null && next > 0 ? next : null;
}

function validNonNegativeInteger(value: unknown): number | null {
  if (typeof value !== "number" || !Number.isFinite(value)) return null;
  const next = Math.floor(value);
  return next >= 0 ? next : null;
}

function readSavedSessionKey(): string {
  try {
    return localStorage.getItem(SESSION_KEY_STORAGE_KEY)?.trim() ?? "";
  } catch {
    return "";
  }
}

function saveSessionKey(sessionKey: string): void {
  if (!sessionKey) {
    clearSessionKey();
    return;
  }
  try {
    localStorage.setItem(SESSION_KEY_STORAGE_KEY, sessionKey);
  } catch {
    // Storage may be unavailable in restricted browser contexts.
  }
}

function emptyState(text: string): HTMLDivElement {
  const node = document.createElement("div");
  node.className = "empty-state";
  node.textContent = text;
  return node;
}

function clearSessionKey(): void {
  try {
    localStorage.removeItem(SESSION_KEY_STORAGE_KEY);
  } catch {
    // Storage may be unavailable in restricted browser contexts.
  }
}

function readSavedKbdVisible(): boolean | null {
  try {
    const raw = localStorage.getItem(KBD_VISIBLE_STORAGE_KEY);
    if (raw === "1") return true;
    if (raw === "0") return false;
    return null;
  } catch {
    return null;
  }
}

function saveKbdVisible(visible: boolean): void {
  try {
    localStorage.setItem(KBD_VISIBLE_STORAGE_KEY, visible ? "1" : "0");
  } catch {
    // Storage may be unavailable in restricted browser contexts.
  }
}

function currentTab(): LayoutTab | null {
  if (!layoutState) return null;
  return (
    layoutState.tabs.find((tab) => tab.index === selectedTabIndex) ??
    layoutState.tabs.find((tab) => tab.index === layoutState?.activeTab) ??
    layoutState.tabs[0] ??
    null
  );
}

function isLayoutMessage(message: RelayMessage): boolean {
  return message.type === "layout" && Array.isArray(message.tabs);
}

function normalizeLayout(message: RelayMessage): { activeTab: number; tabs: LayoutTab[] } {
  const activeTab = typeof message.activeTab === "number" ? message.activeTab : 0;
  const rawTabs = Array.isArray(message.tabs) ? message.tabs : [];
  const tabs: LayoutTab[] = rawTabs
    .map((raw): LayoutTab | null => {
      if (!raw || typeof raw !== "object") return null;
      const tab = raw as Record<string, unknown>;
      const index = typeof tab.index === "number" ? tab.index : 0;
      const surfaces = Array.isArray(tab.surfaces)
        ? tab.surfaces.map(normalizeSurface).filter((surface): surface is LayoutSurface => Boolean(surface))
        : [];
      return {
        index,
        title: typeof tab.title === "string" ? tab.title : `Tab ${index + 1}`,
        focusedSurfaceId: typeof tab.focusedSurfaceId === "string" ? tab.focusedSurfaceId : surfaces[0]?.id,
        surfaces,
      };
    })
    .filter((tab): tab is LayoutTab => Boolean(tab));
  return { activeTab, tabs };
}

function normalizeSurface(raw: unknown): LayoutSurface | null {
  if (!raw || typeof raw !== "object") return null;
  const surface = raw as Record<string, unknown>;
  if (typeof surface.id !== "string") return null;
  return {
    id: surface.id,
    title: typeof surface.title === "string" ? surface.title : shortSurfaceId(surface.id),
    focused: surface.focused === true,
    snapshot: typeof surface.snapshot === "string" ? surface.snapshot : "",
    cols: numberOr(surface.cols, 0),
    rows: numberOr(surface.rows, 0),
    cursorX: numberOr(surface.cursorX, 0),
    cursorY: numberOr(surface.cursorY, 0),
    x: numberOr(surface.x, 0),
    y: numberOr(surface.y, 0),
    w: numberOr(surface.w, 1),
    h: numberOr(surface.h, 1),
  };
}

function numberOr(value: unknown, fallback: number): number {
  return typeof value === "number" && Number.isFinite(value) ? value : fallback;
}

function setStatus(kind: "offline" | "connecting" | "online", text: string): void {
  const dot = document.querySelector<HTMLSpanElement>("#status-dot");
  const label = document.querySelector<HTMLSpanElement>("#status-text");
  const pip = document.querySelector<HTMLSpanElement>("#mobile-status-pip");
  if (dot) dot.dataset.state = kind;
  if (label) label.textContent = text;
  if (pip) {
    pip.dataset.state = kind;
    pip.title = text;
  }
}

function addNotice(message: string): void {
  notices = [...notices.slice(-5), message];
  renderNotices();
}

function renderNotices(): void {
  const root = document.querySelector<HTMLDivElement>("#notice-log");
  if (!root) return;
  if (notices.length === 0) {
    root.textContent = "No relay events yet.";
    return;
  }
  root.innerHTML = notices.map((notice) => `<div>${escapeText(notice)}</div>`).join("");
}

function safeJson(data: string): RelayMessage | null {
  try {
    return JSON.parse(data) as RelayMessage;
  } catch {
    return null;
  }
}

function decodeHex(hex: string): Uint8Array | null {
  if (hex.length % 2 !== 0) return null;
  const bytes = new Uint8Array(hex.length / 2);
  for (let i = 0; i < bytes.length; i += 1) {
    const value = Number.parseInt(hex.slice(i * 2, i * 2 + 2), 16);
    if (Number.isNaN(value)) return null;
    bytes[i] = value;
  }
  return bytes;
}

function encodeHex(bytes: Uint8Array): string {
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
}

function shortSurfaceId(id: string): string {
  return id.length > 6 ? id.slice(-6) : id;
}

function escapeText(value: string): string {
  return value.replace(/[&<>"']/g, (ch) => {
    switch (ch) {
      case "&":
        return "&amp;";
      case "<":
        return "&lt;";
      case ">":
        return "&gt;";
      case '"':
        return "&quot;";
      default:
        return "&#39;";
    }
  });
}

function kickReconnectIfIdle(): void {
  if (!activeSessionKey) return;
  if (socket && socket.readyState === WebSocket.OPEN) return;
  if (socket && socket.readyState === WebSocket.CONNECTING) return;
  cancelReconnect();
  reconnectAttempts = 0;
  connect(activeSessionKey);
}

window.addEventListener("online", kickReconnectIfIdle);
document.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "visible") kickReconnectIfIdle();
});

void loadMe().then((me) => {
  if (me.authenticated) renderConsole();
  else renderLogin();
});
