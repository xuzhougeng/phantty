import type { DesktopPanelMode, MobileInputMode, MobileVisualZoom, StatusKind } from "../types";
import { iconClose, iconKeyboard, iconMenu, iconPanelMode, themeToggleMarkup } from "../icons";
import { bindThemeToggleButtons } from "../theme";
import { activeSurfaceIdForInput, currentTab, state, pushNotice } from "../state";
import {
  clearSessionKey,
  maskSessionKey,
  readSavedSessionKey,
  saveKbdVisible,
  saveDesktopPanelMode,
  saveMobileVisualZoom,
  saveSessionKey,
  saveSidebarCollapsed,
} from "../storage";
import { escapeText, shortSurfaceId } from "../utils";
import { api, connect, disconnect } from "../transport";
import { remoteBrandMarkup } from "../version";
import {
  disposeSurfaceViews,
  focusAndFitSelectedSurface,
  refitAllSurfaces,
  renderRemotePanels,
  syncSurfaceVisualZooms,
  syncTerminalNativeInputGuards,
  updateAiChatControls,
  updateSurfaceCursors,
} from "../surfaces";
import { applyVisualViewportSizing, isMobileRemoteShell } from "../mobile_layout";
import {
  bindMobileTextInput,
  blurMobileTextInput,
  focusMobileTextInput,
  renderMobileTextInputMarkup,
} from "../mobile_text_input";
import { bindVirtualKeyboard, renderVirtualKeyboardMarkup, syncVirtualKeyboardInputMode } from "../vkbd";
import { mobileVisualZoomLabel, mobileVisualZoomPercent, nextMobileVisualZoom } from "../mobile_visual_zoom";
import { selectedMobileSurfaceKind, shouldShowMobileVirtualKeyboard } from "../mobile_surface_mode";
import {
  bindActionText,
  bridgeStatusText,
  fetchWeixinSettings,
  normalizeWeixinSettings,
  pollWeixinBindStatus,
  saveWeixinSettings,
  startWeixinBind,
  unbindWeixin,
  type WeixinSettingsResponse,
} from "../weixin";

let viewportRefitBound = false;
let weixinBindTimer: ReturnType<typeof setTimeout> | null = null;
let weixinBindGeneration = 0;
let weixinState: WeixinSettingsResponse | null = null;
type SidebarPage = "tabs" | "dashboard" | "settings";
let sidebarPage: SidebarPage = "tabs";

