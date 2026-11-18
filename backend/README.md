# 後端：公開市場資料管線（第二階段）

規格：[docs/06](../docs/06-daily-watchlist.md)、[docs/07](../docs/07-source-verification.md)、[docs/09](../docs/09-architecture.md)。
**只處理公開市場資料，不接收、不儲存任何使用者的投資資料。**

## 已實作

| 項目 | 說明 |
|---|---|
| 擷取來源 | TWSE `STOCK_DAY_ALL`、TPEx `tpex_mainboard_quotes`（收盤行情）；TPEx `tpex_3insti_daily_trading`（外資及陸資買賣超）；TWSE `t187ap04_L`、TPEx `mopsfin_t187ap04_O`（公司重大訊息）。**只走官方 OpenAPI，不爬網頁**（TPEx 使用條款第五點） |
| 禮貌存取 | 同主機兩次請求間隔 ≥ 10 秒；網路錯誤、5xx 或 429 時最多重試 2 次（等 5 秒、15 秒）；4xx 不重試；User-Agent 為通用字串 |
| 追溯 | 每次嘗試寫入 `fetch_log`；原始回應以 gzip 存在 `DCA_RAW_DIR`，`raw_payload` 記錄 SHA-256；每筆行情、外資、訊息資料都連回 `raw_payload_id` |
| 資料檢查 | 收盤價 ≤ 0，或與前一個有效收盤價相差 > 50%，標記為可疑、API 不採用；外資「買進 − 賣出 ≠ 買賣超」的列會跳過並記錄；必要欄位消失時整個來源失敗（`SCHEMA`），並回滾，不留半套資料 |
| 冪等 | 行情與外資用主鍵 upsert；重大訊息用內容雜湊去重複。重跑沒有副作用 |
| 新鮮度 | 平日資料日早於今天時，工作狀態為 `NOT_UPDATED`（資料仍會存入），結束碼 2，讓排程稍後再試 |
| API | `/healthz`、`/v1/sources`、`/v1/quotes`、`/v1/instruments`、`/v1/foreign-flow/{symbol}`、`/v1/status`；唯讀、無帳號；金額以字串回傳 |
| 資料庫 | SQLAlchemy 2 + Alembic；原型用 SQLite（金額以字串精確保存、時間一律存 UTC），正式改 PostgreSQL 只需要換 `DCA_DB_URL` |

## 使用方式

```bash
cd backend
pip install -e ".[test]"
python -m pytest -q
```

建立資料庫並執行一次完整擷取：
```bash
export DCA_DB_URL=sqlite:///./data/dca.db DCA_RAW_DIR=./data/raw
alembic upgrade head
python -m dca_backend.jobs tw_daily
```

啟動 API：
```bash
uvicorn dca_backend.api:app --port 8000
```

### 環境變數
| 變數 | 預設 | 說明 |
|---|---|---|
| `DCA_DB_URL` | `sqlite:///./data/dca.db` | 正式環境：`postgresql+psycopg://...` |
| `DCA_RAW_DIR` | `./data/raw` | 原始回應保存目錄 |
| `DCA_REQUEST_INTERVAL_S` | `10` | 同主機請求間隔 |
| `DCA_RETRY_BACKOFF_S` | `5,15` | 重試等待秒數 |

### 建議排程（台灣時間，平日）
```
CRON_TZ=Asia/Taipei
35 14,15,16,17,19,21 * * 1-5  python -m dca_backend.jobs tw_quotes
32 15,16,17,19,21    * * 1-5  python -m dca_backend.jobs tw_foreign_flow
*/30 8-21            * * 1-5  python -m dca_backend.jobs tw_announcements
```
官方公布時間尚未查證（docs/07 V3），以上是保守排程；請連續觀察 2 週的 `job_run` 再調整。

## 實測紀錄（2026-11-19 00:51 台灣時間）
- 5 個端點全部 HTTP 200；共寫入 3,467 列（行情 2,412、外資 899、重大訊息 156），沒有可疑資料，原始回應約 256 KB
- 42 檔當日未成交，收盤價為空值：TPEx 以 `----` 表示，TWSE 以空字串表示
- **TWSE `STOCK_DAY_ALL` 的資料日仍是 11/17，TPEx 已是 11/18**，可見 TWSE OpenAPI 的收盤行情至少落後一個交易日；App 必須顯示資料日
- TPEx 三大法人端點回應約 8.6 秒

## 尚未實作（後續階段）
- 上市（TWSE）個股外資資料：官方管道待查（docs/07 V1）
- 交易日曆、匯率、美股與日股、基金淨值
- 觀察名單評分（第四階段）
- 每台裝置的速率限制與 App Attest（第六階段）
- 正式部署與排程主機
