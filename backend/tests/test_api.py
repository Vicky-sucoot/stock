from __future__ import annotations

from decimal import Decimal

import pytest
from fastapi.testclient import TestClient

from dca_backend.api import create_app
from dca_backend.jobs import run_job

from .conftest import WED_4PM, fixture_rows


@pytest.fixture
def client(session_factory, settings, server):
    run_job(session_factory, settings, "tw_daily", client=server.client(), now=lambda: WED_4PM)
    return TestClient(create_app(session_factory))


def test_healthz(client):
    assert client.get("/healthz").json() == {"status": "ok"}


def test_quotes(client):
    raw = next(r for r in fixture_rows("tpex_mainboard_quotes.json") if r["SecuritiesCompanyCode"] == "6488")
    twse = next(r for r in fixture_rows("twse_stock_day_all.json") if r["Code"] == "2330")
    r = client.get("/v1/quotes", params={"symbols": "TW:6488, tw:2330,TW:00734B,TW:9999"})
    assert r.status_code == 200
    body = r.json()
    by = {q["symbol"]: q for q in body["quotes"]}
    assert Decimal(by["TW:6488"]["close"]) == Decimal(raw["Close"])
    assert by["TW:6488"]["data_date"] == "2026-11-18"
    assert by["TW:6488"]["board"] == "TPEX"
    assert "證券櫃檯買賣中心" in by["TW:6488"]["attribution"]
    assert Decimal(by["TW:2330"]["close"]) == Decimal(twse["ClosingPrice"])
    assert by["TW:2330"]["data_date"] == "2026-11-17"
    # 00734B 當日未成交（收盤 "----"）且沒有更早的報價；9999 不存在
    assert body["missing"] == ["TW:00734B", "TW:9999"]


@pytest.mark.parametrize("q", ["", "AAPL", "US:AAPL", "TW:12", ",".join(f"TW:{1000+i}" for i in range(201))])
def test_quotes_rejects_bad_input(client, q):
    assert client.get("/v1/quotes", params={"symbols": q}).status_code in (400, 422)


def test_sources_have_attribution_and_license(client):
    srcs = client.get("/v1/sources").json()["sources"]
    assert len(srcs) == 5
    for s in srcs:
        assert s["attribution"] and s["license_url"] == "https://data.gov.tw/license"
        assert s["verified_on"] == "2026-11-18"


def test_instruments_search(client):
    res = client.get("/v1/instruments", params={"query": "005"}).json()["instruments"]
    assert any(i["symbol"] == "TW:0050" for i in res)
    res = client.get("/v1/instruments", params={"query": "環球"}).json()["instruments"]
    assert [i["symbol"] for i in res] == ["TW:6488"]


def test_foreign_flow_endpoint(client):
    raw = fixture_rows("tpex_3insti_daily_trading.json")[0]
    sym = "TW:" + raw["SecuritiesCompanyCode"]
    body = client.get(f"/v1/foreign-flow/{sym}").json()
    assert body["unit"] == "shares"
    assert len(body["rows"]) == 1
    assert body["rows"][0]["trade_date"] == "2026-11-18"
    assert client.get("/v1/foreign-flow/XX").status_code == 400


def test_status(client):
    jobs = client.get("/v1/status").json()["jobs"]
    assert jobs["tw_daily"]["status"] == "NOT_UPDATED"
    assert jobs["tw_daily"]["data_date"] == "2026-11-18"