export function renderConsole(app: HTMLElement, onLogout: () => void): void {
  cleanupWeixinPanel();

  const savedSessionKey = readSavedSessionKey();
  const hasSavedSessionKey = savedSessionKey.length > 0;
  let sessionKeyMasked = hasSavedSessionKey;
  const initialSessionInputValue = hasSavedSessionKey ? maskSessionKey(savedSessionKey) : savedSessionKey;

  app.innerHTML = `
    <section class="console-shell" data-kbd-visible="${state.kbdVisible}" data-mobile-surface-kind="none" data-mobile-vkbd-visible="false" data-mobile-input-mode="${state.mobileInputMode}" data-mobile-visual-zoom="${mobileVisualZoomPercent(state.mobileVisualZoom)}" data-drawer-open="${state.drawerOpen}" data-sidebar-collapsed="${state.sidebarCollapsed}" data-desktop-panel-mode="${state.desktopPanelMode}" data-sidebar-page="${sidebarPage}">
      <div class="sidebar-backdrop" id="sidebar-backdrop"></div>
      <aside class="sidebar" id="sidebar">
        <div class="sidebar-main">
          <div class="sidebar-head">
            <div class="sidebar-head-actions">
              <button type="button" class="icon-button" id="drawer-close" aria-label="Close menu" title="Close menu">
                ${iconClose()}
              </button>
            </div>
          </div>

          <nav class="sidebar-page-nav" aria-label="Remote sidebar pages">
            <button type="button" class="sidebar-page-button${sidebarPage === "tabs" ? " active" : ""}" data-sidebar-page-target="tabs">Tabs</button>
            <button type="button" class="sidebar-page-button${sidebarPage === "dashboard" ? " active" : ""}" data-sidebar-page-target="dashboard">Dashboard</button>
            <button type="button" class="sidebar-page-button${sidebarPage === "settings" ? " active" : ""}" data-sidebar-page-target="settings">Settings</button>
          </nav>

          <div class="sidebar-page${sidebarPage === "tabs" ? " active" : ""}" data-sidebar-page="tabs">
          <div class="sidebar-section sidebar-tabs-section">
            <div class="sidebar-section-head">
              <div>
                <div class="sidebar-section-title">Tabs</div>
              </div>
            </div>
            <div class="panel remote-tabs-panel" id="tabs-panel">
              <div id="remote-tabs" class="remote-tabs empty">Waiting...</div>
            </div>
          </div>
          </div>

          <div class="sidebar-page${sidebarPage === "dashboard" ? " active" : ""}" data-sidebar-page="dashboard">
          <div class="sidebar-section">
            <div class="sidebar-section-title">Dashboard</div>
            <div class="panel dashboard-panel" id="dashboard-panel">
              <div class="status-panel dashboard-status">
                <span class="status-dot" id="status-dot"></span>
                <span id="status-text">Not connected</span>
              </div>
              <div class="dashboard-log">
                <div class="panel-label">Activity</div>
                <div id="notice-log" class="notice-log">No activity</div>
              </div>
            </div>
          </div>
          </div>

          <div class="sidebar-page settings-page${sidebarPage === "settings" ? " active" : ""}" data-sidebar-page="settings">
          <div class="sidebar-section settings-section">
            <div class="sidebar-section-title">Settings</div>
            <div class="panel settings-about-panel">
              <div class="panel-label">About</div>
              <div class="brand settings-brand">${remoteBrandMarkup()}</div>
            </div>
            <div class="panel panel-mode-panel" id="desktop-panel-mode">
              <div class="settings-item-head">
                <div>
                  <div class="panel-label">Desktop display</div>
                  <strong id="desktop-panel-mode-title">${desktopPanelModeTitle(state.desktopPanelMode)}</strong>
                </div>
                <span class="settings-item-badge" id="desktop-panel-mode-badge">${desktopPanelModeBadge(state.desktopPanelMode)}</span>
              </div>
              <p id="desktop-panel-mode-copy">${desktopPanelModeCopy(state.desktopPanelMode)}</p>
            </div>
            <details class="settings-group" open>
              <summary>Remote connection</summary>
              <form id="connect-form" class="panel connect-panel">
                <h1>Connect</h1>
                <label>
                  Session key
                  <input name="session" spellcheck="false" autocomplete="off" value="${escapeText(initialSessionInputValue)}" required />
                </label>
                <div class="form-actions">
                  <button type="submit">Connect</button>
                  <button type="button" class="secondary-button" id="clear-session-button">Clear saved</button>
                </div>
              </form>
            </details>
            <details class="settings-group">
              <summary>Weixin</summary>
              <div class="panel weixin-panel" id="weixin-panel">
                <div class="weixin-head">
                  <div class="panel-label">Weixin</div>
                  <span id="weixin-state-pill" class="weixin-state-pill" data-state="loading">Loading</span>
                </div>
                <div id="weixin-status" class="weixin-status">Loading...</div>
                <label class="weixin-switch">
                  <span class="weixin-switch-copy">
                    <strong>Bridge</strong>
                    <small id="weixin-enabled-copy">Off</small>
                  </span>
                  <input id="weixin-enabled" type="checkbox" />
                  <span class="weixin-switch-track" aria-hidden="true"></span>
                </label>
                <label>
                  Target session
                  <select id="weixin-target-session"></select>
                </label>
                <div class="form-actions">
                  <button type="button" class="secondary-button" id="weixin-save">Save</button>
                  <button type="button" class="secondary-button weixin-bind-toggle" id="weixin-bind-toggle" data-mode="bind">Bind</button>
                </div>
                <div id="weixin-qr" class="weixin-qr" hidden></div>
              </div>
            </details>
          </div>
          </div>
        </div>

        <div class="sidebar-footer">
          <div class="sidebar-user">
            <span class="sidebar-user-avatar">P</span>
            <span class="sidebar-user-copy">
              <strong>Phantty</strong>
              <small>Remote console</small>
            </span>
          </div>
          <div class="sidebar-footer-actions">
            <button type="button" class="icon-button panel-mode-toggle" id="desktop-panel-mode-toggle" aria-label="${desktopPanelModeToggleLabel(state.desktopPanelMode)}" title="${desktopPanelModeToggleLabel(state.desktopPanelMode)}">
              ${iconPanelMode(state.desktopPanelMode)}
            </button>
            ${themeToggleMarkup("sidebar-footer-theme")}
            <button class="ghost-button" id="logout-button">Sign out</button>
          </div>
        </div>
      </aside>
      <section class="workspace">
        <header class="mobile-bar">
          <button type="button" class="icon-button" id="drawer-open" aria-label="Open menu">
            ${iconMenu()}
          </button>
          <span class="mobile-bar-title" id="mobile-workspace-title">Phantty Remote</span>
          <span class="status-pip" id="mobile-status-pip" data-state="offline" title="Disconnected"></span>
          <button type="button" class="mobile-zoom-toggle" id="mobile-zoom-toggle" data-zoom="${mobileVisualZoomPercent(state.mobileVisualZoom)}" aria-label="${mobileVisualZoomToggleLabel(state.mobileVisualZoom)}" title="${mobileVisualZoomToggleLabel(state.mobileVisualZoom)}">
            ${mobileVisualZoomLabel(state.mobileVisualZoom)}
          </button>
          <button type="button" class="mobile-input-mode-toggle" id="mobile-input-mode-toggle" data-mode="${state.mobileInputMode}" aria-label="${mobileInputModeToggleLabel(state.mobileInputMode)}" title="${mobileInputModeToggleLabel(state.mobileInputMode)}">
            ${mobileInputModeLabel(state.mobileInputMode)}
          </button>
          <button type="button" class="icon-button" id="kbd-toggle" aria-label="Toggle keyboard">
            ${iconKeyboard()}
          </button>
        </header>
        <div class="surface-strip" id="surface-strip"></div>
        <section class="terminal-panel">
          <div class="terminal-toolbar">
            <div class="terminal-title-group">
              <button type="button" class="icon-button desktop-sidebar-toggle" id="sidebar-expand" aria-label="Open sidebar" title="Open sidebar">
                ${iconMenu()}
              </button>
              <span id="workspace-title">Remote workspace</span>
            </div>
            <div class="terminal-actions">
              <span class="control-state" id="control-state" data-state="granted">Input enabled</span>
              <span class="toolbar-hint">Select panel</span>
            </div>
          </div>
          <div id="remote-panels" class="panels-stage empty">
            <div class="empty-state">No panels</div>
          </div>
        </section>
      </section>
      ${renderVirtualKeyboardMarkup()}
      ${renderMobileTextInputMarkup()}
    </section>
  `;

  document.querySelector<HTMLButtonElement>("#logout-button")?.addEventListener("click", async () => {
    cleanupWeixinPanel();
    await api("/api/logout", { method: "POST" });
    disconnect();
    disposeSurfaceViews();
    onLogout();
  });

  document.querySelector<HTMLFormElement>("#connect-form")?.addEventListener("submit", (event) => {
    event.preventDefault();
    const form = event.currentTarget as HTMLFormElement;
    const data = new FormData(form);
    const typedValue = String(data.get("session") ?? "").trim();
    const sessionKey = sessionKeyMasked && savedSessionKey ? savedSessionKey : typedValue;
    saveSessionKey(sessionKey);
    setDrawerOpen(false);
    connect(sessionKey);
  });

  const sessionInput = document.querySelector<HTMLInputElement>("#connect-form input[name='session']");
  const revealSessionInput = (): void => {
    if (!sessionKeyMasked || !sessionInput) return;
    sessionKeyMasked = false;
    sessionInput.value = "";
  };
  sessionInput?.addEventListener("focus", revealSessionInput);
  sessionInput?.addEventListener("pointerdown", revealSessionInput);
  sessionInput?.addEventListener("input", () => {
    if (sessionKeyMasked) return;
    saveSessionKey(sessionInput.value.trim());
  });
  sessionInput?.addEventListener("change", () => {
    if (sessionKeyMasked) return;
    saveSessionKey(sessionInput.value.trim());
  });

  document.querySelector<HTMLButtonElement>("#clear-session-button")?.addEventListener("click", () => {
    clearSessionKey();
    sessionKeyMasked = false;
    if (sessionInput) sessionInput.value = "";
    pushNotice("Saved session key cleared.");
    renderNotices();
  });

  bindMobileChrome();
  bindViewportRefit();
  bindVirtualKeyboard(() => setKbdVisible(false));
  bindMobileTextInput();
  bindThemeToggleButtons();
  bindSidebarPages();
  bindDesktopPanelMode();
  bindWeixinPanel();
  updateMobileSurfaceMode();
  syncMobileInputModeUi();
  syncMobileVisualZoomUi();
  updateInputUi();
  if (savedSessionKey) queueMicrotask(() => connect(savedSessionKey));
}

