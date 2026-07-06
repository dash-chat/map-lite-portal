import { defineConfig, type Plugin } from "vite";
import { svelte } from "@sveltejs/vite-plugin-svelte";

const pages = ["login", "alogin", "status", "logout", "error"];

// There is deliberately no index.html (the RouterOS hotspot serves the five
// pages by name), so the dev server's root URL would 404. Serve a small
// dev-only index there that links to the pages instead.
function devIndex(): Plugin {
  return {
    name: "dev-index",
    apply: "serve",
    configureServer(server) {
      server.middlewares.use((req, res, next) => {
        if (req.url === "/" || req.url === "/index.html") {
          res.setHeader("Content-Type", "text/html");
          res.end(
            '<!DOCTYPE html><html><head><meta charset="utf-8"><title>portal pages</title></head>' +
              '<body style="font-family: system-ui, sans-serif; padding: 2rem">' +
              "<h1>Portal pages</h1><ul>" +
              pages.map((p) => `<li><a href="/${p}.html">${p}.html</a></li>`).join("") +
              "</ul></body></html>",
          );
          return;
        }
        next();
      });
    },
  };
}

// The pages are served by the RouterOS hotspot from flash/portal, so the
// build must stay small and its file names stable (no content hashes):
// provisioning just overwrites flash/portal without having to garbage-collect
// stale hashed assets.
export default defineConfig({
  base: "./",
  plugins: [svelte(), devIndex()],
  server: {
    open: "/login.html",
  },
  build: {
    cssCodeSplit: false,
    rollupOptions: {
      input: Object.fromEntries(pages.map((p) => [p, `${p}.html`])),
      output: {
        assetFileNames: "assets/[name][extname]",
        entryFileNames: "assets/[name].js",
        chunkFileNames: "assets/[name].js",
      },
    },
  },
});
