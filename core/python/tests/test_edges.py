from datetime import date, datetime, timedelta
from decimal import Decimal

import pytest

from dca_core import LedgerError, Plan, TradingCalendar, Transaction, build_position, market_today
from dca_core.schedule import due_occurrences, upcoming_occurrences


def test_plan_validation():
    with pytest.raises(ValueError):
        Plan(frequency="MONTHLY", start_date=date(2026, 1, 1))
    with pytest.raises(ValueError):
        Plan(frequency="MONTHLY", start_date=date(2026, 1, 1), month_days=(32,))
    with pytest.raises(ValueError):
        Plan(frequency="WEEKLY", start_date=date(2026, 1, 1), weekdays=(0,))
    with pytest.raises(ValueError):
        Plan(frequency="DATES", start_date=date(2026, 1, 1))
    with pytest.raises(ValueError):
        Plan(frequency="MONTHLY", start_date=date(2026, 1, 1), month_days=(1,), holiday_rule="X")


def test_calendar_gives_up_after_30_closed_days():
    start = date(2026, 1, 1)
    cal = TradingCalendar(holidays=frozenset(start + timedelta(days=i) for i in range(40)))
    with pytest.raises(ValueError):
        cal.next_open(start)


def test_calendar_unknown_flag():
    cal = TradingCalendar(known_through=date(2026, 12, 31))
    plan = Plan(frequency="MONTHLY", start_date=date(2027, 1, 1), month_days=(5,))
    occ = due_occurrences(plan, cal, date(2027, 1, 10))
    assert occ[0].calendar_unknown is True


def test_market_today_requires_aware_datetime():
    with pytest.raises(ValueError):
        market_today("TW", datetime(2026, 1, 1))


def test_upcoming_respects_end_date():
    plan = Plan(frequency="MONTHLY", start_date=date(2026, 1, 1), end_date=date(2026, 2, 28), month_days=(10,))
    got = upcoming_occurrences(plan, TradingCalendar(), date(2026, 1, 1), 5)
    assert [o.nominal_date for o in got] == [date(2026, 1, 10), date(2026, 2, 10)]


def test_fx_fallback_used_when_no_trade_rate():
    t = Transaction(type="BUY", trade_date=date(2026, 1, 5), currency="USD", price=Decimal(100),
                    quantity=Decimal(1), gross_amount=Decimal(100), fee=Decimal(32), cost_currency="TWD")
    p = build_position([t], fx_fallback=lambda a, b, d: Decimal(1) / Decimal(32))
    assert p.cost_basis == Decimal(101)


def test_twd_instrument_with_usd_fee():
    t = Transaction(type="BUY", trade_date=date(2026, 1, 5), currency="TWD", price=Decimal(100),
                    quantity=Decimal(10), gross_amount=Decimal(1000), fee=Decimal(1), cost_currency="USD",
                    fx_rate_at_trade=Decimal(32))
    assert build_position([t]).cost_basis == Decimal(1032)


@pytest.mark.parametrize("kind,qty", [("BUY", None), ("BUY", Decimal(0)), ("SPLIT_ADJUST", Decimal(-1))])
def test_invalid_quantities(kind, qty):
    t = Transaction(type=kind, trade_date=date(2026, 1, 5), currency="TWD", quantity=qty, gross_amount=Decimal(1))
    with pytest.raises(LedgerError):
        build_position([t])


def test_unknown_type():
    with pytest.raises(LedgerError) as ei:
        Transaction(type="NOPE", trade_date=date(2026, 1, 5), currency="TWD")
    assert ei.value.code == "UNKNOWN_TYPE"