export function setStatus(kind: StatusKind, text: string): void {
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

export function renderNotices(): void {
  const root = document.querySelector<HTMLDivElement>("#notice-log");
  if (!root) return;
  if (state.notices.length === 0) {
    root.textContent = "No activity";
    return;
  }
  root.innerHTML = state.notices.map((notice) => `<div>${escapeText(notice)}</div>`).join("");
}

export function renderRemoteTabs(): void {
  const tabsRoot = document.querySelector<HTMLDivElement>("#remote-tabs");
  if (!tabsRoot) return;

  const layout = state.layoutState;
  if (!layout || layout.tabs.length === 0) {
    tabsRoot.className = "remote-tabs empty";
    tabsRoot.textContent = "Waiting...";
    return;
  }

  tabsRoot.className = "remote-tabs";
  tabsRoot.innerHTML = layout.tabs
    .map((tab) => {
      const active = tab.index === state.selectedTabIndex ? " active" : "";
      const title = escapeText(tab.title || `Tab ${tab.index + 1}`);
      return `<button type="button" class="tab-chip${active}" data-tab-index="${tab.index}"><span class="tab-chip-label">${title}</span><span class="tab-chip-count">${tab.surfaces.length}</span></button>`;
    })
    .join("");

  tabsRoot.querySelectorAll<HTMLButtonElement>("[data-tab-index]").forEach((button) => {
    button.addEventListener("click", () => {
      state.selectedTabIndex = Number(button.dataset.tabIndex);
      const layoutNow = state.layoutState;
      const activeTab = layoutNow?.tabs.find((tab) => tab.index === state.selectedTabIndex) ?? null;
      state.selectedSurfaceId =
        activeTab?.focusedSurfaceId ?? activeTab?.surfaces[0]?.id ?? state.selectedSurfaceId;
      renderRemoteWorkspace();
    });
  });
}

export function renderRemoteWorkspace(): void {
  renderRemoteTabs();
  renderRemotePanels();
  renderSurfaceStrip();
  renderNotices();
  updateMobileSurfaceMode();
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
      const active = surface.id === state.selectedSurfaceId ? " active" : "";
      const label = escapeText(surface.title || shortSurfaceId(surface.id));
      return `<button type="button" class="surface-chip${active}" data-surface-id="${escapeText(surface.id)}">${label}</button>`;
    })
    .join("");
  strip.querySelectorAll<HTMLButtonElement>("[data-surface-id]").forEach((button) => {
    button.addEventListener("click", () => {
      state.selectedSurfaceId = button.dataset.surfaceId ?? state.selectedSurfaceId;
      renderRemoteWorkspace();
      focusAndFitSelectedSurface();
    });
  });
}

