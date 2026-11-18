"""定期定額期別產生（docs/02 §3）。

規則：
1. 名義扣款日：每週（ISO 星期）、每月（指定日，當月不存在則取月底）、指定日期。
2. 名義日遇休市：依 holiday_rule 順延（NEXT）或提前（PREV）到交易日。
3. 只產生 scheduled_date <= today 且 period_key 尚未存在的期別。
4. 調整後落在同一天的多個期別，彼此列在 merged_keys（UI 合併為一筆「含 n 期」）。
"""

from __future__ import annotations

import calendar as _cal
from dataclasses import dataclass, field
from datetime import date, timedelta

from .calendar import TradingCalendar

WEEKLY = "WEEKLY"
MONTHLY = "MONTHLY"
DATES = "DATES"

NEXT_TRADING_DAY = "NEXT_TRADING_DAY"
PREV_TRADING_DAY = "PREV_TRADING_DAY"

# PREV 規則可能讓下個月初的名義日提前到今天以前，所以往後多看一段。
LOOKAHEAD_DAYS = 31


@dataclass(frozen=True)
class Plan:
    frequency: str
    start_date: date
    end_date: date | None = None
    weekdays: tuple[int, ...] = ()  # ISO：週一 = 1
    month_days: tuple[int, ...] = ()  # 1..31
    specific_dates: tuple[date, ...] = ()
    holiday_rule: str = NEXT_TRADING_DAY
    paused: bool = False

    def __post_init__(self) -> None:
        if self.frequency == WEEKLY and not self.weekdays:
            raise ValueError("weekly plan needs weekdays")
        if self.frequency == MONTHLY and not self.month_days:
            raise ValueError("monthly plan needs month_days")
        if self.frequency == DATES and not self.specific_dates:
            raise ValueError("dates plan needs specific_dates")
        if any(not 1 <= w <= 7 for w in self.weekdays):
            raise ValueError("weekday must be 1..7")
        if any(not 1 <= m <= 31 for m in self.month_days):
            raise ValueError("month day must be 1..31")
        if self.holiday_rule not in (NEXT_TRADING_DAY, PREV_TRADING_DAY):
            raise ValueError("unknown holiday_rule")


@dataclass(frozen=True)
class Occurrence:
    period_key: str
    nominal_date: date
    scheduled_date: date
    adjust_reasons: tuple[str, ...] = ()
    merged_keys: tuple[str, ...] = field(default=())
    calendar_unknown: bool = False


def _iter_months(start: date, end: date):
    y, m = start.year, start.month
    while (y, m) <= (end.year, end.month):
        yield y, m
        m += 1
        if m == 13:
            y, m = y + 1, 1


def _nominal(plan: Plan, lo: date, hi: date) -> list[tuple[str, date, tuple[str, ...]]]:
    """回傳 (period_key, nominal_date, reasons)，nominal 落在 [lo, hi]。"""
    out: list[tuple[str, date, tuple[str, ...]]] = []
    if lo > hi:
        return out
    if plan.frequency == WEEKLY:
        d = lo
        wanted = set(plan.weekdays)
        while d <= hi:
            wd = d.isoweekday()
            if wd in wanted:
                iy, iw, _ = d.isocalendar()
                out.append((f"{iy}-W{iw:02d}#{wd}", d, ()))
            d += timedelta(days=1)
    elif plan.frequency == MONTHLY:
        for y, m in _iter_months(lo, hi):
            dim = _cal.monthrange(y, m)[1]
            for md in sorted(set(plan.month_days)):
                day = min(md, dim)
                nd = date(y, m, day)
                if lo <= nd <= hi:
                    reasons = ("MONTH_END",) if md > dim else ()
                    out.append((f"{y}-{m:02d}#{md}", nd, reasons))
    elif plan.frequency == DATES:
        for sd in sorted(set(plan.specific_dates)):
            if lo <= sd <= hi:
                out.append((f"D{sd.isoformat()}", sd, ()))
    else:
        raise ValueError(f"unknown frequency {plan.frequency}")
    return out


def _schedule(plan: Plan, cal: TradingCalendar, lo: date, hi: date) -> list[Occurrence]:
    occs: list[Occurrence] = []
    for key, nd, reasons in _nominal(plan, lo, hi):
        if cal.is_open(nd):
            sd = nd
        elif plan.holiday_rule == NEXT_TRADING_DAY:
            sd = cal.next_open(nd)
            reasons = reasons + ("HOLIDAY_FORWARD",)
        else:
            sd = cal.prev_open(nd)
            reasons = reasons + ("HOLIDAY_BACKWARD",)
        occs.append(
            Occurrence(
                period_key=key,
                nominal_date=nd,
                scheduled_date=sd,
                adjust_reasons=reasons,
                calendar_unknown=not cal.is_known(sd),
            )
        )
    # 標示同一天的合併期別
    by_day: dict[date, list[str]] = {}
    for o in occs:
        by_day.setdefault(o.scheduled_date, []).append(o.period_key)
    result = []
    for o in occs:
        keys = by_day[o.scheduled_date]
        if len(keys) > 1:
            others = tuple(k for k in keys if k != o.period_key)
            o = Occurrence(
                period_key=o.period_key,
                nominal_date=o.nominal_date,
                scheduled_date=o.scheduled_date,
                adjust_reasons=o.adjust_reasons + ("MERGED",),
                merged_keys=others,
                calendar_unknown=o.calendar_unknown,
            )
        result.append(o)
    result.sort(key=lambda o: (o.scheduled_date, o.nominal_date, o.period_key))
    return result


def due_occurrences(
    plan: Plan,
    cal: TradingCalendar,
    today: date,
    existing_keys: frozenset[str] | set[str] = frozenset(),
    since: date | None = None,
) -> list[Occurrence]:
    """應產生為「待確認」的期別：scheduled_date <= today，且尚未存在。

    `since`：只考慮 nominal_date >= since（例如計畫恢復日或使用者選擇的補產生起點）。
    """
    if plan.paused:
        return []
    lo = max(plan.start_date, since) if since else plan.start_date
    hi = today + timedelta(days=LOOKAHEAD_DAYS)
    if plan.end_date is not None:
        hi = min(hi, plan.end_date)
    return [
        o
        for o in _schedule(plan, cal, lo, hi)
        if o.scheduled_date <= today and o.period_key not in existing_keys
    ]


def upcoming_occurrences(plan: Plan, cal: TradingCalendar, today: date, count: int) -> list[Occurrence]:
    """編輯畫面的「接下來 n 期」預覽：scheduled_date > today。"""
    if plan.paused or count <= 0:
        return []
    lo = max(plan.start_date, today - timedelta(days=LOOKAHEAD_DAYS))
    span = 400
    hi_limit = plan.end_date
    out: list[Occurrence] = []
    while True:
        hi = today + timedelta(days=span)
        if hi_limit is not None:
            hi = min(hi, hi_limit)
        out = [o for o in _schedule(plan, cal, lo, hi) if o.scheduled_date > today]
        if len(out) >= count or (hi_limit is not None and hi >= hi_limit) or span > 3700:
            return out[:count]
        span *= 2
