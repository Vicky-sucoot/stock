"""每日觀察名單引擎（docs/06 §1、§4）：讀資料庫 → 外資分 F → 訊息分 N → 名單與證據 → 寫入。

用法：
    python -m dca_backend.watchlist.engine [--date YYYY-MM-DD] [--export out.json]
"""

from __future__ import annotations

import argparse
import json
import sys
import uuid
from dataclasses import dataclass, field
from datetime import date, datetime, timezone
from decimal import Decimal
from typing import Callable

from sqlalchemy import func, select
from sqlalchemy.orm import Session, sessionmaker

from ..config import Settings
from ..db import create_all, make_engine, make_session_factory
from ..models import (
    Announcement,
    DailyQuote,
    ForeignFlowDaily,
    MarketInstrument,
    SignalAssessment,
    WatchlistEntry,
    WatchlistRun,
)
from ..sources import SOURCES
from .foreign import ForeignInput, ForeignScore, percentile_ranks, score_foreign
from .llm import classifier_from_env
from .params import RULE_VERSION, Params
from .signals import Assessment, Item, LLMClassifier, NewsScore, assess, cluster, score_news, window

BULLISH, BEARISH, UNCERTAIN = "BULLISH", "BEARISH", "UNCERTAIN"

DISCLAIMER = "依公開資料機械式篩選的觀察清單，不構成投資建議，不保證準確或獲利。"


@dataclass
class Candidate:
    symbol: str
    name: str
    board: str
    foreign: ForeignScore | None = None
    streak: int = 0
    news: NewsScore | None = None
    news_items: list[dict] = field(default_factory=list)
    flow_rows: list[dict] = field(default_factory=list)
    flags: list[str] = field(default_factory=list)
    liquidity: Decimal | None = None
    excluded: str | None = None

    @property
    def f(self) -> int:
        return self.foreign.score if self.foreign else 0

    @property
    def n(self) -> int:
        return self.news.score if self.news else 0


def _trading_days(s: Session, board: str, upto: date) -> list[date]:
    return list(s.scalars(select(ForeignFlowDaily.trade_date).where(ForeignFlowDaily.board == board,
                                                                    ForeignFlowDaily.trade_date <= upto)
                          .distinct().order_by(ForeignFlowDaily.trade_date)))


def _flow_history(s: Session, board: str, symbol: str, days: list[date]) -> dict[date, ForeignFlowDaily]:
    rows = s.scalars(select(ForeignFlowDaily).where(ForeignFlowDaily.board == board, ForeignFlowDaily.symbol == symbol,
                                                    ForeignFlowDaily.trade_date.in_(days)))
    return {r.trade_date: r for r in rows}


def _streak(hist: dict[date, ForeignFlowDaily], days_desc: list[date], direction: int, cap: int) -> int:
    n = 0
    for d in days_desc:
        r = hist.get(d)
        if r is None or ((r.fi_net > 0) - (r.fi_net < 0)) != direction:
            break
        n += 1
        if n >= cap:
            break
    return n


def _quotes(s: Session, symbol: str, upto: date, limit: int) -> list[DailyQuote]:
    inst = s.scalar(select(MarketInstrument).where(MarketInstrument.market == "TW", MarketInstrument.symbol == symbol))
    if inst is None:
        return []
    return list(s.scalars(select(DailyQuote).where(DailyQuote.instrument_id == inst.id, DailyQuote.trade_date <= upto,
                                                   DailyQuote.suspicious.is_(False))
                          .order_by(DailyQuote.trade_date.desc()).limit(limit)))


def _flow_dict(r: ForeignFlowDaily) -> dict:
    return {"trade_date": r.trade_date.isoformat(), "fi_buy": r.fi_buy, "fi_sell": r.fi_sell, "fi_net": r.fi_net,
            "fd_net": r.fd_net, "fi_total_net": r.fi_total_net, "source_id": r.source_id, "source_url": r.source_url,
            "raw_payload_id": r.raw_payload_id, "fetched_at": r.fetched_at.isoformat()}


def _assessment(s: Session, a: Announcement, llm: LLMClassifier | None, now: datetime) -> Assessment:
    """有快取就沿用（同一規則版本），避免重複呼叫 LLM。"""
    cached = s.scalar(select(SignalAssessment).where(SignalAssessment.announcement_id == a.id,
                                                     SignalAssessment.rule_version == RULE_VERSION))
    if cached is not None and not (llm is not None and cached.method == "RULE" and "RULE_UNDECIDED" in cached.flags):
        return Assessment(a.id, a.symbol, cached.polarity, cached.confidence, cached.relevance, cached.method,
                          cached.rationale, cached.has_negation, json.loads(cached.flags), cached.model, cached.prompt_version)
    r = assess(a.id, a.symbol, a.company_name, a.subject, a.description, llm)
    if cached is not None:
        s.delete(cached)
        s.flush()
    s.add(SignalAssessment(announcement_id=a.id, symbol=a.symbol, polarity=r.polarity, confidence=r.confidence,
                           relevance=r.relevance, has_negation=r.has_negation, method=r.method, rationale=r.rationale,
                           flags=json.dumps(r.flags), model=r.model, prompt_version=r.prompt_version,
                           rule_version=RULE_VERSION, created_at=now))
    return r