export function updateInputUi(): void {
  const connected = state.socket?.readyState === WebSocket.OPEN;
  const tab = currentTab();
  const selectedSurfaceId = state.selectedSurfaceId ?? tab?.surfaces[0]?.id ?? null;
  const selectedSurface = tab?.surfaces.find((surface) => surface.id === selectedSurfaceId);
  const writable = connected && (Boolean(activeSurfaceIdForInput()) || selectedSurface?.kind === "ai_chat");
  const label = document.querySelector<HTMLSpanElement>("#control-state");
  const hint = document.querySelector<HTMLSpanElement>(".toolbar-hint");

  if (label) {
    label.dataset.state = writable ? "granted" : "idle";
    label.textContent = connected ? (writable ? "Input enabled" : "No input target") : "Input ready";
  }
  if (hint) {
    hint.textContent = connected ? (writable ? "Select panel" : "No target") : "Connect first";
  }

  updateSurfaceCursors();
  updateAiChatControls();
}

function updateMobileSurfaceMode(): void {
  const surfaceKind = selectedMobileSurfaceKind(
    state.layoutState,
    state.selectedTabIndex,
    state.selectedSurfaceId,
  );
  const shell = document.querySelector<HTMLElement>(".console-shell");
  if (shell) {
    shell.dataset.mobileSurfaceKind = surfaceKind;
    shell.dataset.mobileVkbdVisible = String(
      shouldShowMobileVirtualKeyboard(surfaceKind, state.kbdVisible, state.mobileInputMode),
    );
  }

  const keyboardToggle = document.querySelector<HTMLButtonElement>("#kbd-toggle");
  if (keyboardToggle) {
    const chatMode = surfaceKind === "ai_chat";
    keyboardToggle.hidden = chatMode;
    keyboardToggle.setAttribute("aria-hidden", String(chatMode));
  }
  const inputModeToggle = document.querySelector<HTMLButtonElement>("#mobile-input-mode-toggle");
  if (inputModeToggle) {
    const chatMode = surfaceKind === "ai_chat";
    inputModeToggle.hidden = chatMode;
    inputModeToggle.setAttribute("aria-hidden", String(chatMode));
  }
  const zoomToggle = document.querySelector<HTMLButtonElement>("#mobile-zoom-toggle");
  if (zoomToggle) {
    const chatMode = surfaceKind === "ai_chat";
    zoomToggle.hidden = chatMode;
    zoomToggle.setAttribute("aria-hidden", String(chatMode));
  }
  syncMobileInputModeUi();
  syncMobileVisualZoomUi();
}

