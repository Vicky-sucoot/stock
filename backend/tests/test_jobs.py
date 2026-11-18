from __future__ import annotations

import gzip
import hashlib
import json
from datetime import date, datetime, timezone
from decimal import Decimal

import httpx
from sqlalchemy import func, select

from dca_backend.config import Settings
from dca_backend.fetch import Fetcher
from dca_backend.ingest import ingest_quotes
from dca_backend.jobs import FAILED, NOT_UPDATED, OK, PARTIAL, exit_code, run_job
from dca_backend.models import (
    Announcement,
    DailyQuote,
    FetchLog,
    ForeignFlowDaily,
    JobRun,
    MarketInstrument,
    RawPayload,
)
from dca_backend.sources import SOURCES

from .conftest import WED_4PM, fixture_rows

SAT_NOON = datetime(2026, 11, 21, 4, 0, tzinfo=timezone.utc)


def count(sf, model) -> int:
    with sf() as s:
        return s.scalar(select(func.count()).select_from(model))


def test_tw_daily_ingests_all_sources(session_factory, settings, server):
    run = run_job(session_factory, settings, "tw_daily", client=server.client(), now=lambda: WED_4PM)
    # TWSE 收盤行情的資料日（11/17）早於今天（11/18），所以整體是 NOT_UPDATED
    assert run.status == NOT_UPDATED
    assert "TWSE_STOCK_DAY_ALL data_date=2026-11-17" in run.message
    assert run.data_date == date(2026, 11, 18)
    assert exit_code(run.status) == 2

    n_quotes = len(fixture_rows("twse_stock_day_all.json")) + len(fixture_rows("tpex_mainboard_quotes.json"))
    assert count(session_factory, DailyQuote) == n_quotes
    assert count(session_factory, ForeignFlowDaily) == len(fixture_rows("tpex_3insti_daily_trading.json"))
    n_ann = len(fixture_rows("twse_t187ap04_L.json")) + len(fixture_rows("tpex_t187ap04_O.json"))
    assert count(session_factory, Announcement) == n_ann
    assert count(session_factory, FetchLog) == 5
    assert count(session_factory, RawPayload) == 5


def test_raw_payload_is_saved_and_traceable(session_factory, settings, server):
    run_job(session_factory, settings, "tw_foreign_flow", client=server.client(), now=lambda: WED_4PM)
    with session_factory() as s:
        p = s.scalar(select(RawPayload))
        body = gzip.decompress((settings.raw_dir / p.path).read_bytes())
        assert hashlib.sha256(body).hexdigest() == p.sha256
        row = s.scalar(select(ForeignFlowDaily).limit(1))
        assert row.raw_payload_id == p.id
        assert row.source_url == SOURCES["TPEX_3INSTI_DAILY"].endpoint


def test_foreign_flow_values_match_fixture(session_factory, settings, server):
    run = run_job(session_factory, settings, "tw_foreign_flow", client=server.client(), now=lambda: WED_4PM)
    assert run.status == OK
    raw = fixture_rows("tpex_3insti_daily_trading.json")[0]
    with session_factory() as s:
        r = s.get(ForeignFlowDaily, (date(2026, 11, 18), "TPEX", raw["SecuritiesCompanyCode"]))
    key = "Foreign Investors include Mainland Area Investors (Foreign Dealers excluded)-Difference"
    assert r.fi_net == int(raw[key])
    assert r.fi_buy - r.fi_sell == r.fi_net
    assert r.total_net == int(raw["TotalDifference"])


def test_rerun_is_idempotent(session_factory, settings, server):
    for _ in range(2):
        run_job(session_factory, settings, "tw_daily", client=server.client(), now=lambda: WED_4PM)
    n_quotes = len(fixture_rows("twse_stock_day_all.json")) + len(fixture_rows("tpex_mainboard_quotes.json"))
    assert count(session_factory, DailyQuote) == n_quotes
    n_ann = len(fixture_rows("twse_t187ap04_L.json")) + len(fixture_rows("tpex_t187ap04_O.json"))
    assert count(session_factory, Announcement) == n_ann
    assert count(session_factory, JobRun) == 2


def test_weekend_stale_data_is_ok(session_factory, settings, server):
    run = run_job(session_factory, settings, "tw_quotes", client=server.client(), now=lambda: SAT_NOON)
    assert run.status == OK


def test_retry_then_success(session_factory, settings, server):
    url = SOURCES["TPEX_3INSTI_DAILY"].endpoint
    server.overrides[url] = [503, httpx.ConnectError("boom")]
    sleeps: list[float] = []
    settings = Settings(**{**settings.__dict__, "retry_backoff_s": (5.0, 15.0)})
    run = run_job(session_factory, settings, "tw_foreign_flow", client=server.client(),
                  sleep=sleeps.append, now=lambda: WED_4PM)
    assert run.status == OK
    assert sleeps == [5.0, 15.0]
    with session_factory() as s:
        attempts = s.scalars(select(FetchLog).order_by(FetchLog.attempt)).all()
    assert [a.attempt for a in attempts] == [1, 2, 3]
    assert attempts[0].http_status == 503
    assert attempts[1].error.startswith("ConnectError")
    assert attempts[2].http_status == 200


