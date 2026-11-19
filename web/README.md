# 網頁版 App（PWA）

**為什麼是網頁版**：使用者沒有 Mac，原生 iOS App 無法編譯與安裝。網頁版用 iPhone 的 Safari 開啟後「分享 → 加入主畫面」即可像 App 一樣使用，不需要 Mac，也不需要付費的 Apple 開發者帳號。原生版程式（`ios/`）保留，日後有 Mac 時可繼續。

- 網址：`https://vicky-sucoot.github.io/stock/`（由 `.github/workflows/pages.yml` 自動發布）
- 計算核心：`src/core/` 是 Python 參考實作的 TypeScript 版，與 Python、Swift **執行同一批** `core/testcases/*.json` 共用案例
- 開啟密碼與 Face ID：依使用者決定關閉（docs/10），打開即進入
- 資料：`src/app/book.ts`，存在瀏覽器的 IndexedDB；不上傳、不備份、不匯出
- 行情：每天由 GitHub Actions 從證交所與櫃買中心 OpenAPI 擷取，產生同站的 `data/quotes.json`（官方 API 不允許瀏覽器跨站讀取，所以不直接呼叫）

## 疑難排解：打開後仍是舊版（例如仍要求設定密碼）
1. **確認 GitHub Pages 的來源**：倉庫的 Settings → Pages → Build and deployment → Source 必須是「**GitHub Actions**」。若設成「Deploy from a branch」，GitHub 會把 README 發布成網頁，蓋掉 App，手機上快取的舊版也無法更新（`sw.js` 會變成 404）。`pages` workflow 的 `verify` 步驟會檢查這件事
2. 改好後重新執行 `pages` workflow（Actions → pages → Run workflow）
3. 在 iPhone 上把 App 完全關閉，重新開啟一到兩次；App 會自動下載新版
4. 若仍是舊版，才考慮刪除主畫面圖示並清除 Safari 的網站資料——**這會刪除本機所有投資資料**，請先確認沒有重要紀錄

## 開發與測試
```bash
cd web && npm ci && npm test
```
```bash
npm run build && node e2e/run.mjs
```
端對端測試會在 Chromium 以 iPhone 13 尺寸操作完整流程（首次使用、定期定額補產生、確認、官方收盤價、手動匯率、美元檢視、重新開啟直接進入且資料不變、刪除需輸入名稱、清除全部資料）。執行前需在 `public/data/quotes.json` 放行情檔：
```bash
cd backend && python -m dca_backend.export_quotes --raw-dir <data 分支>/raw --out ../web/public/data/quotes.json
```

## 與原生版的差異與限制（請先了解）
| 項目 | 網頁版 | 原因 |
|---|---|---|
| 資料保存 | 瀏覽器 IndexedDB，並請求「持久儲存」 | 刪除主畫面圖示、清除 Safari 網站資料、換手機時資料會消失；**務必以「加入主畫面」方式使用**，降低被系統清除的機會 |
| 開啟密碼、Face ID | 不提供（依使用者決定關閉） | 以手機本身的鎖屏保護 |
| 美股、日股、基金、匯率 | 手動輸入 | 沒有可在網頁中免費且符合授權的自動來源 |
| 每日名單（名單分頁） | 建議買入／建議賣出／訊號衝突 | 以通關密語加密發布、只給自己看；需 GitHub Secret `WATCHLIST_PASSPHRASE`，設定 `ANTHROPIC_API_KEY` 時由 Claude 評分（docs/06 §8） |
