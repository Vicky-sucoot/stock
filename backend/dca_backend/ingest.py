"""把官方回應轉成資料表列（冪等 upsert）。欄位名稱以實測回應為準（2026-11-18）。"""

from __future__ import annotations

import hashlib
import html
from dataclasses import dataclass, field
from datetime import date, datetime
from decimal import Decimal

from sqlalchemy import select
from sqlalchemy.orm import Session

from .models import Announcement, DailyQuote, ForeignFlowDaily, MarketInstrument, RawPayload
from .parsing import dec, integer, norm_keys, roc_date, roc_time, taipei_datetime
from .sources import Source

# 與前一個有效收盤價相比，變動超過此比例就標記為可疑、不採用（docs/05 §4）
SUSPICIOUS_CHANGE = Decimal("0.5")


class SchemaError(ValueError):
    """官方欄位不見了：代表上游格式變更，必須人工確認。"""


@dataclass
class IngestResult:
    data_dates: set[date] = field(default_factory=set)
    rows: int = 0
    skipped: int = 0
    suspicious: list[str] = field(default_factory=list)

    @property
    def data_date(self) -> date | None:
        return max(self.data_dates) if self.data_dates else None


def _req(row: dict, key: str, source: Source) -> str:
    if key not in row:
        raise SchemaError(f"{source.id}: missing field {key!r}")
    return row[key]


def _asset_type(symbol: str) -> str:
    # 台灣 ETF 代號以 00 開頭（簡化判斷；之後可改用官方 ETF 清單）
    return "ETF" if symbol.startswith("00") else "STOCK"


def _instrument(session: Session, board: str, symbol: str, name: str, now: datetime) -> MarketInstrument:
    inst = session.scalar(select(MarketInstrument).where(MarketInstrument.market == "TW", MarketInstrument.symbol == symbol))
    if inst is None:
        inst = MarketInstrument(market="TW", board=board, symbol=symbol, name=name,
                                asset_type=_asset_type(symbol), currency="TWD", active=True, updated_at=now)
        session.add(inst)
        session.flush()
    elif inst.name != name or inst.board != board:
        inst.name, inst.board, inst.updated_at = name, board, now
    return inst


# ---------- 收盤行情 ----------

_QUOTE_FIELDS = {
    "TWSE": dict(date="Date", symbol="Code", name="Name", open="OpeningPrice", high="HighestPrice",
                 low="LowestPrice", close="ClosingPrice", change="Change", volume="TradeVolume", turnover="TradeValue"),
    "TPEX": dict(date="Date", symbol="SecuritiesCompanyCode", name="CompanyName", open="Open", high="High",
                 low="Low", close="Close", change="Change", volume="TradingShares", turnover="TransactionAmount"),
}


def _previous_close(session: Session, instrument_id: int, before: date) -> Decimal | None:
    return session.scalar(
        select(DailyQuote.close)
        .where(DailyQuote.instrument_id == instrument_id, DailyQuote.trade_date < before,
               DailyQuote.close.is_not(None), DailyQuote.suspicious.is_(False))
        .order_by(DailyQuote.trade_date.desc())
        .limit(1)
    )


def ingest_quotes(session: Session, rows: list[dict], source: Source, board: str,
                  payload: RawPayload, now: datetime) -> IngestResult:
    f = _QUOTE_FIELDS[board]
    res = IngestResult()
    for raw in rows:
        r = norm_keys(raw)
        d = roc_date(_req(r, f["date"], source))
        symbol = _req(r, f["symbol"], source).strip()
        if d is None or not symbol:
            res.skipped += 1
            continue
        inst = _instrument(session, board, symbol, _req(r, f["name"], source).strip(), now)
        close = dec(r.get(f["close"]))
        reason = None
        if close is not None:
            if close <= 0:
                reason = "NON_POSITIVE_CLOSE"
            else:
                prev = _previous_close(session, inst.id, d)
                if prev is not None and prev > 0 and abs(close / prev - 1) > SUSPICIOUS_CHANGE:
                    reason = "CHANGE_GT_50PCT"
        if reason:
            res.suspicious.append(f"{symbol}:{reason}")
        session.merge(DailyQuote(
            instrument_id=inst.id, trade_date=d, source_id=source.id,
            open=dec(r.get(f["open"])), high=dec(r.get(f["high"])), low=dec(r.get(f["low"])),
            close=close, change=dec(r.get(f["change"])),
            volume=integer(r.get(f["volume"])), turnover=integer(r.get(f["turnover"])),
            suspicious=reason is not None, suspicious_reason=reason,
            raw_payload_id=payload.id, fetched_at=now,
        ))
        res.data_dates.add(d)
        res.rows += 1
    session.flush()
    return res


