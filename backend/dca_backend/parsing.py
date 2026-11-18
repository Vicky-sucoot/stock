"""官方 OpenAPI 欄位解析（民國日期、空值符號、帶空白的欄位名稱）。"""

from __future__ import annotations

import re
from datetime import date, datetime, time
from decimal import Decimal, InvalidOperation
from zoneinfo import ZoneInfo

TAIPEI = ZoneInfo("Asia/Taipei")

# 官方資料中代表「無資料」的符號（實測：TPEx 未成交時為 "----"，TWSE 為空字串）
_EMPTY = {"", "-", "--", "---", "----", "N/A", "X"}


def roc_date(s: str | None) -> date | None:
    """民國年 YYYMMDD（例如 1151118）→ 西元日期。"""
    if s is None:
        return None
    s = s.strip()
    if not re.fullmatch(r"\d{6,7}", s):
        return None
    y, m, d = int(s[:-4]) + 1911, int(s[-4:-2]), int(s[-2:])
    try:
        return date(y, m, d)
    except ValueError:
        return None


def roc_time(s: str | None) -> time | None:
    """發言時間 HHMMSS，可能少一位前導 0（實測 "70004" = 07:00:04）。"""
    if s is None:
        return None
    s = s.strip()
    if not s.isdigit() or len(s) > 6:
        return None
    s = s.zfill(6)
    try:
        return time(int(s[:2]), int(s[2:4]), int(s[4:]))
    except ValueError:
        return None


def taipei_datetime(d: date | None, t: time | None) -> datetime | None:
    if d is None:
        return None
    return datetime.combine(d, t or time(0, 0), tzinfo=TAIPEI)


def dec(s: str | None) -> Decimal | None:
    if s is None:
        return None
    s = s.strip().replace(",", "")
    if s in _EMPTY:
        return None
    try:
        v = Decimal(s)
    except InvalidOperation:
        return None
    return v if v.is_finite() else None


def integer(s: str | None) -> int | None:
    v = dec(s)
    if v is None or v != v.to_integral_value():
        return None
    return int(v)


def norm_keys(row: dict) -> dict:
    """欄位名稱去除所有空白（實測 TPEx 有 " Foreign Investors..." 與 "主旨 " 等）。"""
    return {re.sub(r"\s+", "", k): v for k, v in row.items()}
