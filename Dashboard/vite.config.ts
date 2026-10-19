import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// The production build is served by the ModelMatrix controller at
// http://localhost:7700. `pnpm dev` proxies the API to a running controller.
const controller = (globalThis as any).process?.env?.MODELMATRIX_CONTROLLER_URL ?? "http://127.0.0.1:7700";

export default defineConfig({
  plugins: [react()],
  base: "/",
  build: {
    outDir: "dist",
    assetsDir: "assets",
    sourcemap: false,
    chunkSizeWarningLimit: 1600,
  },
  server: {
    port: 5173,
    proxy: {
      "/api": {
        target: controller,
        changeOrigin: true,
        configure: (proxy: any) => {
          // Present dev requests to the controller like local CLI calls.
          proxy.on("proxyReq", (request: any) => {
            for (const header of ["origin", "referer", "sec-fetch-site", "sec-fetch-mode", "sec-fetch-dest"]) {
              request.removeHeader(header);
            }
          });
        },
      },
    },
  },
});