# ---------- 外資及陸資買賣超（TPEx 三大法人明細） ----------

_FLOW_KEYS = {
    "fi_buy": "ForeignInvestorsincludeMainlandAreaInvestors(ForeignDealersexcluded)-TotalBuy",
    "fi_sell": "ForeignInvestorsincludeMainlandAreaInvestors(ForeignDealersexcluded)-TotalSell",
    "fi_net": "ForeignInvestorsincludeMainlandAreaInvestors(ForeignDealersexcluded)-Difference",
    "fd_buy": "ForeignDealers-TotalBuy",
    "fd_sell": "ForeignDealers-TotalSell",
    "fd_net": "ForeignDealers-Difference",
    "fi_total_buy": "ForeignInvestorsIncludeMainlandAreaInvestors-TotalBuy",
    "fi_total_sell": "ForeignInvestorsIncludeMainlandAreaInvestors-TotalSell",
    "fi_total_net": "ForeignInvestorsIncludeMainlandAreaInvestors-Difference",
}
_FLOW_OPTIONAL = {
    "it_net": "SecuritiesInvestmentTrustCompanies-Difference",
    "dealer_net": "Dealers-Difference",
    "total_net": "TotalDifference",
}


def ingest_tpex_foreign_flow(session: Session, rows: list[dict], source: Source,
                             payload: RawPayload, now: datetime) -> IngestResult:
    res = IngestResult()
    for raw in rows:
        r = norm_keys(raw)
        d = roc_date(_req(r, "Date", source))
        symbol = _req(r, "SecuritiesCompanyCode", source).strip()
        values = {k: integer(_req(r, key, source)) for k, key in _FLOW_KEYS.items()}
        if d is None or not symbol or any(v is None for v in values.values()):
            res.skipped += 1
            continue
        # 內部一致性：買進 − 賣出 = 買賣超（不一致時跳過，保留原始資料供人工檢查）
        if values["fi_buy"] - values["fi_sell"] != values["fi_net"]:
            res.skipped += 1
            res.suspicious.append(f"{symbol}:FI_NET_MISMATCH")
            continue
        optional = {k: integer(r.get(key)) for k, key in _FLOW_OPTIONAL.items()}
        session.merge(ForeignFlowDaily(
            trade_date=d, board="TPEX", symbol=symbol, name=_req(r, "CompanyName", source).strip(),
            **values, **optional,
            source_id=source.id, source_url=source.endpoint, raw_payload_id=payload.id, fetched_at=now,
        ))
        res.data_dates.add(d)
        res.rows += 1
    session.flush()
    return res


# ---------- 公司重大訊息 ----------

_ANN_FIELDS = {
    "TWSE": dict(symbol="公司代號", name="公司名稱"),
    "TPEX": dict(symbol="SecuritiesCompanyCode", name="CompanyName"),
}


def ingest_announcements(session: Session, rows: list[dict], source: Source, board: str,
                         payload: RawPayload, now: datetime) -> IngestResult:
    f = _ANN_FIELDS[board]
    res = IngestResult()
    for raw in rows:
        r = norm_keys(raw)
        symbol = _req(r, f["symbol"], source).strip()
        ann_date = roc_date(_req(r, "發言日期", source))
        published = taipei_datetime(ann_date, roc_time(r.get("發言時間")))
        # 官方資料以 HTML 實體表示部分罕用字（實測如 &#12070;），先還原
        subject = html.unescape(_req(r, "主旨", source) or "").strip()
        if not symbol or published is None or not subject:
            res.skipped += 1
            continue
        h = hashlib.sha256(f"{board}|{symbol}|{published.isoformat()}|{subject}".encode()).hexdigest()
        exists = session.scalar(select(Announcement.id).where(Announcement.source_id == source.id,
                                                             Announcement.content_hash == h))
        if exists is None:
            session.add(Announcement(
                source_id=source.id, board=board, symbol=symbol,
                company_name=html.unescape(_req(r, f["name"], source)).strip(), published_at=published,
                subject=subject, clause=(r.get("符合條款") or None), fact_date=roc_date(r.get("事實發生日")),
                description=html.unescape(r["說明"]) if r.get("說明") else None, source_url=source.endpoint, content_hash=h,
                license_basis="GOV_OPEN_DATA", raw_payload_id=payload.id, fetched_at=now,
            ))
            res.rows += 1
        res.data_dates.add(ann_date)
    session.flush()
    return res
