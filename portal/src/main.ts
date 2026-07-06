import { mount } from "svelte";
import "./portal.css";
import App from "./App.svelte";
import type { HotspotData } from "./types";

const hotspot: HotspotData = window.__HOTSPOT__ ?? { page: "login" };

const errorEl = document.getElementById("hotspot-error");
let error = errorEl?.textContent?.trim() ?? "";

// In `pnpm dev` there is no RouterOS in front of us, so the $(...) hotspot
// variables arrive unsubstituted — swap in sample values to make the pages
// previewable. Dead code in the production build.
if (import.meta.env.DEV) {
  const samples: Record<string, string> = {
    identity: "mAP lite",
    ip: "192.168.88.42",
    uptime: "1h23m45s",
    bytesInNice: "1.2 MiB",
    bytesOutNice: "8.4 MiB",
    linkLoginOnly: "#login",
    linkOrigEsc: "",
    macEsc: "AA%3ABB%3ACC%3A00%3A11%3A22",
    linkRedirect: "#redirect",
    linkLogout: "#logout",
    linkLogin: "#login",
  };
  const values = hotspot as unknown as Record<string, string>;
  for (const [key, value] of Object.entries(values)) {
    if (typeof value === "string" && value.includes("$(")) {
      values[key] = samples[key] ?? "";
    }
  }
  if (error.includes("$(")) error = "";
}

const target = document.getElementById("app");
if (!target) throw new Error("missing #app element");

mount(App, { target, props: { hotspot, error } });
