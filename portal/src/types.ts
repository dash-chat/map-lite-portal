// Contract between the HTML entry shells (where RouterOS substitutes the
// $(...) hotspot variables) and the Svelte app. Every field except `page`
// depends on which page the router is serving.

export type HotspotPage = "login" | "alogin" | "status" | "logout" | "error";

export interface HotspotData {
  page: HotspotPage;
  identity?: string;
  linkLoginOnly?: string;
  linkOrigEsc?: string;
  macEsc?: string;
  linkRedirect?: string;
  linkLogout?: string;
  linkLogin?: string;
  ip?: string;
  uptime?: string;
  bytesInNice?: string;
  bytesOutNice?: string;
}

export interface PageProps {
  hotspot: HotspotData;
  error?: string;
}

declare global {
  interface Window {
    __HOTSPOT__?: HotspotData;
  }
}