def _reason(c: Candidate) -> str:
    parts = []
    if c.foreign and c.foreign.direction != 0 and c.flow_rows:
        net = c.flow_rows[0]["fi_net"]
        side = "買" if net > 0 else "賣"
        lots = abs(net) // 1000
        ratio = f"（約占成交量 {(c.foreign.ratio * 100).quantize(Decimal('0.1'))}%）" if c.foreign.ratio is not None else ""
        lead = f"外資連續 {c.streak} 日{side}超，" if c.streak >= 2 else f"外資{side}超，"
        parts.append(f"{lead}今日淨{side} {lots:,} 張{ratio}")
    directional = [i for i in c.news_items if i["counted"] and i["polarity"] != 0]
    if directional:
        top = directional[0]
        parts.append(f"{'利多' if top['polarity'] > 0 else '利空'}訊息：{top['subject'][:30]}")
    elif c.board == "TPEX" or c.foreign:
        parts.append("無相關重大訊息")
    return "；".join(parts) + "。"


def build_watchlist(s: Session, data_date: date | None = None, p: Params = Params(),
                    llm: LLMClassifier | None = None,
                    now: Callable[[], datetime] = lambda: datetime.now(timezone.utc)) -> WatchlistRun:
    started = now()
    board = "TPEX"  # 上市（TWSE）外資來源待查（docs/07 V1）
    if data_date is None:
        data_date = s.scalar(select(func.max(ForeignFlowDaily.trade_date)).where(ForeignFlowDaily.board == board))
    run = WatchlistRun(run_id=str(uuid.uuid4()), data_date=data_date or started.date(), started_at=started,
                       status="FAILED", coverage="{}", rule_version=RULE_VERSION, params=json.dumps(p.to_dict()))
    s.add(run)
    if data_date is None:
        run.coverage = json.dumps({"foreign_TPEX": False, "foreign_TWSE": False, "announcements": False,
                                   "licensed_news": False, "llm": llm is not None})
        run.stats = json.dumps({"message": "沒有任何外資資料"})
        run.finished_at = now()
        s.commit()
        return run

    days = _trading_days(s, board, data_date)
    days_desc = list(reversed(days))
    prev_day = days_desc[1] if len(days_desc) > 1 else None
    today_rows = list(s.scalars(select(ForeignFlowDaily).where(ForeignFlowDaily.board == board,
                                                               ForeignFlowDaily.trade_date == data_date)))
    coverage = {"foreign_TPEX": bool(today_rows), "foreign_TWSE": False, "announcements": False,
                "licensed_news": False, "llm": llm is not None, "history_days": len(days)}

    cands: dict[str, Candidate] = {}
    # --- 外資 ---
    inputs: dict[str, ForeignInput] = {}
    for r in today_rows:
        c = cands.setdefault(r.symbol, Candidate(r.symbol, r.name, board))
        hist = _flow_history(s, board, r.symbol, days_desc[: p.streak_cap])
        c.flow_rows = [_flow_dict(hist[d]) for d in days_desc[: p.streak_cap] if d in hist]
        direction = (r.fi_net > 0) - (r.fi_net < 0)
        streak = _streak(hist, days_desc, direction, p.streak_cap) if direction else 0
        c.streak = streak
        if direction and streak == len(days) and streak < p.streak_points[0][0]:
            c.flags.append("HISTORY_INSUFFICIENT")
        qs = _quotes(s, r.symbol, data_date, p.liquidity_days)
        q_today = qs[0] if qs and qs[0].trade_date == data_date else None
        if q_today is None or q_today.close is None:
            c.flags.append("NO_QUOTE")
        turnovers = [Decimal(q.turnover) for q in qs if q.turnover is not None]
        if turnovers:
            c.liquidity = sum(turnovers, Decimal(0)) / len(turnovers)
            if len(turnovers) < p.liquidity_days and "HISTORY_INSUFFICIENT" not in c.flags:
                c.flags.append("HISTORY_INSUFFICIENT")
            if c.liquidity < p.min_avg_turnover:
                c.excluded = "LOW_LIQUIDITY"
        inputs[r.symbol] = ForeignInput(r.symbol, r.fi_net, streak, q_today.close if q_today else None,
                                        q_today.volume if q_today else None)
    # 規模分：同方向 |金額| 排名
    for sign in (1, -1):
        amts = {sym: Decimal(x.net_shares) * x.close for sym, x in inputs.items()
                if x.close is not None and (x.net_shares > 0) - (x.net_shares < 0) == sign}
        for sym, rank in percentile_ranks(amts).items():
            inputs[sym].pct_rank = rank
    for sym, x in inputs.items():
        cands[sym].foreign = score_foreign(x, p)

    # --- 公司重大訊息 ---
    w_start, w_end = window(data_date, prev_day, p)
    lookback = w_start.replace(hour=0, minute=0) - (w_end - w_start)
    anns = list(s.scalars(select(Announcement).where(Announcement.published_at >= lookback.astimezone(timezone.utc),
                                                     Announcement.published_at < w_end.astimezone(timezone.utc))
                          .order_by(Announcement.published_at)))
    coverage["announcements"] = any(a.published_at >= w_start for a in anns)
    by_symbol: dict[str, list[Announcement]] = {}
    for a in anns:
        by_symbol.setdefault(a.symbol, []).append(a)
    llm_calls_before = getattr(llm, "calls", 0)
    for sym, items in by_symbol.items():
        in_window = [a for a in items if a.published_at >= w_start]
        if not in_window and sym not in cands:
            continue
        c = cands.setdefault(sym, Candidate(sym, items[0].company_name, items[0].board))
        assessed = {a.id: _assessment(s, a, llm, started) for a in in_window}
        clusters = cluster([Item(a.id, a.symbol, a.subject, a.published_at) for a in in_window], p)
        reps = [assessed[cl[0].item_id] for cl in clusters]
        c.news = score_news(reps, p)
        if c.news.low_confidence:
            c.flags.append("LOW_CONFIDENCE")
        rep_ids = {cl[0].item_id: [x.item_id for x in cl[1:]] for cl in clusters}
        for a in items:
            asmt = assessed.get(a.id)
            stale = a.published_at < w_start
            c.news_items.append({
                "announcement_id": a.id, "subject": a.subject, "published_at": a.published_at.isoformat(),
                "source_id": a.source_id, "source_url": a.source_url,
                "attribution": SOURCES[a.source_id].attribution if a.source_id in SOURCES else None,
                "is_stale": stale, "counted": a.id in rep_ids and not stale,
                "duplicates": rep_ids.get(a.id, []),
                "polarity": asmt.polarity if asmt else None,
                "confidence": str(asmt.confidence) if asmt else None,
                "method": asmt.method if asmt else None,
                "rationale": asmt.rationale if asmt else "前一窗口的訊息，只列為背景，不計分",
                "flags": asmt.flags if asmt else [],
            })
        c.news_items.sort(key=lambda i: (not i["counted"], -abs(i["polarity"] or 0), i["published_at"]))

    # --- 綜合（docs/06 §4） ---
    lists: dict[str, list[tuple[Candidate, int | None, str]]] = {BULLISH: [], BEARISH: [], UNCERTAIN: []}
    for c in cands.values():
        if c.excluded:
            continue
        f, n = c.f, c.n
        if c.board != board:
            if n != 0:
                lists[UNCERTAIN].append((c, None, "上市外資資料來源尚未取得，資料不足、不判斷方向"))
            continue
        if c.foreign is None:
            if n != 0:
                lists[UNCERTAIN].append((c, None, "當日無外資資料，資料不足、不判斷方向"))
            continue
        if "NO_QUOTE" in c.flags and f != 0:
            lists[UNCERTAIN].append((c, None, "缺少當日收盤行情，無法計算金額與成交量占比"))
            continue
        if f == 0:
            continue  # 只有訊息、沒有外資動向：不列入（避免只靠訊息）
        if f * n < 0 and abs(f) >= p.conflict_min and abs(n) >= p.conflict_min:
            c.flags.append("SIGNAL_CONFLICT")
            lists[UNCERTAIN].append((c, f + n, "外資方向與訊息方向相反，訊號衝突、不判斷方向"))
            continue
        total = f + n
        if f > 0 and total >= p.list_threshold:
            lists[BULLISH].append((c, total, _reason(c)))
        elif f < 0 and total <= -p.list_threshold:
            lists[BEARISH].append((c, total, _reason(c)))

    def sort_key(item):
        c, total, _ = item
        amt = abs(c.foreign.amount) if c.foreign and c.foreign.amount is not None else Decimal(0)
        return (-(abs(total) if total is not None else -1), -amt, c.symbol)

    counts = {}
    for lt, items in lists.items():
        items.sort(key=sort_key)
        limit = p.max_uncertain if lt == UNCERTAIN else p.max_entries
        counts[lt] = len(items)
        for rank, (c, total, reason) in enumerate(items[:limit], start=1):
            s.add(WatchlistEntry(
                run_id=run.run_id, list_type=lt, rank=rank, symbol=c.symbol, name=c.name, board=c.board,
                score_total=total, score_foreign=c.f if c.foreign else None, score_news=c.n if c.news else None,
                reason_short=reason, flags=json.dumps(sorted(set(c.flags))),
                evidence=json.dumps(_evidence(c, p), ensure_ascii=False),
            ))
    run.coverage = json.dumps(coverage)
    run.status = "OK" if all(coverage[k] for k in ("foreign_TPEX", "foreign_TWSE")) else (
        "PARTIAL" if coverage["foreign_TPEX"] else "FAILED")
    run.stats = json.dumps({"candidates": len(cands), "matched": counts, "announcements": len(anns),
                            "llm_calls": getattr(llm, "calls", 0) - llm_calls_before,
                            "window": [w_start.isoformat(), w_end.isoformat()]}, ensure_ascii=False)
    run.finished_at = now()
    s.commit()
    return run