def test_404_is_not_retried_and_job_is_partial(session_factory, settings, server):
    url = SOURCES["TWSE_T187AP04_L"].endpoint
    server.overrides[url] = [404]
    run = run_job(session_factory, settings, "tw_announcements", client=server.client(), now=lambda: WED_4PM)
    assert run.status == PARTIAL
    assert server.calls.count(url) == 1
    assert count(session_factory, Announcement) == len(fixture_rows("tpex_t187ap04_O.json"))


def test_all_failed(session_factory, settings, server):
    url = SOURCES["TPEX_3INSTI_DAILY"].endpoint
    server.overrides[url] = [500, 500, 500]
    run = run_job(session_factory, settings, "tw_foreign_flow", client=server.client(), now=lambda: WED_4PM)
    assert run.status == FAILED
    assert exit_code(run.status) == 1
    assert count(session_factory, FetchLog) == 3


def test_schema_change_fails_step_without_partial_writes(session_factory, settings, server):
    url = SOURCES["TPEX_3INSTI_DAILY"].endpoint
    rows = fixture_rows("tpex_3insti_daily_trading.json")
    del rows[-1]["ForeignDealers-Difference"]  # 最後一列欄位消失
    server.overrides[url] = [json.dumps(rows).encode()]
    run = run_job(session_factory, settings, "tw_foreign_flow", client=server.client(), now=lambda: WED_4PM)
    assert run.status == FAILED
    assert "SCHEMA" in run.message
    assert count(session_factory, ForeignFlowDaily) == 0  # 前面幾列也一起回滾
    assert count(session_factory, RawPayload) == 1  # 原始回應仍保留供檢查


def test_invalid_json_is_failure(session_factory, settings, server):
    url = SOURCES["TPEX_3INSTI_DAILY"].endpoint
    server.overrides[url] = [b"<html>blocked</html>"]
    run = run_job(session_factory, settings, "tw_foreign_flow", client=server.client(), now=lambda: WED_4PM)
    assert run.status == FAILED
    assert "invalid JSON" in run.message


def test_no_trade_quote_has_null_close(session_factory, settings, server):
    run_job(session_factory, settings, "tw_quotes", client=server.client(), now=lambda: WED_4PM)
    with session_factory() as s:
        inst = s.scalar(select(MarketInstrument).where(MarketInstrument.symbol == "00734B"))
        q = s.scalar(select(DailyQuote).where(DailyQuote.instrument_id == inst.id))
    assert q.close is None and q.suspicious is False
    assert inst.asset_type == "ETF"


def test_suspicious_jump_is_flagged(session_factory, settings):
    src = SOURCES["TPEX_MAINBOARD_QUOTES"]
    now = WED_4PM
    with session_factory() as s:
        payload = RawPayload(source_id=src.id, url=src.endpoint, fetched_at=now, http_status=200,
                             sha256="x", size_bytes=0, path="x")
        s.add(payload)
        s.flush()
        base = {"SecuritiesCompanyCode": "6488", "CompanyName": "環球晶", "Change": "0", "Open": "1",
                "High": "1", "Low": "1", "TradingShares": "1000", "TransactionAmount": "100000"}
        ingest_quotes(s, [{**base, "Date": "1151117", "Close": "100"}], src, "TPEX", payload, now)
        res = ingest_quotes(s, [{**base, "Date": "1151118", "Close": "151"}], src, "TPEX", payload, now)
        assert res.suspicious == ["6488:CHANGE_GT_50PCT"]
        res = ingest_quotes(s, [{**base, "Date": "1151118", "Close": "0"}], src, "TPEX", payload, now)
        assert res.suspicious == ["6488:NON_POSITIVE_CLOSE"]
        res = ingest_quotes(s, [{**base, "Date": "1151118", "Close": "105.5"}], src, "TPEX", payload, now)
        assert res.suspicious == []
        q = s.scalar(select(DailyQuote).where(DailyQuote.trade_date == date(2026, 11, 18)))
        assert q.close == Decimal("105.5") and q.suspicious is False


def test_throttle_waits_between_requests_to_same_host(session_factory, settings, server):
    clock = [0.0]
    sleeps: list[float] = []

    def fake_sleep(s):
        sleeps.append(s)
        clock[0] += s

    settings = Settings(**{**settings.__dict__, "request_interval_s": 10.0})
    with session_factory() as s:
        f = Fetcher(s, settings, "t", client=server.client(), sleep=fake_sleep, monotonic=lambda: clock[0])
        f.get_json(SOURCES["TWSE_T187AP04_L"])
        f.get_json(SOURCES["TPEX_T187AP04_O"])  # 不同主機：不等待
        clock[0] += 3
        f.get_json(SOURCES["TWSE_STOCK_DAY_ALL"])  # 同主機，已過 3 秒 → 再等 7 秒
    assert sleeps == [7.0]


def test_announcement_time_parsed_in_taipei(session_factory, settings, server):
    run_job(session_factory, settings, "tw_announcements", client=server.client(), now=lambda: WED_4PM)
    raw = fixture_rows("twse_t187ap04_L.json")[0]
    with session_factory() as s:
        a = s.scalar(select(Announcement).where(Announcement.symbol == raw["公司代號"]))
    from dca_backend.parsing import TAIPEI
    assert a.published_at.astimezone(TAIPEI).strftime("%H%M%S") == raw["發言時間"].zfill(6)
    assert a.published_at.utcoffset().total_seconds() == 0
    assert a.subject == raw["主旨 "].strip()
    assert a.license_basis == "GOV_OPEN_DATA"