function bindMobileChrome(): void {
  document.querySelector<HTMLButtonElement>("#drawer-open")?.addEventListener("click", () => {
    setDrawerOpen(true);
  });
  document.querySelector<HTMLButtonElement>("#drawer-close")?.addEventListener("click", () => {
    if (isMobileRemoteShell()) {
      setDrawerOpen(false);
    } else {
      setSidebarCollapsed(true);
    }
  });
  document.querySelector<HTMLDivElement>("#sidebar-backdrop")?.addEventListener("click", () => {
    setDrawerOpen(false);
  });
  document.querySelector<HTMLButtonElement>("#sidebar-expand")?.addEventListener("click", () => {
    setSidebarCollapsed(false);
  });
  document.querySelector<HTMLButtonElement>("#kbd-toggle")?.addEventListener("click", () => {
    setKbdVisible(!state.kbdVisible);
  });
  document.querySelector<HTMLButtonElement>("#mobile-input-mode-toggle")?.addEventListener("click", () => {
    setMobileInputMode(nextMobileInputMode(state.mobileInputMode));
  });
  document.querySelector<HTMLButtonElement>("#mobile-zoom-toggle")?.addEventListener("click", () => {
    setMobileVisualZoom(nextMobileVisualZoom(state.mobileVisualZoom));
  });
}

function setMobileInputMode(mode: MobileInputMode): void {
  if (state.mobileInputMode === mode) return;
  state.mobileInputMode = mode;
  if (mode === "text") {
    focusMobileTextInput();
  } else {
    blurMobileTextInput();
  }
  syncTerminalNativeInputGuards();
  updateSurfaceCursors();
  syncMobileInputModeUi();
  updateMobileSurfaceMode();
}

function syncMobileInputModeUi(): void {
  const mode = state.mobileInputMode;
  const shell = document.querySelector<HTMLElement>(".console-shell");
  if (shell) shell.dataset.mobileInputMode = mode;

  const toggle = document.querySelector<HTMLButtonElement>("#mobile-input-mode-toggle");
  if (toggle) {
    const label = mobileInputModeToggleLabel(mode);
    toggle.dataset.mode = mode;
    toggle.textContent = mobileInputModeLabel(mode);
    toggle.setAttribute("aria-label", label);
    toggle.title = label;
  }

  syncVirtualKeyboardInputMode();
}

function setMobileVisualZoom(zoom: MobileVisualZoom): void {
  if (state.mobileVisualZoom === zoom) return;
  state.mobileVisualZoom = zoom;
  saveMobileVisualZoom(zoom);
  syncMobileVisualZoomUi();
  syncSurfaceVisualZooms();
  updateMobileSurfaceMode();
}

function syncMobileVisualZoomUi(): void {
  const zoom = state.mobileVisualZoom;
  const percent = mobileVisualZoomPercent(zoom);
  const shell = document.querySelector<HTMLElement>(".console-shell");
  if (shell) shell.dataset.mobileVisualZoom = String(percent);

  const toggle = document.querySelector<HTMLButtonElement>("#mobile-zoom-toggle");
  if (!toggle) return;

  const label = mobileVisualZoomToggleLabel(zoom);
  toggle.dataset.zoom = String(percent);
  toggle.textContent = mobileVisualZoomLabel(zoom);
  toggle.setAttribute("aria-label", label);
  toggle.title = label;
}

function mobileInputModeLabel(mode: MobileInputMode): string {
  if (mode === "keys") return "Keys";
  if (mode === "text") return "Text";
  return "View";
}

function mobileInputModeToggleLabel(mode: MobileInputMode): string {
  return `Switch to ${mobileInputModeLabel(nextMobileInputMode(mode)).toLowerCase()} mode`;
}

