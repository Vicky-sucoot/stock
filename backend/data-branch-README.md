# 公開市場原始資料（自動累積）

這個分支由 `.github/workflows/ingest.yml` 在平日定時寫入，**請勿手動修改**。

| 目錄 | 內容 |
|---|---|
| `raw/<來源>/<UTC 日期>/<UTC 時間>_<SHA-256 前 12 碼>.json.gz` | 官方 OpenAPI 的原始回應（gzip），內容相同就不重複存，只新增、不改寫 |
| `runs/<UTC 年-月>.jsonl` | 每次執行的結果（狀態、資料日、筆數、訊息） |

從原始檔重建資料庫：
```bash
cd backend
DCA_DB_URL=sqlite:///./data/dca.db python -m dca_backend.replay --raw-dir ../data-branch/raw --init-db
```

## 資料來源與授權
- 臺灣證券交易所 OpenAPI（https://openapi.twse.com.tw/）
- 證券櫃檯買賣中心 OpenAPI（https://www.tpex.org.tw/openapi/）
- 依政府資料開放授權條款（https://data.gov.tw/license）使用，並依規定標示提供機關
- 資料只供本專案內部累積與分析；查核紀錄見主分支的 `docs/07-source-verification.md`
