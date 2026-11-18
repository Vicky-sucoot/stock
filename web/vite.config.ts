import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";
import { VitePWA } from "vite-plugin-pwa";

// GitHub Pages 的子路徑：https://<帳號>.github.io/stock/
const base = process.env.DCA_BASE ?? "./";

export default defineConfig({
  base,
  plugins: [
    react(),
    VitePWA({
      registerType: "autoUpdate",
      includeAssets: ["icon.svg", "apple-touch-icon.png"],
      manifest: {
        name: "定期定額投資管理",
        short_name: "定期定額",
        description: "規劃與記錄定期定額投資；資料只存在這支手機。",
        lang: "zh-Hant-TW",
        start_url: ".",
        scope: ".",
        display: "standalone",
        background_color: "#ffffff",
        theme_color: "#1d4ed8",
        icons: [
          { src: "icon-192.png", sizes: "192x192", type: "image/png" },
          { src: "icon-512.png", sizes: "512x512", type: "image/png" },
          { src: "icon-512.png", sizes: "512x512", type: "image/png", purpose: "maskable" },
        ],
      },
      workbox: {
        // 行情檔每天更新：先用網路，離線時用快取
        runtimeCaching: [{ urlPattern: /data\/.*\.json$/, handler: "NetworkFirst" }],
        globPatterns: ["**/*.{js,css,html,svg,png}"],
      },
    }),
  ],
  test: { environment: "node" },
});
