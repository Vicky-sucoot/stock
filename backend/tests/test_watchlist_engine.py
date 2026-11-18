from __future__ import annotations

import json
from datetime import date, datetime, timezone
from decimal import Decimal

import pytest
from sqlalchemy import func, select

from dca_backend.models import (
    Announcement,
    DailyQuote,
    ForeignFlowDaily,
    MarketInstrument,
    SignalAssessment,
    WatchlistEntry,
)
from dca_backend.parsing import TAIPEI
from dca_backend.watchlist.engine import BEARISH, BULLISH, UNCERTAIN, build_watchlist, export_run
from dca_backend.watchlist.signals import LLMJudgement

DAYS = [date(2026, 11, 12), date(2026, 11, 13), date(2026, 11, 16), date(2026, 11, 17), date(2026, 11, 18)]
NOW = datetime(2026, 11, 18, 12, 0, tzinfo=timezone.utc)

# symbol: (每日外資買賣超股數, 收盤, 成交股數)；最後一天為資料日
SERIES = {
    "A001": ([1_000_000] * 4 + [3_200_000], "85", 21_000_000),  # 連 5 買、單日大幅
    "A002": ([-100_000, -50_000, 300_000, 400_000, 600_000], "40", 15_000_000),  # 連 3 買、規模小
    "A003": ([500_000, -100_000, -200_000, -300_000, -2_500_000], "120", 9_000_000),  # 連 4 賣、單日大幅
    "A004": ([300_000] * 4 + [1_800_000], "60", 12_000_000),  # 連買但有利空訊息 → 衝突
    "LOWL": ([100_000] * 4 + [150_000], "10", 200_000),  # 成交金額太低 → 排除
    "NOQ1": ([100_000] * 4 + [900_000], "50", 5_000_000),  # 當日缺行情
}


def tp(d: date, hh: int, mm: int = 0) -> datetime:
    return datetime(d.year, d.month, d.day, hh, mm, tzinfo=TAIPEI)


def seed(s):
    now = NOW
    for sym, (nets, close, vol) in SERIES.items():
        inst = MarketInstrument(market="TW", board="TPEX", symbol=sym, name=f"測試{sym}", asset_type="STOCK",
                                currency="TWD", active=True, updated_at=now)
        s.add(inst)
        s.flush()
        for d, net in zip(DAYS, nets):
            s.add(ForeignFlowDaily(trade_date=d, board="TPEX", symbol=sym, name=f"測試{sym}",
                                   fi_buy=max(net, 0) + 1000, fi_sell=max(-net, 0) + 1000, fi_net=net,
                                   fd_buy=0, fd_sell=0, fd_net=0, fi_total_buy=0, fi_total_sell=0, fi_total_net=net,
                                   source_id="TPEX_3INSTI_DAILY", source_url="https://example.invalid/3insti",
                                   fetched_at=now))
            if sym == "NOQ1" and d == DAYS[-1]:
                continue
            c = Decimal(close)
            s.add(DailyQuote(instrument_id=inst.id, trade_date=d, source_id="TPEX_MAINBOARD_QUOTES", close=c,
                             volume=vol, turnover=int(c * vol), suspicious=False, fetched_at=now))
    D = DAYS[-1]
    anns = [
        ("A001", "TPEX", "公告本公司取得重大訂單", tp(D, 8)),
        ("A001", "TPEX", "公告本公司 取得重大訂單。", tp(D, 8, 10)),  # 重複
        ("A001", "TPEX", "公告本公司董事會決議發放現金股利", tp(DAYS[-2], 9)),  # 前一窗口：背景，不計分
        ("A004", "TPEX", "公告本公司更正財報", tp(DAYS[-2], 15)),
        ("B001", "TWSE", "公告本公司取得重大訂單", tp(D, 7)),  # 上市：資料不足
        ("C001", "TPEX", "公告本公司取得重大訂單", tp(D, 9)),  # 上櫃但當日無外資資料
        ("A002", "TPEX", "公告本公司子公司資訊", tp(D, 10)),  # 規則無法判定
        ("A001", "TPEX", "公告本公司取得重大訂單", tp(D, 14)),  # 13:30 之後：屬下一窗口
    ]
    for i, (sym, board, subject, t) in enumerate(anns):
        s.add(Announcement(source_id="TPEX_T187AP04_O" if board == "TPEX" else "TWSE_T187AP04_L", board=board,
                           symbol=sym, company_name=f"測試{sym}", published_at=t, subject=subject,
                           source_url="https://example.invalid/ann", content_hash=f"h{i}",
                           license_basis="GOV_OPEN_DATA", fetched_at=now))
    s.commit()


@pytest.fixture
def db(session_factory):
    with session_factory() as s:
        seed(s)
    return session_factory


def entries(s, run_id):
    rows = s.scalars(select(WatchlistEntry).where(WatchlistEntry.run_id == run_id)
                     .order_by(WatchlistEntry.list_type, WatchlistEntry.rank)).all()
    out = {BULLISH: [], BEARISH: [], UNCERTAIN: []}
    for r in rows:
        out[r.list_type].append(r)
    return out


