# 07 外部資料來源查核表

**查核日期**：2026-11-18（UTC；台灣時間 2026-11-19 凌晨）
**查核方式**：從雲端工作環境直接以 HTTP 請求取得官方 OpenAPI 規格檔、範例回應與條款頁面原文。無法直接開啟的項目，會註明「僅搜尋摘要」或「待查」。
**說明**：表中「✅ 已查核」只代表當天看到的內容。官方可能隨時修改端點或條款，上線前必須重新查核。

## 1. 台灣證券交易所（TWSE）

| 項目 | 查核結果 | 狀態 |
|---|---|---|
| OpenAPI 規格 | https://openapi.twse.com.tw/v1/swagger.json（標題「臺灣證券交易所 OpenAPI」1.0，共 143 個路徑） | ✅ 已查核 |
| 授權 | 規格說明連到「使用條款」https://www.twse.com.tw/zh/page/terms/use.html 與「授權說明網址」https://data.gov.tw/license（政府資料開放授權條款） | ✅ 連結已查核；**TWSE 使用條款內文無法取得**（網站對自動化請求回應安全性阻擋頁或中斷連線）→ 待查 |
| 上市個股收盤行情 | `GET /v1/exchangeReport/STOCK_DAY_ALL`：欄位 Date（民國年 YYYMMDD）、Code、Name、TradeVolume、TradeValue、OpeningPrice、HighestPrice、LowestPrice、ClosingPrice、Change、Transaction。**只回傳最新一個交易日** | ✅ 已查核。範例：台灣時間 11/19 00 時取得的資料日為 1151117，比 TPEx 晚一天 → 更新時間待查 |
| 公司重大訊息（上市） | `GET /v1/opendata/t187ap04_L`：欄位 出表日期、發言日期、發言時間、公司代號、公司名稱、主旨、符合條款、事實發生日、說明 | ✅ 已查核 |
| 外資持股相關 | `/v1/fund/MI_QFIIS_cat`（類股持股比率）、`/v1/fund/MI_QFIIS_sort_20`（持股前 20 名） | ✅ 已查核；**不是每日個股買賣超** |
| **個股三大法人或外資買賣超日報（T86／TWT38U）** | **OpenAPI 規格中沒有這兩項**。網站報表路徑 `https://www.twse.com.tw/rwd/zh/fund/T86`、`/fund/TWT38U` 對自動化請求回應「因為安全性考量，您所執行的頁面無法呈現」 | ❌ **P0 風險**：取得方式、授權、更新時間、歷史範圍都待查。可能的選項：①向 TWSE 詢問 OpenAPI 是否會提供或有其他官方管道；②申請 TWSE 資訊授權或購買盤後資訊；③確認網站報表是否允許自動下載。**確認前，上市標的一律列為「資料不足」** |
| 交易日曆 | 規格中沒有找到開休市日期的端點；網站「開休市日期」頁面無法自動存取 | 待查（MVP 可每年手動維護一次） |
| 基金基本資料 | `/v1/opendata/t187ap47_L`「基金基本資料彙總表」 | ✅ 有此端點；內容是否包含淨值待查 |
| 費用與頻率限制 | 規格中未載明費用或流量限制 | 待查；實作時自我限制（每端點每天少量請求，間隔至少 10 秒） |

## 2. 證券櫃檯買賣中心（TPEx）

