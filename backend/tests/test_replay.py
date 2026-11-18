from __future__ import annotations

import json
from datetime import datetime, timezone

from sqlalchemy import func, select

from dca_backend.db import create_all, make_engine, make_session_factory
from dca_backend.jobs import append_run_log, run_job
from dca_backend.models import Announcement, DailyQuote, ForeignFlowDaily, RawPayload
from dca_backend.replay import replay

from .conftest import WED_4PM

LATER = datetime(2026, 11, 18, 10, 0, tzinfo=timezone.utc)


def _counts(sf):
    with sf() as s:
        return {m.__tablename__: s.scalar(select(func.count()).select_from(m))
                for m in (DailyQuote, ForeignFlowDaily, Announcement)}


def _raw_files(settings):
    return sorted(p.relative_to(settings.raw_dir).as_posix() for p in settings.raw_dir.rglob("*.json.gz"))


def test_identical_payloads_are_stored_once(session_factory, settings, server):
    run_job(session_factory, settings, "tw_daily", client=server.client(), now=lambda: WED_4PM)
    first = _raw_files(settings)
    run_job(session_factory, settings, "tw_daily", client=server.client(), now=lambda: LATER)
    assert _raw_files(settings) == first  # 內容相同，不新增檔案
    assert len(first) == 5
    with session_factory() as s:
        assert s.scalar(select(func.count()).select_from(RawPayload)) == 10  # 每次擷取仍有紀錄
        assert s.scalar(select(func.count(func.distinct(RawPayload.path)))) == 5


def test_replay_rebuilds_same_data(session_factory, settings, server, tmp_path):
    run_job(session_factory, settings, "tw_daily", client=server.client(), now=lambda: WED_4PM)
    original = _counts(session_factory)

    engine = make_engine(f"sqlite:///{tmp_path}/rebuilt.db")
    create_all(engine)
    sf2 = make_session_factory(engine)
    r = replay(sf2, settings.raw_dir)
    assert r.files == 5 and r.failed == []
    assert _counts(sf2) == original
    # 再重播一次不會重複
    r2 = replay(sf2, settings.raw_dir)
    assert r2.files == 0 and r2.skipped_existing == 5
    assert _counts(sf2) == original
    engine.dispose()


def test_replay_reports_schema_failures(session_factory, settings, server, tmp_path):
    url = next(u for u in server.data if "3insti" in u)
    rows = json.loads(server.data[url])
    del rows[0]["TotalDifference"]
    del rows[0]["ForeignDealers-Difference"]
    server.data[url] = json.dumps(rows).encode()
    run_job(session_factory, settings, "tw_foreign_flow", client=server.client(), now=lambda: WED_4PM)

    engine = make_engine(f"sqlite:///{tmp_path}/rebuilt.db")
    create_all(engine)
    r = replay(make_session_factory(engine), settings.raw_dir)
    assert len(r.failed) == 1 and "missing field" in r.failed[0]
    engine.dispose()


def test_run_log_appends_json_lines(session_factory, settings, server, tmp_path):
    log = tmp_path / "runs" / "2026-11.jsonl"
    for t in (WED_4PM, LATER):
        run = run_job(session_factory, settings, "tw_foreign_flow", client=server.client(), now=lambda t=t: t)
        append_run_log(log, run)
    lines = [json.loads(x) for x in log.read_text(encoding="utf-8").splitlines()]
    assert [x["status"] for x in lines] == ["OK", "OK"]
    assert lines[0]["data_date"] == "2026-11-18"
