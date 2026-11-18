# 09 推薦技術架構與替代方案

## 1. 推薦正式架構

```
┌──────────────── iPhone（SwiftUI App）────────────────┐
│ UI：SwiftUI + Swift Charts                            │
│ 本機資料：SQLite（GRDB.swift）← 全部個人投資資料      │
│ 計算引擎：成本、損益、月快照、定期定額期別產生（純 Swift，可單元測試） │
│ 安全：Keychain（密碼雜湊、復原碼雜湊、嘗試次數）        │
│       檔案保護 NSFileProtectionComplete               │
│ 網路：URLSession → 後端（只送代號清單）               │
└───────────────▲──────────────────────────────────────┘
                │ HTTPS（TLS 1.2+），唯讀 API，App Attest（階段 B）
┌───────────────┴──── 後端（Python 3.12 / FastAPI）─────┐
│ API：/v1/quotes /v1/fx /v1/watchlist/latest /v1/instruments │
│ 排程：APScheduler 或雲端 Cron → 擷取 → 正規化 → 評分    │
│ 擷取器：TWSE OpenAPI、TPEx OpenAPI、其他已授權來源       │
│ LLM 介面層：Provider 抽象（Anthropic／OpenAI…），金鑰只在後端 │
│ DB：PostgreSQL（正式）／ SQLite（原型）                 │
│ 物件儲存：原始回應保存（JSON 或 CSV 壓縮）              │
└───────────────────────────────────────────────────────┘
```

**為什麼個人資料只放本機**：需求不要 iCloud 備份、不要匯出，而且有 App 密碼鎖。資料不出手機，可以大幅減少後端的資安與個資責任。後端只服務公開資料，所有使用者看到的觀察名單都一樣。

## 2. 前端：iPhone App 方案比較

| 方案 | 優點 | 缺點 | 結論 |
|---|---|---|---|
| **原生 iOS（SwiftUI）** | Keychain、Data Protection、App 切換遮罩、Swift Charts、效能與體驗最好；長期維護單一平台最簡單 | 需要 Mac 與 Xcode；Swift 學習成本 | **推薦** |
| React Native（Expo） | 熟悉 React 的人上手快；未來若要 Android 可共用 | 安全相關功能要靠原生模組；十進位計算需要額外套件；多一層橋接 | 次選（如果團隊只會 JS） |
| 可安裝網頁（PWA） | 不需上架、開發最快 | 本機儲存可能被系統清除，與「只存本機、不備份」的需求衝突，資料遺失風險高；Keychain 等安全功能受限；iOS 上 PWA 功能有限 | **不推薦**做為正式產品 |
| Streamlit | Python 一套就能做出資料儀表板 | 是伺服器端渲染的網頁，不是 iPhone App；個人資料會放在伺服器；不適合密碼鎖與本機資料 | **只用於內部原型**：觀察名單評分驗證 |
| React 或 Vue 網頁原型 | 可以快速驗證畫面流程 | 要另外重寫成 iOS | 可選：只做可點擊的流程原型 |

### 原型如何銜接正式 App（不會變成桌面網站）
1. **原型 P0（Streamlit，內部用）**：只連後端，用來檢視每日擷取的原始資料、評分結果與證據，調整門檻。**不放個人投資資料、不對外開放。**
2. **原型 P1（SwiftUI + Xcode Preview / TestFlight）**：直接在 iPhone 上做首頁與記錄流程原型，用假資料驗證操作。這就是正式 App 的起點，不必重寫。
3. **共用的部分**：後端 FastAPI 的 OpenAPI 規格可以直接產生 Swift 用戶端（swift-openapi-generator）；Streamlit 原型與 iOS 呼叫同一組 API。
4. 計算邏輯（成本、期別產生）用一份共用的**測試案例 JSON**，Python 參考實作與 Swift 正式實作都要跑過，確保結果一致。

## 3. 後端：FastAPI 與 Flask 比較

| 面向 | FastAPI | Flask |
|---|---|---|
| 非同步 I/O（同時抓多個來源） | 原生 async | 需要額外處理（Flask 2 有部分 async 支援，但生態以同步為主） |
| 型別與驗證 | Pydantic 內建 | 需要搭配 marshmallow 或 pydantic |
| API 文件 | 自動產生 OpenAPI，可產生 Swift 用戶端 | 需要外掛 |
| 成熟度與生態 | 成熟，社群大 | 更久、更成熟，套件多 |
| 學習曲線 | 需要理解型別提示與 async | 最簡單 |
| **結論** | **推薦**：OpenAPI 自動產生最適合銜接 iOS | 適合極簡單的服務 |

