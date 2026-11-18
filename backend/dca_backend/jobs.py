"""每日擷取工作（docs/09 §6）。由外部排程（cron／雲端 Cron）在不同時間重複呼叫；
每次執行都是冪等的 upsert，所以重跑沒有副作用。

結束碼：0 = 全部 OK；2 = 有來源尚未更新或部分失敗（排程稍後再試）；1 = 全部失敗。

用法：
    python -m dca_backend.jobs tw_daily
    python -m dca_backend.jobs tw_foreign_flow --init-db
"""

from __future__ import annotations

import argparse
import json
import logging
import sys
from dataclasses import dataclass
from datetime import date, datetime, timezone
from pathlib import Path
from typing import Callable

import httpx
from sqlalchemy.orm import Session, sessionmaker

from .config import Settings
from .db import create_all, make_engine, make_session_factory
from .fetch import FetchError, Fetcher
from .ingest import IngestResult, SchemaError, ingest_announcements, ingest_quotes, ingest_tpex_foreign_flow
from .models import JobRun
from .parsing import TAIPEI
from .sources import SOURCES

log = logging.getLogger("dca_backend.jobs")

OK, PARTIAL, NOT_UPDATED, FAILED = "OK", "PARTIAL", "NOT_UPDATED", "FAILED"


@dataclass(frozen=True)
class Step:
    source_id: str
    board: str
    kind: str  # quotes / foreign_flow / announcements
    # 需要「資料日 = 今天」才算完成的工作（收盤行情、外資資料）
    freshness: bool


JOBS: dict[str, list[Step]] = {
    "tw_quotes": [
        Step("TWSE_STOCK_DAY_ALL", "TWSE", "quotes", True),
        Step("TPEX_MAINBOARD_QUOTES", "TPEX", "quotes", True),
    ],
    "tw_foreign_flow": [
        # 上市（TWSE）個股外資資料的官方取得管道待查（docs/07 V1），MVP 只做上櫃
        Step("TPEX_3INSTI_DAILY", "TPEX", "foreign_flow", True),
    ],
    "tw_announcements": [
        Step("TWSE_T187AP04_L", "TWSE", "announcements", False),
        Step("TPEX_T187AP04_O", "TPEX", "announcements", False),
    ],
}
JOBS["tw_daily"] = JOBS["tw_quotes"] + JOBS["tw_foreign_flow"] + JOBS["tw_announcements"]


def _ingest(session: Session, step: Step, rows, payload, now) -> IngestResult:
    src = SOURCES[step.source_id]
    if step.kind == "quotes":
        return ingest_quotes(session, rows, src, step.board, payload, now)
    if step.kind == "foreign_flow":
        return ingest_tpex_foreign_flow(session, rows, src, payload, now)
    return ingest_announcements(session, rows, src, step.board, payload, now)


def run_job(
    session_factory: sessionmaker[Session],
    settings: Settings,
    job: str,
    client: httpx.Client | None = None,
    sleep: Callable[[float], None] | None = None,
    now: Callable[[], datetime] = lambda: datetime.now(timezone.utc),
) -> JobRun:
    steps = JOBS[job]
    started = now()
    today = started.astimezone(TAIPEI).date()
    is_weekday = today.isoweekday() <= 5
    with session_factory() as session:
        run = JobRun(job=job, started_at=started, status="RUNNING", rows_upserted=0)
        session.add(run)
        session.flush()
        kwargs = {"client": client, "now": now}
        if sleep is not None:
            kwargs["sleep"] = sleep
        fetcher = Fetcher(session, settings, job, **kwargs)

        outcomes: list[str] = []
        notes: list[str] = []
        data_dates: list[date] = []
        for step in steps:
            src = SOURCES[step.source_id]
            try:
                fr = fetcher.get_json(src)
            except FetchError as e:
                outcomes.append(FAILED)
                notes.append(str(e))
                log.warning("fetch failed: %s", e)
                continue
            try:
                with session.begin_nested():
                    res = _ingest(session, step, fr.rows, fr.payload, now())
            except SchemaError as e:
                outcomes.append(FAILED)
                notes.append(f"SCHEMA: {e}")
                log.error("schema changed: %s", e)
                continue
            run.rows_upserted += res.rows
            if res.data_date:
                data_dates.append(res.data_date)
            if res.suspicious:
                notes.append(f"{src.id} suspicious: {', '.join(res.suspicious[:20])}")
            if step.freshness and is_weekday and (res.data_date is None or res.data_date < today):
                outcomes.append(NOT_UPDATED)
                notes.append(f"{src.id} data_date={res.data_date} < today={today}")
            else:
                outcomes.append(OK)

        if all(o == OK for o in outcomes):
            run.status = OK
        elif all(o == FAILED for o in outcomes):
            run.status = FAILED
        elif FAILED in outcomes:
            run.status = PARTIAL
        else:
            run.status = NOT_UPDATED
        run.data_date = max(data_dates) if data_dates else None
        run.finished_at = now()
        run.message = "\n".join(notes) or None
        session.commit()
        return run


def exit_code(status: str) -> int:
    return {OK: 0, FAILED: 1}.get(status, 2)


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(prog="dca_backend.jobs")
    p.add_argument("job", choices=sorted(JOBS))
    p.add_argument("--init-db", action="store_true", help="原型用：直接建立資料表（正式環境請用 alembic upgrade head）")
    p.add_argument("--run-log", type=Path, default=None, help="把本次結果以一行 JSON 附加到此檔（GitHub Actions 累積用）")
    args = p.parse_args(argv)
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    settings = Settings.from_env()
    engine = make_engine(settings.db_url)
    if args.init_db:
        create_all(engine)
    run = run_job(make_session_factory(engine), settings, args.job)
    print(f"{run.job}: {run.status} data_date={run.data_date} rows={run.rows_upserted}")
    if run.message:
        print(run.message)
    if args.run_log is not None:
        append_run_log(args.run_log, run)
    return exit_code(run.status)


def append_run_log(path: Path, run: JobRun) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    line = {
        "job": run.job, "status": run.status,
        "started_at": run.started_at.isoformat(), "finished_at": run.finished_at.isoformat() if run.finished_at else None,
        "data_date": run.data_date.isoformat() if run.data_date else None,
        "rows": run.rows_upserted, "message": run.message,
    }
    with path.open("a", encoding="utf-8") as f:
        f.write(json.dumps(line, ensure_ascii=False) + "\n")


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