def test_end_to_end_lists(db):
    with db() as s:
        run = build_watchlist(s, now=lambda: NOW)
        assert run.data_date == DAYS[-1]
        assert run.status == "PARTIAL"  # 上市外資資料來源尚未取得
        cov = json.loads(run.coverage)
        assert cov["foreign_TPEX"] and not cov["foreign_TWSE"] and cov["announcements"]
        e = entries(s, run.run_id)

        bull = [(x.symbol, x.score_foreign, x.score_news, x.score_total) for x in e[BULLISH]]
        # A001：S1 15 + S2 20 + S3 0（3 檔買超中排第 1 → 1/3，未達前 10%）= 35；訊息 +19（重複公告只計一次）
        assert bull == [("A001", 35, 19, 54)]
        assert e[BULLISH][0].reason_short == "外資連續 5 日買超，今日淨買 3,200 張（約占成交量 15.2%）；利多訊息：公告本公司取得重大訂單。"

        bear = [(x.symbol, x.score_foreign, x.score_total) for x in e[BEARISH]]
        assert bear == [("A003", -38, -38)]  # S1 13 + S2 25 + S3 0（唯一賣超 → 1/1）

        unc = [(x.symbol, x.score_total) for x in e[UNCERTAIN]]
        # A004：外資 +35、訊息 −19 → 衝突；其餘為資料不足，依代號排序
        assert unc == [("A004", 16), ("B001", None), ("C001", None), ("NOQ1", None)]
        reasons = {x.symbol: x.reason_short for x in e[UNCERTAIN]}
        assert "訊號衝突" in reasons["A004"] and "上市" in reasons["B001"]
        assert "無外資資料" in reasons["C001"] and "收盤行情" in reasons["NOQ1"]

        listed = {x.symbol for lst in e.values() for x in lst}
        assert "LOWL" not in listed  # 流動性過濾
        assert "A002" not in listed  # F = 10，未達門檻


def test_evidence_is_traceable(db):
    with db() as s:
        run = build_watchlist(s, now=lambda: NOW)
        a001 = entries(s, run.run_id)[BULLISH][0]
        ev = json.loads(a001.evidence)
        assert ev["foreign"]["streak"] == 5
        assert [r["fi_net"] for r in ev["foreign"]["rows"]][0] == 3_200_000
        assert all(r["source_url"] for r in ev["foreign"]["rows"])
        assert ev["foreign"]["amount_estimated"] == "272000000"
        items = ev["news"]["items"]
        counted = [i for i in items if i["counted"]]
        assert len(counted) == 1 and counted[0]["duplicates"]  # 重複的那則列在 duplicates
        stale = [i for i in items if i["is_stale"]]
        assert stale and stale[0]["subject"] == "公告本公司董事會決議發放現金股利"
        assert all(i["source_url"] and i["published_at"] for i in items)
        assert "不構成投資建議" in ev["disclaimer"]
        flags = json.loads(a001.flags)
        assert "HISTORY_INSUFFICIENT" in flags  # 只有 5 天歷史


def test_assessments_are_cached_and_llm_only_for_undecided(db):
    class FakeLLM:
        model, prompt_version = "fake", "t"

        def __init__(self):
            self.calls = 0

        def classify(self, *a):
            self.calls += 1
            return LLMJudgement(1, Decimal("0.9"), Decimal(1), False, "測試")

    llm = FakeLLM()
    with db() as s:
        build_watchlist(s, llm=llm, now=lambda: NOW)
        assert llm.calls == 1  # 只有「子公司資訊」交給 LLM
        n = s.scalar(select(func.count()).select_from(SignalAssessment))
        build_watchlist(s, llm=llm, now=lambda: NOW)
        assert llm.calls == 1  # 第二次使用快取
        assert s.scalar(select(func.count()).select_from(SignalAssessment)) == n


def test_no_data_fails(session_factory):
    with session_factory() as s:
        run = build_watchlist(s, now=lambda: NOW)
        assert run.status == "FAILED"


def test_export_is_json_serializable(db):
    with db() as s:
        run = build_watchlist(s, now=lambda: NOW)
        out = export_run(s, run.run_id)
        text = json.dumps(out, ensure_ascii=False)
        assert out["data_date"] == "2026-11-18" and "不構成投資建議" in text
        assert len(out["entries"]) == 6


def test_watchlist_api(db):
    from fastapi.testclient import TestClient

    from dca_backend.api import create_app

    client = TestClient(create_app(db))
    assert client.get("/v1/watchlist/latest").status_code == 404
    with db() as s:
        run = build_watchlist(s, now=lambda: NOW)
    body = client.get("/v1/watchlist/latest").json()
    assert body["run_id"] == run.run_id and body["status"] == "PARTIAL"
    assert all("evidence" not in e for e in body["entries"])
    detail = client.get(f"/v1/watchlist/{run.run_id}/entries/a001").json()
    assert detail["list_type"] == BULLISH and detail["evidence"]["foreign"]["streak"] == 5
    assert client.get(f"/v1/watchlist/{run.run_id}/entries/ZZZZ").status_code == 404