function mobileVisualZoomToggleLabel(zoom: MobileVisualZoom): string {
  return `Switch terminal visual zoom to ${mobileVisualZoomLabel(nextMobileVisualZoom(zoom))}`;
}

function nextMobileInputMode(mode: MobileInputMode): MobileInputMode {
  if (mode === "keys") return "text";
  if (mode === "text") return "view";
  return "keys";
}

function bindSidebarPages(): void {
  document.querySelectorAll<HTMLButtonElement>("[data-sidebar-page-target]").forEach((button) => {
    button.addEventListener("click", () => {
      const page = button.dataset.sidebarPageTarget;
      if (page === "tabs" || page === "dashboard" || page === "settings") {
        setSidebarPage(page);
      }
    });
  });
}

function setSidebarPage(page: SidebarPage): void {
  sidebarPage = page;
  const shell = document.querySelector<HTMLElement>(".console-shell");
  if (shell) shell.dataset.sidebarPage = page;

  document.querySelectorAll<HTMLElement>("[data-sidebar-page]").forEach((section) => {
    section.classList.toggle("active", section.dataset.sidebarPage === page);
  });
  document.querySelectorAll<HTMLButtonElement>("[data-sidebar-page-target]").forEach((button) => {
    const active = button.dataset.sidebarPageTarget === page;
    button.classList.toggle("active", active);
    button.setAttribute("aria-current", active ? "page" : "false");
  });
}

function bindDesktopPanelMode(): void {
  document.querySelector<HTMLButtonElement>("#desktop-panel-mode-toggle")?.addEventListener("click", () => {
    setDesktopPanelMode(state.desktopPanelMode === "layout" ? "single" : "layout");
  });
}

function setDesktopPanelMode(value: string): void {
  if (value !== "layout" && value !== "single") return;
  const mode: DesktopPanelMode = value;
  if (state.desktopPanelMode === mode) return;
  state.desktopPanelMode = mode;
  saveDesktopPanelMode(mode);
  const shell = document.querySelector<HTMLElement>(".console-shell");
  if (shell) shell.dataset.desktopPanelMode = mode;
  syncDesktopPanelModeUi(mode);
  renderRemoteWorkspace();
  refitAllSurfaces();
}

function syncDesktopPanelModeUi(mode: DesktopPanelMode): void {
  const title = document.querySelector<HTMLElement>("#desktop-panel-mode-title");
  const badge = document.querySelector<HTMLElement>("#desktop-panel-mode-badge");
  const copy = document.querySelector<HTMLElement>("#desktop-panel-mode-copy");
  const toggle = document.querySelector<HTMLButtonElement>("#desktop-panel-mode-toggle");

  if (title) title.textContent = desktopPanelModeTitle(mode);
  if (badge) badge.textContent = desktopPanelModeBadge(mode);
  if (copy) copy.textContent = desktopPanelModeCopy(mode);
  if (toggle) {
    const label = desktopPanelModeToggleLabel(mode);
    toggle.innerHTML = iconPanelMode(mode);
    toggle.setAttribute("aria-label", label);
    toggle.title = label;
  }
}

function desktopPanelModeTitle(mode: DesktopPanelMode): string {
  return mode === "layout" ? "Mirror layout" : "Focused panels";
}

function desktopPanelModeBadge(mode: DesktopPanelMode): string {
  return mode === "layout" ? "Layout" : "Focused";
}

function desktopPanelModeCopy(mode: DesktopPanelMode): string {
  if (mode === "layout") return "Local split layout.";
  return "One panel at a time.";
}

function desktopPanelModeToggleLabel(mode: DesktopPanelMode): string {
  return mode === "layout" ? "Switch desktop tabs to focused panels" : "Switch desktop tabs to mirror layout";
}

function bindViewportRefit(): void {
  const refit = (): void => {
    applyVisualViewportSizing(document.querySelector<HTMLElement>(".console-shell"));
    refitAllSurfaces();
  };

  refit();
  if (viewportRefitBound) return;
  viewportRefitBound = true;

  window.addEventListener("resize", refit, { passive: true });
  window.visualViewport?.addEventListener("resize", refit);
  window.visualViewport?.addEventListener("scroll", refit);
}

