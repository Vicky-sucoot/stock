# 計算核心（第一階段）

規格見 [docs/02](../docs/02-portfolio-plans-calc.md)、[docs/05](../docs/05-market-data-fx-chart.md)。

| 目錄 | 內容 |
|---|---|
| `core/python/dca_core/` | Python 參考實作（後端與原型共用） |
| `core/testcases/*.json` | **共用測試案例**：Python 與 Swift 執行同一批檔案，結果必須一致 |
| `ios/DCACore/` | Swift Package：iOS App 的正式實作（iOS 17+／macOS 14+） |

## 模組

| 功能 | Python | Swift |
|---|---|---|
| 交易日曆、市場時區 | `calendar.py` | `TradingCalendar.swift`、`LocalDate.swift` |
| 定期定額期別（月底規則、休市順延或提前、合併、補產生、預覽） | `schedule.py` | `Schedule.swift` |
| 交易回放（移動平均成本、賣出、股利、再投入、分割、費用幣別） | `ledger.py` | `Ledger.swift` |
| 價格與匯率解析（手動優先）、幣別換算、合併總覽 KPI | `valuation.py` | `Valuation.swift` |
| 全期間月資料點（推估標記、原幣模式） | `snapshots.py` | `Snapshots.swift` |

## 執行測試

Python：
```bash
cd core/python && python3 -m pytest -q
```

Swift（需要 macOS 與 Xcode 15+，或 Swift 5.9+ 工具鏈）：
```bash
cd ios/DCACore && swift test
```

## 共用案例的格式約定
- 金額、數量、匯率一律以**字串**表示十進位數；兩邊都用十進位型別（Python `Decimal`、Swift `Decimal`），不使用浮點數
- 比較時兩邊都以銀行家捨入（四捨六入五成雙）取到小數 8 位
- 日期為 `YYYY-MM-DD`；匯率為「1 單位幣別 = ? TWD」
- `schedule_cases.json` 中的休市日是**測試用固定資料**，不是官方休市表
- 新增規則時：先在 JSON 加案例 → Python 通過 → Swift 通過

## 第一階段已決定的計算口徑（補充 docs/02）
- **股利再投入**：再投入金額同時計入持有成本與「含股利損益」，但**不**計入「歷史總投入」。`invested_current = cost_basis − reinvested_cost`，賣出時兩者依比例扣減
- **股票股利**：增加數量，成本不變
- **獨立費用（FEE）**：「含股利」與「不含股利」兩種損益都會扣除，不計入投入
- **全部賣出**：數量歸零時成本歸零，之後重新起算平均成本；已實現損益保留
- **費用幣別**：與標的幣別不同時，用 `fx_rate_at_trade` 換算；沒有就需要 `fx_fallback`，否則報錯 `FX_REQUIRED`
- **同日交易**：依 `trade_date`、`seq`、輸入順序排序
- **期別合併**：調整後落在同一天的期別各自保留 `period_key`，並互相列在 `merged_keys`；UI 顯示成一筆「含 n 期」
- **交易日曆未更新**：超出 `known_through` 時只排除週末，並設定 `calendar_unknown = true`
- **尚未實作**：「按交易日匯率」的成本口徑（docs/02 §2.2 的選用模式），以及 XIRR，排在後續階段