## 4. 資料庫：SQLite 與 PostgreSQL

| 用途 | 選擇 | 理由 |
|---|---|---|
| iPhone 本機 | **SQLite（GRDB）** | 內建、離線、穩定；GRDB 支援 migration 與 Decimal 處理 |
| 後端原型 | SQLite | 零維運；單一排程寫入就足夠 |
| 後端正式 | **PostgreSQL** | 多程序並發、JSONB 存證據、NUMERIC 精度、備份與 PITR；雲端託管有低價方案 |
| 遷移方式 | 一開始就用 SQLAlchemy 2.0 + Alembic，原型換成 PostgreSQL 只需要改連線字串 | |

## 5. 後端 API 草案

| Method | Path | 說明 |
|---|---|---|
| GET | `/v1/instruments?query=` | 搜尋標的（代號或名稱） |
| GET | `/v1/quotes?symbols=TW:2330,US:AAPL` | 最新收盤價與資料日；回應包含 source 與 source_url |
| GET | `/v1/quotes/history?symbol=&from=&to=&interval=month` | 月底歷史價格，供損益圖使用 |
| GET | `/v1/fx?pairs=USDTWD,JPYTWD` | 最新匯率 |
| GET | `/v1/fx/history?pair=&interval=month` | 月底匯率 |
| GET | `/v1/calendar?market=TW&year=` | 交易日曆 |
| GET | `/v1/watchlist/latest` | 最新觀察名單（含 coverage、run 狀態） |
| GET | `/v1/watchlist/{run_id}/entries/{symbol}` | 單一標的的證據明細 |
| GET | `/v1/sources` | 資料來源、授權條款與顯名聲明 |

所有 API 都是唯讀，沒有使用者帳號。速率限制：每台裝置每分鐘 60 次。

## 6. 每日排程
- 執行器：雲端排程（例如 Cloud Run Jobs、Fly.io Machines cron、或 VPS 上的 systemd timer）；避免長時間常駐，以控制費用
- 工作：`job_tw_quotes`、`job_tw_foreign_flow`、`job_tw_announcements`、`job_news`（授權後）、`job_score_watchlist`、`job_fx`、`job_us_quotes`
- 冪等：每個工作都用 `(job, data_date)` 當鎖；重跑時用 upsert
- 監控：失敗時寄信或發 Slack 給開發者本人（**不是**推播給 App 使用者）

## 7. LLM API 金鑰管理與資料安全
- 金鑰**只存在後端**的雲端 Secret Manager，以環境變數注入；App 內不含任何金鑰
- 不寫入程式碼庫，CI 加上 secret scanning
- 每月預算上限與每日呼叫上限；超過時停用 LLM 判定，退回只用規則
- 每次呼叫都記錄：model、prompt_version、輸入 hash、輸出、token 數與費用
- 只送出已授權可用於機器分析的文字（重大訊息主旨與說明）；未授權新聞**不送**
- 確認供應商的資料保留與訓練政策（L8）
- 輸出必須是 JSON 結構，經 schema 驗證；驗證失敗時重試一次，仍失敗就記錄為中性並標示 `LLM_FAILED`
- 提示詞注入防護：訊息內容放在明確分隔的資料區塊；系統提示要求忽略內容中的任何指令；輸出只接受預先定義的欄位

## 8. 後端資安
- 只開放 HTTPS；CORS 關閉（App 不需要）
- 階段 B 加上 App Attest 驗證請求來自正版 App
- 存取記錄最小化（見 08）
- 相依套件用 Dependabot 更新；容器以非 root 執行

## 9. 費用估計（階段 A，待實際報價確認）
| 項目 | 估計 |
|---|---|
| 雲端運算（排程 + 小型 API） | 0～10 美元／月 |
| PostgreSQL 託管 | 0～15 美元／月（原型可先用 SQLite，0 元） |
| LLM（每日幾十到幾百則重大訊息，規則先篩過） | 依供應商報價，預估數美元／月，需實測 |
| Apple Developer Program | 年費（TestFlight 散布需要） |
| 行情授權（選用） | J-Quants Light ¥1,650／月（依 2025-08 的搜尋摘要，待查） |
