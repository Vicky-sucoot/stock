# 04 資料欄位與資料庫草案

資料分兩處存放：

- **iPhone 本機（SQLite）**：所有個人投資資料。不上傳，也不做 iCloud 備份。
- **後端（PostgreSQL；原型階段用 SQLite）**：只放公開市場資料與觀察名單結果，**不含任何使用者資料**。

金額與數量一律用十進位：Swift 用 `Decimal`；SQLite 存成 TEXT 或整數最小單位；PostgreSQL 用 `NUMERIC`。**不使用浮點數。**

## 1. 本機資料庫（iPhone）

### portfolio 投資組合
| 欄位 | 型別 | 說明 |
|---|---|---|
| id | UUID PK | |
| name | TEXT UNIQUE | 1～20 字 |
| description | TEXT? | |
| color | TEXT | |
| default_currency | TEXT | TWD/USD/JPY |
| include_in_overview | BOOL | 預設 true |
| sort_order | INT | |
| archived_at | DATETIME? | |
| created_at / updated_at | DATETIME | |

### instrument 標的（本機快取與自建）
| 欄位 | 型別 | 說明 |
|---|---|---|
| id | UUID PK | |
| market | TEXT | TW_TWSE / TW_TPEX / US / JP / FUND_TW_DOMESTIC / FUND_TW_OFFSHORE |
| asset_type | TEXT | STOCK / ETF / FUND |
| symbol | TEXT | 例如 0050、AAPL、7203、基金代碼 |
| name | TEXT | |
| currency | TEXT | 計價幣別 |
| lot_size | INT? | 參考用 |
| price_decimals | INT | |
| source_ref | TEXT? | 後端標的 ID；若為自建則留空 |
| is_user_defined | BOOL | 例如找不到資料的基金 |
| UNIQUE(market, symbol) | | |

### plan 定期定額計畫
| 欄位 | 型別 | 說明 |
|---|---|---|
| id | UUID PK | |
| portfolio_id | FK | |
| instrument_id | FK | |
| amount_mode | TEXT | AMOUNT / QUANTITY |
| amount | DECIMAL | 每期原幣金額，或每期數量 |
| currency | TEXT | |
| frequency | TEXT | WEEKLY / MONTHLY / DATES |
| weekdays | TEXT? | 例如 "1,4"（ISO 週一=1） |
| month_days | TEXT? | 例如 "6,16,31" |
| specific_dates | TEXT? | JSON 日期陣列 |
| holiday_rule | TEXT | NEXT_TRADING_DAY（預設）/ PREV_TRADING_DAY |
| start_date / end_date | DATE / DATE? | |
| fee_mode | TEXT | FIXED / RATE |
| fee_value / fee_min | DECIMAL | |
| fee_currency | TEXT | 可與標的幣別不同（例如複委託以台幣收費） |
| paused | BOOL | |
| last_generated_date | DATE? | 補產生期數用的游標 |
| note | TEXT? | |

### plan_occurrence 期別（待確認）
| 欄位 | 型別 | 說明 |
|---|---|---|
| id | UUID PK | |
| plan_id | FK | |
| period_key | TEXT | 例如 "2027-02#31"、"2027-W06#1"、"D2027-03-15" |
| nominal_date | DATE | 名義扣款日（已套用月底規則） |
| scheduled_date | DATE | 套用休市規則後的日期 |
| adjust_reason | TEXT? | MONTH_END / HOLIDAY_FORWARD / HOLIDAY_BACKWARD / MERGED |
| status | TEXT | PENDING / CONFIRMED / SKIPPED |
| est_price / est_quantity | DECIMAL? | |
| transaction_id | FK? | 確認後連到交易 |
| UNIQUE(plan_id, period_key) | | 防止重複產生 |

### transaction 交易
| 欄位 | 型別 | 說明 |
|---|---|---|
| id | UUID PK | |
| portfolio_id / instrument_id | FK | |
| type | TEXT | BUY / SELL / DIVIDEND_CASH / DIVIDEND_STOCK / DIVIDEND_REINVEST / FEE / SPLIT_ADJUST |
| trade_date | DATE | |
| price | DECIMAL? | 原幣；基金時為淨值 |
| quantity | DECIMAL? | 股數或單位數，支援 6 位小數；分割時填比例 |
| gross_amount | DECIMAL | 成交金額或股利總額（原幣） |
| fee | DECIMAL | 手續費 |
| tax | DECIMAL | 證交稅／預扣稅 |
| other_cost | DECIMAL | 匯費、二代健保、其他 |
| cost_currency | TEXT | 費用幣別（預設等於標的幣別） |
| currency | TEXT | 標的幣別 |
| fx_rate_at_trade | DECIMAL? | 交易日 1 單位原幣兌 TWD；選填 |
| occurrence_id | FK? | 由定期定額確認而來 |
| note | TEXT? | |
| created_at / updated_at | DATETIME | |

