"""唯讀 API（docs/09 §5）。沒有使用者帳號，也不接收任何持股資料。

金額一律以字串回傳，讓 App 用 Decimal 解析，避免浮點誤差。

啟動：uvicorn dca_backend.api:app
"""

from __future__ import annotations

import json
import re

from fastapi import Depends, FastAPI, HTTPException, Query
from sqlalchemy import func, or_, select
from sqlalchemy.orm import Session, sessionmaker

from .config import Settings
from .db import make_engine, make_session_factory
from .models import DailyQuote, ForeignFlowDaily, JobRun, MarketInstrument, WatchlistEntry, WatchlistRun
from .sources import SOURCES
from .watchlist.engine import export_run

SYMBOL_RE = re.compile(r"^TW:[0-9A-Z]{4,6}$")
MAX_SYMBOLS = 200


def _s(v) -> str | None:
    return None if v is None else str(v)


def create_app(session_factory: sessionmaker[Session]) -> FastAPI:
    app = FastAPI(title="DCA 公開市場資料 API", version="0.1.0", docs_url="/docs", redoc_url=None)

    def get_session():
        with session_factory() as s:
            yield s

    @app.get("/healthz")
    def healthz():
        return {"status": "ok"}

    @app.get("/v1/sources")
    def sources():
        return {"sources": [s.to_dict() for s in SOURCES.values()]}

    @app.get("/v1/quotes")
    def quotes(symbols: str = Query(..., description="以逗號分隔，例如 TW:2330,TW:6488"),
               session: Session = Depends(get_session)):
        wanted = [x.strip().upper() for x in symbols.split(",") if x.strip()]
        if not wanted or len(wanted) > MAX_SYMBOLS:
            raise HTTPException(400, f"symbols must contain 1..{MAX_SYMBOLS} items")
        bad = [x for x in wanted if not SYMBOL_RE.match(x)]
        if bad:
            raise HTTPException(400, f"invalid symbols: {', '.join(bad[:10])}")
        out, missing = [], []
        for sym in dict.fromkeys(wanted):
            code = sym.split(":", 1)[1]
            inst = session.scalar(select(MarketInstrument).where(MarketInstrument.market == "TW",
                                                                 MarketInstrument.symbol == code))
            q = None
            if inst is not None:
                # 最新一筆「有收盤價且未被標記可疑」的報價
                q = session.scalar(
                    select(DailyQuote)
                    .where(DailyQuote.instrument_id == inst.id, DailyQuote.close.is_not(None),
                           DailyQuote.suspicious.is_(False))
                    .order_by(DailyQuote.trade_date.desc(), DailyQuote.fetched_at.desc())
                    .limit(1)
                )
            if inst is None or q is None:
                missing.append(sym)
                continue
            src = SOURCES[q.source_id]
            out.append({
                "symbol": sym, "name": inst.name, "board": inst.board, "asset_type": inst.asset_type,
                "currency": inst.currency, "close": _s(q.close), "change": _s(q.change),
                "data_date": q.trade_date.isoformat(), "fetched_at": q.fetched_at.isoformat(),
                "source_id": src.id, "source_url": src.endpoint, "attribution": src.attribution,
            })
        return {"quotes": out, "missing": missing}

    @app.get("/v1/instruments")
    def instruments(query: str = Query(..., min_length=1, max_length=32),
                    limit: int = Query(20, ge=1, le=50), session: Session = Depends(get_session)):
        q = query.strip()
        rows = session.scalars(
            select(MarketInstrument)
            .where(MarketInstrument.active.is_(True),
                   or_(MarketInstrument.symbol.startswith(q.upper()), MarketInstrument.name.contains(q)))
            .order_by(func.length(MarketInstrument.symbol), MarketInstrument.symbol)
            .limit(limit)
        ).all()
        return {"instruments": [
            {"symbol": f"{r.market}:{r.symbol}", "name": r.name, "board": r.board,
             "asset_type": r.asset_type, "currency": r.currency} for r in rows
        ]}

    @app.get("/v1/foreign-flow/{symbol}")
    def foreign_flow(symbol: str, days: int = Query(10, ge=1, le=60), session: Session = Depends(get_session)):
        """觀察名單明細頁用：近 n 個交易日的外資原始數據（單位：股）。"""
        sym = symbol.upper()
        if not SYMBOL_RE.match(sym):
            raise HTTPException(400, "invalid symbol")
        code = sym.split(":", 1)[1]
        rows = session.scalars(
            select(ForeignFlowDaily).where(ForeignFlowDaily.symbol == code)
            .order_by(ForeignFlowDaily.trade_date.desc()).limit(days)
        ).all()
        return {"symbol": sym, "unit": "shares", "rows": [
            {"trade_date": r.trade_date.isoformat(), "board": r.board, "name": r.name,
             "fi_buy": r.fi_buy, "fi_sell": r.fi_sell, "fi_net": r.fi_net,
             "fd_net": r.fd_net, "fi_total_net": r.fi_total_net,
             "source_id": r.source_id, "source_url": r.source_url,
             "attribution": SOURCES[r.source_id].attribution,
             "fetched_at": r.fetched_at.isoformat()} for r in rows
        ]}

    @app.get("/v1/watchlist/latest")
    def watchlist_latest(session: Session = Depends(get_session)):
        """最新一次觀察名單（第五階段 App 使用）。每個標的的完整證據另以明細端點取得。"""
        run = session.scalar(select(WatchlistRun).where(WatchlistRun.finished_at.is_not(None))
                             .order_by(WatchlistRun.data_date.desc(), WatchlistRun.finished_at.desc()).limit(1))
        if run is None:
            raise HTTPException(404, "no watchlist yet")
        out = export_run(session, run.run_id)
        for e in out["entries"]:
            e.pop("evidence")
        return out

    @app.get("/v1/watchlist/{run_id}/entries/{symbol}")
    def watchlist_entry(run_id: str, symbol: str, session: Session = Depends(get_session)):
        rows = session.scalars(select(WatchlistEntry).where(WatchlistEntry.run_id == run_id,
                                                            WatchlistEntry.symbol == symbol.upper())).all()
        if not rows:
            raise HTTPException(404, "entry not found")
        e = rows[0]
        return {"run_id": run_id, "list_type": e.list_type, "rank": e.rank, "symbol": e.symbol, "name": e.name,
                "board": e.board, "score_total": e.score_total, "score_foreign": e.score_foreign,
                "score_news": e.score_news, "reason_short": e.reason_short, "flags": json.loads(e.flags),
                "evidence": json.loads(e.evidence)}

    @app.get("/v1/status")
    def status(session: Session = Depends(get_session)):
        """各工作最近一次執行結果，供 App 顯示資料完整度。"""
        latest = {}
        for job in session.scalars(select(JobRun.job).distinct()).all():
            r = session.scalar(select(JobRun).where(JobRun.job == job)
                               .order_by(JobRun.started_at.desc()).limit(1))
            latest[job] = {"status": r.status, "data_date": r.data_date.isoformat() if r.data_date else None,
                           "finished_at": r.finished_at.isoformat() if r.finished_at else None}
        return {"jobs": latest}

    return app


def _default_app() -> FastAPI:  # pragma: no cover
    settings = Settings.from_env()
    return create_app(make_session_factory(make_engine(settings.db_url)))


def __getattr__(name: str):  # pragma: no cover - 讓 `uvicorn dca_backend.api:app` 延遲建立
    if name == "app":
        return _default_app()
    raise AttributeError(name)
