import { defineConfig } from "vite";
import { svelte } from "@sveltejs/vite-plugin-svelte";

// The pages are served by the RouterOS hotspot from flash/portal, so the
// build must stay small and its file names stable (no content hashes):
// provisioning just overwrites flash/portal without having to garbage-collect
// stale hashed assets.
export default defineConfig({
  base: "./",
  plugins: [svelte()],
  build: {
    cssCodeSplit: false,
    rollupOptions: {
      input: {
        login: "login.html",
        alogin: "alogin.html",
        status: "status.html",
        logout: "logout.html",
        error: "error.html",
      },
      output: {
        assetFileNames: "assets/[name][extname]",
        entryFileNames: "assets/[name].js",
        chunkFileNames: "assets/[name].js",
      },
    },
  },
});