| 項目 | 查核結果 | 狀態 |
|---|---|---|
| OpenAPI 規格 | https://www.tpex.org.tw/openapi/swagger.json（「證券櫃檯買賣中心 OpenAPI」1.0.0，共 225 個路徑；支援 JSON 與 CSV） | ✅ 已查核 |
| 三大法人買賣明細 | `GET /openapi/v1/tpex_3insti_daily_trading`。欄位：Date（民國年）、SecuritiesCompanyCode、CompanyName；外資及陸資（不含外資自營商）買進／賣出／買賣超股數；外資自營商買進／賣出／買賣超；外資及陸資合計買進／賣出／買賣超；投信買進／賣出／買賣超；自營商買進／賣出／買賣超（含避險）；三大法人買賣超股數合計。**實測只回傳最新一日**（2026-11-18 取得的資料日為 1151118，涵蓋 ETF，例如 00411A） | ✅ 已查核 |
| 外資及陸資買賣超彙總表 | `GET /openapi/v1/tpex_3insti_qfii_trading`（含 Rank，單位寫「仟股」，與明細表單位不同，實作時要注意） | ✅ 已查核 |
| 上櫃收盤行情 | `GET /openapi/v1/tpex_mainboard_quotes`：Date、Code、Name、Close、Change、Open、High、Low、TradingShares、TransactionAmount 等 | ✅ 已查核 |
| 重大訊息（上櫃） | `GET /openapi/v1/mopsfin_t187ap04_O` | ✅ 端點存在 |
| 開放式基金行情 | `GET /openapi/v1/tpex_opfund_latest`（只涵蓋在櫃買交易的開放式基金） | ✅ 端點存在 |
| 使用條款 | https://www.tpex.org.tw/web/inc/gtsm_disclaimer.php?l=zh-tw，第五點：「非依櫃檯買賣中心同意之方式或經櫃檯買賣中心所同意者，禁止透過包括但不限於自動化裝置、指令碼、自動程式、蜘蛛程式、爬蟲程式或擷取程式等方式下載本網站之軟體或資料」；第七點：除授權給政府資料開放平臺的資料外，須事前取得書面同意才能使用或重製；引用時應「清楚註明資料來源，並確保資料完整性，不得任意增刪」 | ✅ 已查核原文。**結論：只透過 OpenAPI 取得，不爬網頁報表** |
| 開放資料授權 | 政府資料開放平臺資料集 11856（上櫃股票三大法人買賣明細）標示每日更新、免費、政府資料開放授權條款 | ⚠️ 僅搜尋摘要（data.gov.tw 資料集頁面未直接開啟） |
| 歷史資料 | OpenAPI 只提供最新一日；歷史資料需要後端每天累積，或由網站報表取得（自動化下載受第五點限制） | ⚠️ 歷史回補方式待查 |
| 公布時間 | 未查到官方說明 | 待查 |

## 3. 政府資料開放授權條款
來源：https://data.gov.tw/license（✅ 已查核原文）
- 使用者必須依附件「顯名聲明」標示原資料提供機關；「未盡顯名標示義務者，視為自始未取得開放資料之授權」
- 與 CC BY 4.0 相容
- 資料提供機關不保證資料正確，並可停止提供
- **實作要求**：App 的「資料來源」頁與觀察名單明細頁，都必須顯示提供機關名稱與授權條款名稱

## 4. 匯率

| 來源 | 結果 | 狀態 |
|---|---|---|
| 臺灣銀行牌告匯率 https://rate.bot.com.tw/xrt 與 CSV 下載路徑 `/xrt/flcsv/0/day` | 自動化請求收到「Challenge Validation」挑戰頁，無法取得內容；使用條款未取得 | ❌ 待查；未經同意不得繞過挑戰頁 |
| 中央銀行 https://www.cbc.gov.tw | 連線遭中斷，未取得 | 待查（建議查政府資料開放平臺上的央行匯率資料集與授權） |
| 替代方案 | 例如付費 FX API，或由使用者手動輸入；MVP 允許手動 | 待選定 |

## 5. 美股、日股、基金

