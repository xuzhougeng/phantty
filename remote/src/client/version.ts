export const WEB_VERSION = "v0.22.2";
export const WEB_BUILD_TIME = normalizedBuildTime(import.meta.env?.VITE_PHANTTY_WEB_BUILD_TIME);

export function webVersionLabel(buildTime: string | null = WEB_BUILD_TIME): string {
  const normalized = normalizedBuildTime(buildTime);
  return normalized ? `Web ${WEB_VERSION} (${normalized})` : `Web ${WEB_VERSION}`;
}

export function remoteBrandMarkup(buildTime: string | null = WEB_BUILD_TIME): string {
  return `Phantty Remote <span class="web-version">${escapeHtml(webVersionLabel(buildTime))}</span>`;
}

function normalizedBuildTime(value: string | null | undefined): string | null {
  const trimmed = value?.trim();
  return trimmed ? trimmed : null;
}

function escapeHtml(value: string): string {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}
