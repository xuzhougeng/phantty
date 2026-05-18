export type RemoteTabSelectionSidebarAction = "close-drawer" | "collapse-sidebar";

export function remoteTabSelectionSidebarAction(isMobileRemoteShell: boolean): RemoteTabSelectionSidebarAction {
  return isMobileRemoteShell ? "close-drawer" : "collapse-sidebar";
}