function bindWeixinPanel(): void {
  document.querySelector<HTMLInputElement>("#weixin-enabled")?.addEventListener("change", (event) => {
    const copy = document.querySelector<HTMLElement>("#weixin-enabled-copy");
    if (copy) copy.textContent = (event.currentTarget as HTMLInputElement).checked ? "On" : "Off";
  });
  document.querySelector<HTMLButtonElement>("#weixin-save")?.addEventListener("click", () => {
    void saveWeixinPanel();
  });
  document.querySelector<HTMLButtonElement>("#weixin-bind-toggle")?.addEventListener("click", () => {
    if (weixinState?.binding.bound) {
      void unbindWeixinPanel();
    } else {
      void startWeixinPanelBind();
    }
  });
  void refreshWeixinPanel(weixinBindGeneration);
}

function nextWeixinBindGeneration(): number {
  weixinBindGeneration += 1;
  return weixinBindGeneration;
}

function isCurrentWeixinBindGeneration(generation: number): boolean {
  return generation === weixinBindGeneration;
}

function cleanupWeixinPanel(): void {
  nextWeixinBindGeneration();
  if (weixinBindTimer) {
    clearTimeout(weixinBindTimer);
    weixinBindTimer = null;
  }
  weixinState = null;

  const qr = document.querySelector<HTMLDivElement>("#weixin-qr");
  if (qr) {
    qr.hidden = true;
    qr.replaceChildren();
  }
}

async function refreshWeixinPanel(generation = weixinBindGeneration): Promise<void> {
  const status = document.querySelector<HTMLDivElement>("#weixin-status");
  try {
    const next = await fetchWeixinSettings();
    if (!isCurrentWeixinBindGeneration(generation)) return;
    weixinState = {
      ...next,
      settings: normalizeWeixinSettings(next.settings),
    };
    renderWeixinPanel();
  } catch (error) {
    if (!isCurrentWeixinBindGeneration(generation)) return;
    if (status) status.textContent = error instanceof Error ? error.message : "Load failed";
  }
}

function renderWeixinPanel(): void {
  if (!weixinState) return;

  const status = document.querySelector<HTMLDivElement>("#weixin-status");
  const pill = document.querySelector<HTMLSpanElement>("#weixin-state-pill");
  const enabled = document.querySelector<HTMLInputElement>("#weixin-enabled");
  const enabledCopy = document.querySelector<HTMLElement>("#weixin-enabled-copy");
  const bindToggle = document.querySelector<HTMLButtonElement>("#weixin-bind-toggle");
  const target = document.querySelector("#weixin-target-session") as HTMLSelectElement | null;
  const state = weixinPanelState(weixinState);

  if (status) status.textContent = bridgeStatusText(weixinState.settings, weixinState.binding);
  if (pill) {
    pill.dataset.state = state;
    pill.textContent = state === "ready" ? "Ready" : state === "disabled" ? "Disabled" : "Not bound";
  }
  if (enabled) enabled.checked = weixinState.settings.enabled;
  if (enabledCopy) enabledCopy.textContent = weixinState.settings.enabled ? "On" : "Off";
  if (bindToggle) {
    const bound = weixinState.binding.bound;
    bindToggle.textContent = bindActionText(weixinState.binding);
    bindToggle.dataset.mode = bound ? "unbind" : "bind";
  }
  if (target) {
    const selected = weixinState.settings.target_session;
    const sessions = [...weixinState.sessions];
    if (selected && !sessions.some((session) => session.key === selected)) {
      sessions.unshift({ key: selected, connected: false });
    }

    target.innerHTML = [
      `<option value="">No target</option>`,
      ...sessions.map((session) => {
        const connected = session.connected ? "connected" : "offline";
        return `<option value="${escapeText(session.key)}"${session.key === selected ? " selected" : ""}>${escapeText(maskSessionKey(session.key))} (${connected})</option>`;
      }),
    ].join("");
  }
}

function weixinPanelState(next: WeixinSettingsResponse): "ready" | "disabled" | "unbound" {
  if (!next.binding.bound) return "unbound";
  if (!next.settings.enabled) return "disabled";
  return "ready";
}

async function saveWeixinPanel(): Promise<void> {
  const status = document.querySelector<HTMLDivElement>("#weixin-status");
  const enabled = document.querySelector<HTMLInputElement>("#weixin-enabled");
  const target = document.querySelector("#weixin-target-session") as HTMLSelectElement | null;
  if (!enabled || !target) return;

  if (status) status.textContent = "Saving...";
  const generation = weixinBindGeneration;
  try {
    const settings = normalizeWeixinSettings({
      enabled: enabled.checked,
      target_session: target.value,
      reply_timeout_ms: weixinState?.settings.reply_timeout_ms ?? 120000,
    });
    await saveWeixinSettings(settings);
    if (!isCurrentWeixinBindGeneration(generation)) return;
    await refreshWeixinPanel(generation);
  } catch (error) {
    if (!isCurrentWeixinBindGeneration(generation)) return;
    if (status) status.textContent = error instanceof Error ? error.message : "Save failed";
  }
}

