"""從原始回應檔重建資料庫（不連網）。

原始資料目錄（raw_dir）是唯一的事實來源；資料庫可以隨時丟掉重建。
這讓「先用 GitHub Actions 免費累積原始檔，之後再搬到正式主機」成為可能。

用法：
    DCA_DB_URL=sqlite:///./data/dca.db python -m dca_backend.replay --raw-dir ./data/raw --init-db
"""

from __future__ import annotations

import argparse
import gzip
import hashlib
import json
import re
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

from sqlalchemy import select
from sqlalchemy.orm import Session, sessionmaker

from .config import Settings
from .db import create_all, make_engine, make_session_factory
from .ingest import SchemaError
from .jobs import JOBS, _ingest
from .models import RawPayload
from .sources import SOURCES

_NAME = re.compile(r"^(?P<hms>\d{6})_(?P<sha>[0-9a-f]{12})\.json\.gz$")


@dataclass
class ReplayResult:
    files: int = 0
    skipped_existing: int = 0
    failed: list[str] | None = None
    rows: int = 0


def _steps_by_source():
    return {s.source_id: s for s in JOBS["tw_daily"]}


def _fetched_at(path: Path) -> datetime:
    m = _NAME.match(path.name)
    if not m:
        raise ValueError(f"unexpected raw file name: {path.name}")
    return datetime.strptime(path.parent.name + m["hms"], "%Y%m%d%H%M%S").replace(tzinfo=timezone.utc)


def replay(session_factory: sessionmaker[Session], raw_dir: Path) -> ReplayResult:
    steps = _steps_by_source()
    files = []
    for source_id in steps:
        base = raw_dir / source_id
        if base.is_dir():
            files += [(p, source_id) for p in base.glob("*/*.json.gz")]
    # 依取得時間排序，讓「與前一日比較」的檢查和當初一致
    files.sort(key=lambda it: (_fetched_at(it[0]), it[1]))
    res = ReplayResult(failed=[])
    with session_factory() as session:
        for path, source_id in files:
            rel = path.relative_to(raw_dir).as_posix()
            body = gzip.decompress(path.read_bytes())
            sha = hashlib.sha256(body).hexdigest()
            if session.scalar(select(RawPayload.id).where(RawPayload.path == rel, RawPayload.sha256 == sha)):
                res.skipped_existing += 1
                continue
            fetched_at = _fetched_at(path)
            src = SOURCES[source_id]
            payload = RawPayload(source_id=source_id, url=src.endpoint, fetched_at=fetched_at,
                                 http_status=200, sha256=sha, size_bytes=len(body), path=rel)
            session.add(payload)
            session.flush()
            try:
                with session.begin_nested():
                    r = _ingest(session, steps[source_id], json.loads(body.decode("utf-8-sig")), payload, fetched_at)
                res.rows += r.rows
            except (SchemaError, ValueError) as e:
                res.failed.append(f"{rel}: {e}")
            res.files += 1
        session.commit()
    return res


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(prog="dca_backend.replay")
    p.add_argument("--raw-dir", type=Path, default=None)
    p.add_argument("--init-db", action="store_true")
    args = p.parse_args(argv)
    settings = Settings.from_env()
    engine = make_engine(settings.db_url)
    if args.init_db:
        create_all(engine)
    r = replay(make_session_factory(engine), args.raw_dir or settings.raw_dir)
    print(f"replayed files={r.files} skipped={r.skipped_existing} rows={r.rows} failed={len(r.failed)}")
    for f in r.failed:
        print("FAILED", f)
    return 1 if r.failed else 0


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