| 來源 | 結果 | 狀態 |
|---|---|---|
| Finnhub 條款 https://finnhub.io/terms-of-service | 原文：「You hereby agree to not redistribute or share access to data or derived results from the data obtained from Finnhub with anyone or any 3rd party without written approval」、「All plan listed on Finnhub website is strictly for personal use unless explicitly stated otherwise」 | ✅ 已查核。**只能個人用途**；後端轉發給他人屬於再散布，需書面授權 |
| Alpha Vantage 條款 https://www.alphavantage.co/terms_of_service/ | 頁面可連線，但條款內文由前端動態載入，未取得 | 待查 |
| JPX J-Quants | 方案頁回應 403。依搜尋摘要（JPX 2025-08-22 新聞稿 https://www.jpx.co.jp/corporate/news/news-releases/6020/20250822-01.html）：免費方案資料延遲 12 週（過去 2 年）；Light ¥1,650／月、Standard ¥3,300／月、Premium ¥16,500／月 | ⚠️ 僅搜尋摘要；第三方顯示或再散布條款待查 |
| 境內與境外基金淨值（投信投顧公會、基金資訊觀測站） | 首頁可連線，下載方式、API 與授權條款尚未查到 | 待查；MVP 用手動 |

## 6. 新聞網站（著作權、API、爬取限制）

| 網站 | robots.txt 查核（✅ 已讀原文） | 使用條款與授權 | 結論 |
|---|---|---|---|
| 中央社 cna.com.tw | 宣告 `Content-signal: search=yes, ai-input=yes, ai-train=no`；GPTBot、ClaudeBot 等 AI 爬蟲列在「阻擋：AI 訓練／模型語料」群組 | 著作權頁網址未找到（嘗試的路徑回應 404）；新聞授權方案待查 | 未取得授權前不爬取；可洽詢商業授權 |
| 聯合新聞網、經濟日報 money.udn.com | 註解原文：「Any other uses are not permitted, incl. but not limited to: for large language models (LLMs), machine learning and/or artificial intelligence-related purposes ... and/or for any commercial purposes. Contact copyright@udn.com」；GPTBot、Claude、ClaudeBot `Disallow: /` | 明確禁止 LLM 與商業用途 | **不可**用於 LLM 分析；只能取得授權後使用 |
| 工商時報 ctee.com.tw | 阻擋清單包含 anthropic-ai、ClaudeBot、GPTBot、ChatGPT-User、OAI-SearchBot 等 | 條款待查 | 未取得授權前不爬取 |
| 鉅亨網 news.cnyes.com | 一般 User-agent `Allow: /`，有少數 Disallow | 使用條款待查 | robots.txt 允許不等於授權重製；待查 |

**原則**：未確認授權前，不爬取、不保存、不重製新聞全文，也不送進 LLM。

**符合授權的替代方案（依優先順序）**
1. **公司重大訊息**：TWSE `t187ap04_L` 與 TPEx `mopsfin_t187ap04_O`，屬於官方 OpenAPI 與政府開放資料（MVP 採用）
2. **洽談新聞授權**：中央社、經濟日報、鉅亨網等媒體的商業授權或資料 API，合約必須明確允許「機器分析（含 LLM）」與「在 App 顯示標題、摘要與連結」
3. **只顯示標題與連結**：只在授權或 RSS 條款允許時使用，且不做全文分析
4. **使用者自行貼上連結**：App 只保存連結與使用者自己寫的摘要，不在後端抓取內容

## 7. 待查清單（上線前必須補齊）

| # | 項目 | 建議做法 |
|---|---|---|
| V1 | TWSE 上市個股外資買賣超的官方取得方式與授權 | 來函或電洽 TWSE 資訊服務窗口 |
| V2 | TWSE 網站使用條款全文 | 用瀏覽器人工開啟並存檔 |
| V3 | TWSE 與 TPEx 三大法人資料每日公布時間 | 官方說明或連續 2 週觀察紀錄 |
| V4 | TPEx 歷史三大法人資料的合法取得方式 | 洽詢 TPEx 或從上線日開始累積 |
| V5 | 台股交易日曆的官方來源 | TWSE「開休市日期」頁（人工）或 OpenAPI |
| V6 | 匯率來源與授權 | 臺灣銀行、央行或付費 API |
| V7 | 美股與日股行情的商業授權（階段 B） | 供應商合約 |
| V8 | 基金淨值來源與授權 | 投信投顧公會、集保結算所 |
| V9 | 新聞授權 | 媒體授權合約 |
