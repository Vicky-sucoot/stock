# 網頁版 App（PWA）

**為什麼是網頁版**：使用者沒有 Mac，原生 iOS App 無法編譯與安裝。網頁版用 iPhone 的 Safari 開啟後「分享 → 加入主畫面」即可像 App 一樣使用，不需要 Mac，也不需要付費的 Apple 開發者帳號。原生版程式（`ios/`）保留，日後有 Mac 時可繼續。

- 網址：`https://vicky-sucoot.github.io/stock/`（由 `.github/workflows/pages.yml` 自動發布）
- 計算核心：`src/core/` 是 Python 參考實作的 TypeScript 版，與 Python、Swift **執行同一批** `core/testcases/*.json` 共用案例
- 安全：`src/app/security.ts`（WebCrypto PBKDF2、復原碼、鎖定），規則與 iOS 版相同
- 資料：`src/app/book.ts`，存在瀏覽器的 IndexedDB；不上傳、不備份、不匯出
- 行情：每天由 GitHub Actions 從證交所與櫃買中心 OpenAPI 擷取，產生同站的 `data/quotes.json`（官方 API 不允許瀏覽器跨站讀取，所以不直接呼叫）

## 開發與測試
```bash
cd web && npm ci && npm test
```
```bash
npm run build && node e2e/run.mjs
```
端對端測試會在 Chromium 以 iPhone 13 尺寸操作完整流程（首次設定、定期定額補產生、確認、官方收盤價、手動匯率、美元檢視、重新上鎖、用復原碼重設密碼且資料不變）。執行前需在 `public/data/quotes.json` 放行情檔：
```bash
cd backend && python -m dca_backend.export_quotes --raw-dir <data 分支>/raw --out ../web/public/data/quotes.json
```

## 與原生版的差異與限制（請先了解）
| 項目 | 網頁版 | 原因 |
|---|---|---|
| 資料保存 | 瀏覽器 IndexedDB，並請求「持久儲存」 | 刪除主畫面圖示、清除 Safari 網站資料、換手機時資料會消失；**務必以「加入主畫面」方式使用**，降低被系統清除的機會 |
| 鎖定時間 | 以裝置時間計算；把時間往回調會重新計時，往後調可縮短等待 | 瀏覽器拿不到開機後的單調時間（原生版可以） |
| Face ID | 不提供 | 網頁無法直接用 Face ID 解鎖本機資料 |
| 美股、日股、基金、匯率 | 手動輸入 | 沒有可在網頁中免費且符合授權的自動來源 |
| 觀察名單 | 不顯示 | 資料需累積 20 個交易日，且公開發布前需法遵確認（倉庫與網站皆為公開） |
