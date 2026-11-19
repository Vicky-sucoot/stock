import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { registerSW } from "virtual:pwa-register";
import App from "./App";
import "./styles.css";
import { AppProvider } from "./ui/model";

// 有新版時自動更新：開啟、回到前景、以及每小時都檢查一次，避免一直使用快取中的舊版
registerSW({
  immediate: true,
  onRegisteredSW(_url, registration) {
    if (!registration) return;
    const check = () => registration.update().catch(() => undefined);
    document.addEventListener("visibilitychange", () => {
      if (document.visibilityState === "visible") check();
    });
    setInterval(check, 60 * 60 * 1000);
  },
});

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <AppProvider>
      <App />
    </AppProvider>
  </StrictMode>,
);