async function startWeixinPanelBind(): Promise<void> {
  const status = document.querySelector<HTMLDivElement>("#weixin-status");
  const qr = document.querySelector<HTMLDivElement>("#weixin-qr");
  const generation = nextWeixinBindGeneration();
  if (weixinBindTimer) {
    clearTimeout(weixinBindTimer);
    weixinBindTimer = null;
  }

  if (status) status.textContent = "Starting...";
  try {
    const binding = await startWeixinBind();
    if (!isCurrentWeixinBindGeneration(generation)) return;
    if (qr) {
      qr.hidden = false;
      qr.innerHTML = `<img src="${escapeText(binding.qrcode_data_url)}" alt="Weixin bind QR code" /><div>${escapeText(binding.status)}</div>`;
    }
    if (status) status.textContent = "Waiting...";
    scheduleWeixinBindPoll(binding.qrcode, generation);
  } catch (error) {
    if (!isCurrentWeixinBindGeneration(generation)) return;
    if (status) status.textContent = error instanceof Error ? error.message : "Bind failed";
  }
}

function scheduleWeixinBindPoll(qrcode: string, generation: number): void {
  if (!isCurrentWeixinBindGeneration(generation)) return;
  const status = document.querySelector<HTMLDivElement>("#weixin-status");
  if (weixinBindTimer) clearTimeout(weixinBindTimer);

  weixinBindTimer = setTimeout(() => {
    if (!isCurrentWeixinBindGeneration(generation)) return;
    weixinBindTimer = null;
    void (async () => {
      try {
        const next = await pollWeixinBindStatus(qrcode);
        if (!isCurrentWeixinBindGeneration(generation)) return;
        if (next.binding.bound || next.status === "bound") {
          const qr = document.querySelector<HTMLDivElement>("#weixin-qr");
          if (qr) {
            qr.hidden = true;
            qr.replaceChildren();
          }
          await refreshWeixinPanel(generation);
          return;
        }

        if (next.status === "expired" || next.status === "failed") {
          if (status) status.textContent = next.message ?? "Stopped";
          return;
        }

        if (status) status.textContent = next.message ?? "Waiting...";
        scheduleWeixinBindPoll(qrcode, generation);
      } catch (error) {
        if (!isCurrentWeixinBindGeneration(generation)) return;
        if (status) status.textContent = error instanceof Error ? error.message : "Check failed";
      }
    })();
  }, 2000);
}

async function unbindWeixinPanel(): Promise<void> {
  const status = document.querySelector<HTMLDivElement>("#weixin-status");
  const qr = document.querySelector<HTMLDivElement>("#weixin-qr");
  const generation = nextWeixinBindGeneration();
  if (weixinBindTimer) {
    clearTimeout(weixinBindTimer);
    weixinBindTimer = null;
  }
  if (qr) {
    qr.hidden = true;
    qr.replaceChildren();
  }

  if (status) status.textContent = "Unbinding Weixin...";
  try {
    await unbindWeixin();
    if (!isCurrentWeixinBindGeneration(generation)) return;
    await refreshWeixinPanel(generation);
  } catch (error) {
    if (!isCurrentWeixinBindGeneration(generation)) return;
    if (status) status.textContent = error instanceof Error ? error.message : "Unbind failed";
  }
}

function setDrawerOpen(open: boolean): void {
  state.drawerOpen = open;
  const shell = document.querySelector<HTMLElement>(".console-shell");
  if (shell) shell.dataset.drawerOpen = String(open);
}

function setSidebarCollapsed(collapsed: boolean): void {
  state.sidebarCollapsed = collapsed;
  saveSidebarCollapsed(collapsed);
  const shell = document.querySelector<HTMLElement>(".console-shell");
  if (shell) shell.dataset.sidebarCollapsed = String(collapsed);
  requestAnimationFrame(() => refitAllSurfaces());
}

function setKbdVisible(visible: boolean): void {
  state.kbdVisible = visible;
  saveKbdVisible(visible);
  const shell = document.querySelector<HTMLElement>(".console-shell");
  if (shell) shell.dataset.kbdVisible = String(visible);
  updateMobileSurfaceMode();
  requestAnimationFrame(() => refitAllSurfaces());
}
