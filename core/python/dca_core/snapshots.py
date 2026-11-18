"""全期間月資料點（docs/05 §5）。

- 資料點：第一筆交易的月份 ~ as_of 月份；每月取最後一個日曆日，當月取 as_of。
- 價格：手動值（生效日 <= 該點日期）→ 該點日期以前最近一筆歷史價 → 最後成交價 → 成本。
- 匯率：手動值 → 最近一筆歷史匯率；缺匯率時該幣別不計入，並標示。
- 推估：使用的價格或匯率日期早於該月第一天，或改用最後成交價或成本時，標示 estimated。
"""

from __future__ import annotations

import calendar as _cal
from bisect import bisect_right
from dataclasses import dataclass, field
from datetime import date
from decimal import Decimal

from .ledger import Transaction, build_position
from .valuation import Override, _active_override, convert

ZERO = Decimal(0)


@dataclass(frozen=True)
class Series:
    """依日期排序的 (date, value)。"""

    points: tuple[tuple[date, Decimal], ...] = ()
    overrides: tuple[Override, ...] = ()

    def at(self, d: date) -> tuple[Decimal | None, date | None, bool]:
        """回傳 (value, value_date, is_manual)。"""
        o = _active_override(self.overrides, d)
        if o is not None:
            return o.value, d, True
        dates = [p[0] for p in self.points]
        i = bisect_right(dates, d)
        if i == 0:
            return None, None, False
        return self.points[i - 1][1], self.points[i - 1][0], False


@dataclass(frozen=True)
class SnapshotHolding:
    instrument_id: str
    currency: str
    transactions: tuple[Transaction, ...]
    include_in_overview: bool = True


@dataclass
class MonthPoint:
    month: str
    date: date
    market_value: Decimal
    invested_current: Decimal
    historical_invested: Decimal
    pnl_ex_div: Decimal
    pnl_inc_div: Decimal
    estimated: bool
    estimated_items: list[str] = field(default_factory=list)
    missing_fx: list[str] = field(default_factory=list)


def _month_ends(first: date, as_of: date):
    y, m = first.year, first.month
    while (y, m) <= (as_of.year, as_of.month):
        if (y, m) == (as_of.year, as_of.month):
            yield f"{y}-{m:02d}", as_of
        else:
            yield f"{y}-{m:02d}", date(y, m, _cal.monthrange(y, m)[1])
        m += 1
        if m == 13:
            y, m = y + 1, 1


def monthly_snapshots(
    holdings: list[SnapshotHolding],
    price_history: dict[str, Series],
    fx_history: dict[str, Series],
    view: str,
    as_of: date,
    only_currency: str | None = None,
) -> list[MonthPoint]:
    """`only_currency`：例如 "USD" 時只計該幣別資產且不換算（USD 檢視的「原幣」模式）。"""
    hs = [h for h in holdings if h.include_in_overview]
    if only_currency is not None:
        hs = [h for h in hs if h.currency == only_currency]
        view = only_currency
    all_dates = [t.trade_date for h in hs for t in h.transactions]
    if not all_dates:
        return []
    first = min(all_dates)
    out: list[MonthPoint] = []
    for month, d in _month_ends(first, as_of):
        month_start = date(d.year, d.month, 1)
        rates: dict[str, Decimal] = {}
        est_items: list[str] = []
        missing: set[str] = set()
        # 原幣模式下所有資產幣別都等於檢視幣別，不需要匯率
        needed = set() if only_currency is not None else ({h.currency for h in hs} | {view})
        for c in needed:
            if c == "TWD":
                continue
            v, vd, manual = fx_history.get(c, Series()).at(d)
            if v is None:
                missing.add(c)
                continue
            rates[c] = v
            if not manual and vd is not None and vd < month_start:
                est_items.append(f"FX:{c}")
        mv_t = inv_t = hist_t = ex_t = div_t = ZERO
        for h in hs:
            pos = build_position(list(h.transactions), as_of=d)
            if (
                pos.quantity == 0
                and pos.historical_invested == 0
                and pos.dividends_net == 0
                and pos.standalone_fees == 0
            ):
                continue
            p, pd, manual = price_history.get(h.instrument_id, Series()).at(d)
            stale = p is not None and not manual and pd is not None and pd < month_start
            if p is None and pos.last_trade_price is not None:
                p = pos.last_trade_price
                stale = True
            mv = pos.cost_basis if p is None else pos.quantity * p
            if (p is None or stale) and pos.quantity != 0:
                est_items.append(f"PRICE:{h.instrument_id}")
            if h.currency in missing or view in missing:
                continue

            def cv(x: Decimal) -> Decimal:
                r = convert(x, h.currency, view, rates)
                assert r is not None
                return r

            mv_t += cv(mv)
            inv_t += cv(pos.invested_current)
            hist_t += cv(pos.historical_invested)
            ex_t += cv(mv - pos.cost_basis + pos.realized_pnl - pos.standalone_fees)
            div_t += cv(pos.dividends_net)
        est_items = sorted(set(est_items))
        out.append(
            MonthPoint(
                month=month,
                date=d,
                market_value=mv_t,
                invested_current=inv_t,
                historical_invested=hist_t,
                pnl_ex_div=ex_t,
                pnl_inc_div=ex_t + div_t,
                estimated=bool(est_items) or bool(missing),
                estimated_items=est_items,
                missing_fx=sorted(missing),
            )
        )
    return out
