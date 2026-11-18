from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path

import httpx
import pytest

from dca_backend.config import Settings
from dca_backend.db import create_all, make_engine, make_session_factory
from dca_backend.sources import SOURCES

FIXTURES = Path(__file__).parent / "fixtures"

# 端點 → 實測回應（2026-11-18 擷取並截短）
FIXTURE_FOR = {
    SOURCES["TWSE_STOCK_DAY_ALL"].endpoint: "twse_stock_day_all.json",
    SOURCES["TPEX_MAINBOARD_QUOTES"].endpoint: "tpex_mainboard_quotes.json",
    SOURCES["TPEX_3INSTI_DAILY"].endpoint: "tpex_3insti_daily_trading.json",
    SOURCES["TWSE_T187AP04_L"].endpoint: "twse_t187ap04_L.json",
    SOURCES["TPEX_T187AP04_O"].endpoint: "tpex_t187ap04_O.json",
}

# 2026-11-18（週三）16:00 台灣時間
WED_4PM = datetime(2026, 11, 18, 8, 0, tzinfo=timezone.utc)


def fixture_rows(name: str) -> list[dict]:
    return json.loads((FIXTURES / name).read_text(encoding="utf-8"))


class FakeServer:
    """依 URL 回傳 fixture；可針對特定 URL 注入一串回應（狀態碼或例外）。"""

    def __init__(self) -> None:
        self.overrides: dict[str, list] = {}
        self.data: dict[str, bytes] = {u: (FIXTURES / f).read_bytes() for u, f in FIXTURE_FOR.items()}
        self.calls: list[str] = []

    def handler(self, request: httpx.Request) -> httpx.Response:
        url = str(request.url)
        self.calls.append(url)
        queue = self.overrides.get(url)
        if queue:
            item = queue.pop(0)
            if isinstance(item, Exception):
                raise item
            if isinstance(item, int):
                return httpx.Response(item, content=b"error")
            return httpx.Response(200, content=item)
        if url in self.data:
            return httpx.Response(200, content=self.data[url])
        return httpx.Response(404)

    def client(self) -> httpx.Client:
        return httpx.Client(transport=httpx.MockTransport(self.handler))


@pytest.fixture
def server() -> FakeServer:
    return FakeServer()


@pytest.fixture
def settings(tmp_path) -> Settings:
    return Settings(db_url=f"sqlite:///{tmp_path}/test.db", raw_dir=tmp_path / "raw",
                    request_interval_s=0, retry_backoff_s=(0, 0))


@pytest.fixture
def session_factory(settings):
    engine = make_engine(settings.db_url)
    create_all(engine)
    yield make_session_factory(engine)
    engine.dispose()
