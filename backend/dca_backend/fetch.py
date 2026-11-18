"""禮貌的 HTTP 擷取器：同主機限速、有限次數重試、每次嘗試寫入 fetch_log、保存原始回應。"""

from __future__ import annotations

import gzip
import hashlib
import json
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Callable
from urllib.parse import urlparse

import httpx
from sqlalchemy.orm import Session

from .config import Settings
from .models import FetchLog, RawPayload
from .sources import Source


class FetchError(RuntimeError):
    pass


@dataclass
class FetchResult:
    rows: list[dict]
    payload: RawPayload


def find_raw_file(raw_dir, source_id: str, sha: str) -> str | None:
    """在 raw_dir/<source_id>/*/ 中找同一 SHA-256 的檔案（檔名含前 12 碼，再以內容確認）。"""
    base = raw_dir / source_id
    if not base.is_dir():
        return None
    for p in sorted(base.glob(f"*/*_{sha[:12]}.json.gz")):
        if hashlib.sha256(gzip.decompress(p.read_bytes())).hexdigest() == sha:
            return p.relative_to(raw_dir).as_posix()
    return None


def _retryable(status: int) -> bool:
    return status == 429 or status >= 500


class Fetcher:
    def __init__(
        self,
        session: Session,
        settings: Settings,
        job: str,
        client: httpx.Client | None = None,
        sleep: Callable[[float], None] = time.sleep,
        monotonic: Callable[[], float] = time.monotonic,
        now: Callable[[], datetime] = lambda: datetime.now(timezone.utc),
    ) -> None:
        self.session = session
        self.settings = settings
        self.job = job
        self.client = client or httpx.Client(
            timeout=settings.http_timeout_s,
            headers={"User-Agent": settings.user_agent, "Accept": "application/json"},
            follow_redirects=False,
        )
        self._sleep = sleep
        self._monotonic = monotonic
        self._now = now
        self._last_request: dict[str, float] = {}

    def _throttle(self, url: str) -> None:
        host = urlparse(url).netloc
        last = self._last_request.get(host)
        if last is not None:
            wait = self.settings.request_interval_s - (self._monotonic() - last)
            if wait > 0:
                self._sleep(wait)
        self._last_request[host] = self._monotonic()

    def get_json(self, source: Source) -> FetchResult:
        url = source.endpoint
        attempts = 1 + len(self.settings.retry_backoff_s)
        last_error = ""
        for attempt in range(1, attempts + 1):
            self._throttle(url)
            started = self._now()
            t0 = self._monotonic()
            status: int | None = None
            body: bytes | None = None
            error: str | None = None
            try:
                resp = self.client.get(url)
                status = resp.status_code
                body = resp.content
                if status != 200:
                    error = f"HTTP {status}"
            except httpx.HTTPError as e:
                error = f"{type(e).__name__}: {e}"
            self.session.add(
                FetchLog(
                    job=self.job,
                    source_id=source.id,
                    url=url,
                    attempt=attempt,
                    started_at=started,
                    duration_ms=int((self._monotonic() - t0) * 1000),
                    http_status=status,
                    size_bytes=len(body) if body is not None else None,
                    error=error,
                )
            )
            self.session.flush()
            if error is None and body is not None:
                return self._accept(source, url, status or 200, body, started)
            last_error = error or "unknown"
            if status is not None and not _retryable(status):
                break
            if attempt < attempts:
                self._sleep(self.settings.retry_backoff_s[attempt - 1])
        raise FetchError(f"{source.id}: {last_error}")

    def _accept(self, source: Source, url: str, status: int, body: bytes, fetched_at: datetime) -> FetchResult:
        try:
            rows = json.loads(body.decode("utf-8-sig"))
        except (UnicodeDecodeError, json.JSONDecodeError) as e:
            raise FetchError(f"{source.id}: invalid JSON ({e})") from e
        if not isinstance(rows, list) or not all(isinstance(r, dict) for r in rows):
            raise FetchError(f"{source.id}: expected a JSON array of objects")
        sha = hashlib.sha256(body).hexdigest()
        # 同一份內容已經存過（例如一天內重跑多次）就沿用，不重複寫檔：原始資料目錄只會新增
        existing = find_raw_file(self.settings.raw_dir, source.id, sha)
        if existing is not None:
            rel = existing
        else:
            rel = f"{source.id}/{fetched_at:%Y%m%d}/{fetched_at:%H%M%S}_{sha[:12]}.json.gz"
            path = self.settings.raw_dir / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            # mtime=0：同樣內容產生同樣的 gzip 位元組，方便 git 去重複
            path.write_bytes(gzip.compress(body, mtime=0))
        payload = RawPayload(
            source_id=source.id,
            url=url,
            fetched_at=fetched_at,
            http_status=status,
            sha256=sha,
            size_bytes=len(body),
            path=rel,
        )
        self.session.add(payload)
        self.session.flush()
        return FetchResult(rows=rows, payload=payload)