### price_override 手動價格或淨值 ／ fx_override 手動匯率
| 欄位 | 型別 | 說明 |
|---|---|---|
| id | UUID PK | |
| instrument_id 或 currency_pair | | 匯率的幣別對，例如 USD/TWD |
| value | DECIMAL | |
| effective_date | DATE | 生效日 |
| set_at | DATETIME | |
| note | TEXT? | |
| active | BOOL | 只有使用者「改回自動」時才會變成 false |

**優先順序**：如果該標的或幣別對有 active 的手動值，**一律採用最新一筆 active 手動值**，自動更新只會寫進 `price_cache`，不會碰手動值。

### price_cache ／ fx_cache（自動取得的值，可重建）
| 欄位 | 說明 |
|---|---|
| key（instrument_id 或幣別對）、date、value | |
| source | 例如 TWSE_OPENAPI_STOCK_DAY_ALL |
| source_url | |
| data_date | 資料本身的日期 |
| fetched_at | 取得時間 |
| is_delayed / is_estimated | 延遲或推估標記 |

### monthly_snapshot（快取，可重建）
`portfolio_id?`（空值代表合併）、`month`（YYYY-MM）、`view_currency`、`market_value`、`invested`、`pnl_ex_div`、`pnl_inc_div`、`is_estimated`、`computed_at`

### app_security（Keychain，不放 SQLite）
見 [10](10-passcode-recovery.md)。另外存放：`face_id_enabled`、`biometric_domain_state`、`data_loss_ack_at`（使用者勾選資料保存說明的時間），以及使用者自備的美股 API 金鑰 `user_quote_api_key`（R2-4）。

## 2. 後端資料庫（公開資料）

### market_instrument
`id`、`market`、`symbol`、`name`、`asset_type`、`currency`、`listed_board`（TWSE/TPEX）、`active`、`updated_at`

### daily_quote
`instrument_id`、`trade_date`、`close`、`open`、`high`、`low`、`volume`、`turnover`、`source`、`source_url`、`fetched_at`、`raw_json`；PK(`instrument_id`, `trade_date`, `source`)

### fx_rate
`pair`、`rate_date`、`rate`、`rate_type`（中價／即期買入／即期賣出）、`source`、`source_url`、`fetched_at`

### trading_calendar
`market`、`date`、`is_open`、`note`、`source`

### foreign_flow_daily（外資買賣超原始資料）
| 欄位 | 說明 |
|---|---|
| trade_date, board（TWSE/TPEX）, symbol, name | |
| fi_buy_shares, fi_sell_shares, fi_net_shares | 外資及陸資（不含外資自營商） |
| fd_buy_shares, fd_sell_shares, fd_net_shares | 外資自營商 |
| fi_total_net_shares | 外資及陸資合計 |
| source_endpoint, source_url, fetched_at, raw_json | 保存原始回應，供追溯 |
| PK(trade_date, board, symbol) | |

### announcement（公司重大訊息）與 news_item（授權新聞）
| 欄位 | 說明 |
|---|---|
| id, source（MOPS_TWSE / MOPS_TPEX / 授權新聞來源代碼） | |
| published_at（含時區）, fetched_at | |
| title, summary_or_excerpt | **只存授權範圍內的內容**；未授權新聞只存標題與連結 |
| url, related_symbols[] | |
| content_hash, cluster_id | 去重複用 |
| license_basis | 例如 GOV_OPEN_DATA / LICENSED_<合約編號> / HEADLINE_LINK_ONLY |

### signal_assessment（每則訊息的判定）
`item_id`、`symbol`、`polarity`（+1/0/-1）、`confidence`（0～1）、`relevance`（0～1）、`is_stale`、`has_negation`、`rationale`（≤80 字）、`model`、`prompt_version`、`rule_version`、`created_at`

### watchlist_run ／ watchlist_entry
- run：`run_id`、`data_date`、`started_at`、`finished_at`、`status`（OK / PARTIAL / FAILED）、`coverage`（JSON：各來源是否成功）、`rule_version`
- entry：`run_id`、`list_type`（BULLISH / BEARISH / UNCERTAIN）、`rank`、`symbol`、`name`、`board`、`score_total`、`score_foreign`、`score_news`、`reason_short`、`evidence`（JSON：外資明細列、訊息 id、計算步驟）、`uncertainty_flags`

### fetch_log
`job`、`url`、`http_status`、`attempt`、`started_at`、`duration_ms`、`error`、`bytes`，用於錯誤重試與稽核。