def _evidence(c: Candidate, p: Params) -> dict:
    fs = c.foreign
    return {
        "foreign": None if fs is None else {
            "unit": "shares", "rows": c.flow_rows, "streak": c.streak,
            "amount_estimated": None if fs.amount is None else str(fs.amount),
            "amount_note": "以收盤價估算（本 App 估算，非官方數值）",
            "ratio_of_volume": None if fs.ratio is None else str(fs.ratio),
            "S1_consecutive": fs.s1, "S2_big_day": fs.s2, "S3_size": fs.s3, "F": fs.score,
            "avg_turnover": None if c.liquidity is None else str(c.liquidity),
        },
        "news": None if c.news is None else {
            "N": c.news.score, "sum": str(c.news.raw_sum), "low_confidence": c.news.low_confidence,
            "formula": f"N = {p.news_scale} × tanh(Σ 方向 × 信心 × 關聯 / {p.news_divisor})",
            "items": c.news_items,
        },
        "rule_version": RULE_VERSION,
        "disclaimer": DISCLAIMER,
    }


def export_run(s: Session, run_id: str) -> dict:
    run = s.get(WatchlistRun, run_id)
    entries = s.scalars(select(WatchlistEntry).where(WatchlistEntry.run_id == run_id)
                        .order_by(WatchlistEntry.list_type, WatchlistEntry.rank)).all()
    return {
        "run_id": run.run_id, "data_date": run.data_date.isoformat(), "status": run.status,
        "coverage": json.loads(run.coverage), "rule_version": run.rule_version, "stats": json.loads(run.stats),
        "generated_at": run.finished_at.isoformat() if run.finished_at else None, "disclaimer": DISCLAIMER,
        "entries": [{"list_type": e.list_type, "rank": e.rank, "symbol": e.symbol, "name": e.name, "board": e.board,
                     "score_total": e.score_total, "score_foreign": e.score_foreign, "score_news": e.score_news,
                     "reason_short": e.reason_short, "flags": json.loads(e.flags), "evidence": json.loads(e.evidence)}
                    for e in entries],
    }


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="dca_backend.watchlist.engine")
    ap.add_argument("--date", type=date.fromisoformat, default=None)
    ap.add_argument("--init-db", action="store_true")
    ap.add_argument("--export", default=None, help="把結果寫成 JSON 檔")
    ap.add_argument("--export-dir", default=None, help="寫成 <目錄>/<資料日>.json 與 latest.json")
    args = ap.parse_args(argv)
    settings = Settings.from_env()
    engine = make_engine(settings.db_url)
    if args.init_db:
        create_all(engine)
    sf: sessionmaker[Session] = make_session_factory(engine)
    with sf() as s:
        run = build_watchlist(s, args.date, llm=classifier_from_env())
        out = export_run(s, run.run_id)
    print(f"watchlist {out['data_date']}: {out['status']} {out['stats'].get('matched')}")
    targets = [args.export] if args.export else []
    if args.export_dir:
        import os

        os.makedirs(args.export_dir, exist_ok=True)
        targets += [os.path.join(args.export_dir, f"{out['data_date']}.json"), os.path.join(args.export_dir, "latest.json")]
    for path in targets:
        with open(path, "w", encoding="utf-8") as f:
            json.dump(out, f, ensure_ascii=False, indent=1)
    return 0 if out["status"] != "FAILED" else 1


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
