"""資料來源登錄（docs/07）。App 的「資料來源」頁由 /v1/sources 提供，用來滿足顯名要求。"""

from __future__ import annotations

from dataclasses import asdict, dataclass

TWSE_BASE = "https://openapi.twse.com.tw/v1"
TPEX_BASE = "https://www.tpex.org.tw/openapi/v1"

GOV_OPEN_DATA_LICENSE = "政府資料開放授權條款－第1版"
GOV_OPEN_DATA_LICENSE_URL = "https://data.gov.tw/license"


@dataclass(frozen=True)
class Source:
    id: str
    name: str
    provider: str
    endpoint: str
    license: str
    license_url: str
    terms_url: str
    attribution: str
    verified_on: str
    # VERIFIED：已讀官方規格或條款原文；PARTIAL：部分項目待查（見 notes）
    verification: str
    notes: str = ""

    def to_dict(self) -> dict:
        return asdict(self)


_TWSE_TERMS = "https://www.twse.com.tw/zh/page/terms/use.html"
_TPEX_TERMS = "https://www.tpex.org.tw/web/inc/gtsm_disclaimer.php?l=zh-tw"
_TWSE_ATTR = "資料來源：臺灣證券交易所 OpenAPI，依政府資料開放授權條款提供"
_TPEX_ATTR = "資料來源：證券櫃檯買賣中心 OpenAPI，依政府資料開放授權條款提供"

SOURCES: dict[str, Source] = {
    s.id: s
    for s in [
        Source(
            id="TWSE_STOCK_DAY_ALL",
            name="上市個股日成交資訊",
            provider="臺灣證券交易所",
            endpoint=f"{TWSE_BASE}/exchangeReport/STOCK_DAY_ALL",
            license=GOV_OPEN_DATA_LICENSE,
            license_url=GOV_OPEN_DATA_LICENSE_URL,
            terms_url=_TWSE_TERMS,
            attribution=_TWSE_ATTR,
            verified_on="2026-11-18",
            verification="PARTIAL",
            notes="OpenAPI 規格標示授權說明為 data.gov.tw/license；TWSE 使用條款全文待查（V2）；只回傳最新一日",
        ),
        Source(
            id="TPEX_MAINBOARD_QUOTES",
            name="上櫃股票收盤行情",
            provider="證券櫃檯買賣中心",
            endpoint=f"{TPEX_BASE}/tpex_mainboard_quotes",
            license=GOV_OPEN_DATA_LICENSE,
            license_url=GOV_OPEN_DATA_LICENSE_URL,
            terms_url=_TPEX_TERMS,
            attribution=_TPEX_ATTR,
            verified_on="2026-11-18",
            verification="PARTIAL",
            notes="使用條款已讀原文：只能透過同意之方式（OpenAPI）取得，引用須註明來源並保持完整；此資料集的開放授權標示待查",
        ),
        Source(
            id="TPEX_3INSTI_DAILY",
            name="上櫃股票三大法人買賣明細資訊",
            provider="證券櫃檯買賣中心",
            endpoint=f"{TPEX_BASE}/tpex_3insti_daily_trading",
            license=GOV_OPEN_DATA_LICENSE,
            license_url=GOV_OPEN_DATA_LICENSE_URL,
            terms_url=_TPEX_TERMS,
            attribution=_TPEX_ATTR,
            verified_on="2026-11-18",
            verification="PARTIAL",
            notes="data.gov.tw 資料集 11856 標示政府資料開放授權（僅搜尋摘要）；只回傳最新一日，歷史需自行累積",
        ),
        Source(
            id="TWSE_T187AP04_L",
            name="上市公司每日重大訊息",
            provider="臺灣證券交易所（公開資訊觀測站資料）",
            endpoint=f"{TWSE_BASE}/opendata/t187ap04_L",
            license=GOV_OPEN_DATA_LICENSE,
            license_url=GOV_OPEN_DATA_LICENSE_URL,
            terms_url=_TWSE_TERMS,
            attribution=_TWSE_ATTR,
            verified_on="2026-11-18",
            verification="PARTIAL",
            notes="公開資訊觀測站原文連結格式待查；目前以 OpenAPI 端點作為來源連結",
        ),
        Source(
            id="TPEX_T187AP04_O",
            name="上櫃公司每日重大訊息",
            provider="證券櫃檯買賣中心（公開資訊觀測站資料）",
            endpoint=f"{TPEX_BASE}/mopsfin_t187ap04_O",
            license=GOV_OPEN_DATA_LICENSE,
            license_url=GOV_OPEN_DATA_LICENSE_URL,
            terms_url=_TPEX_TERMS,
            attribution=_TPEX_ATTR,
            verified_on="2026-11-18",
            verification="PARTIAL",
            notes="公開資訊觀測站原文連結格式待查；目前以 OpenAPI 端點作為來源連結",
        ),
    ]
}
