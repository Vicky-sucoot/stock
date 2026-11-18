from datetime import datetime, timezone

from dca_backend.export_quotes import build
from dca_backend.jobs import run_job

from .conftest import WED_4PM


def test_build_quotes_from_raw(session_factory, settings, server):
    run_job(session_factory, settings, "tw_quotes", client=server.client(), now=lambda: WED_4PM)
    out = build(settings.raw_dir, now=datetime(2026, 11, 18, tzinfo=timezone.utc))
    q = out["quotes"]
    assert q["2330"] == ["台積電", "TWSE", "2170.00", "2026-11-17"]
    assert q["6488"][1:] == ["TPEX", "544.00", "2026-11-18"]
    assert q["00734B"][2] is None  # 當日無成交
    assert {s["id"] for s in out["sources"]} == {"TWSE_STOCK_DAY_ALL", "TPEX_MAINBOARD_QUOTES"}
    assert all("政府資料開放授權條款" in s["attribution"] for s in out["sources"])
    assert "watchlist" not in out and "不構成投資建議" in out["disclaimer"]


def test_build_with_no_files(tmp_path):
    assert build(tmp_path)["quotes"] == {}
