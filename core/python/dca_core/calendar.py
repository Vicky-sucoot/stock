"""交易日曆與市場時區。"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import date, datetime, timedelta
from zoneinfo import ZoneInfo

MARKET_TIMEZONES = {
    "TW": "Asia/Taipei",
    "FUND_TW": "Asia/Taipei",
    "US": "America/New_York",
    "JP": "Asia/Tokyo",
}

# 調整日期時最多往前或往後找幾天；超過代表日曆資料異常。
MAX_ADJUST_DAYS = 30


@dataclass(frozen=True)
class TradingCalendar:
    """週末一律休市；`holidays` 為額外休市日。

    `known_through` 之後的日期視為「日曆未更新」：只排除週末，並由呼叫端標示。
    """

    holidays: frozenset[date] = field(default_factory=frozenset)
    known_through: date | None = None

    def is_open(self, d: date) -> bool:
        if d.isoweekday() >= 6:
            return False
        return d not in self.holidays

    def is_known(self, d: date) -> bool:
        return self.known_through is None or d <= self.known_through

    def next_open(self, d: date) -> date:
        return self._walk(d, 1)

    def prev_open(self, d: date) -> date:
        return self._walk(d, -1)

    def _walk(self, d: date, step: int) -> date:
        cur = d
        for _ in range(MAX_ADJUST_DAYS + 1):
            if self.is_open(cur):
                return cur
            cur = cur + timedelta(days=step)
        raise ValueError(f"no trading day within {MAX_ADJUST_DAYS} days of {d}")


def market_today(market: str, now_utc: datetime) -> date:
    """以市場時區判斷「今天」的日期（docs/02 §3.3 時區規則）。"""
    if now_utc.tzinfo is None:
        raise ValueError("now_utc must be timezone-aware")
    tz = ZoneInfo(MARKET_TIMEZONES[market])
    return now_utc.astimezone(tz).date()
