"""執行 core/testcases/*.json 共用測試案例（Swift 端執行同一批檔案）。"""

from __future__ import annotations

import json
from datetime import date, datetime
from decimal import ROUND_HALF_EVEN, Decimal
from pathlib import Path

import pytest

from dca_core import (
    FxInput,
    LedgerError,
    Override,
    Plan,
    PriceInput,
    TradingCalendar,
    Transaction,
    build_position,
    due_occurrences,
    market_today,
    monthly_snapshots,
    overview,
    resolve_price,
    upcoming_occurrences,
)
from dca_core.snapshots import Series, SnapshotHolding
from dca_core.valuation import Holding

CASES = Path(__file__).resolve().parents[2] / "testcases"
Q = Decimal("1e-8")


def load(name: str) -> dict:
    return json.loads((CASES / name).read_text(encoding="utf-8"))


def d(s: str | None) -> date | None:
    return date.fromisoformat(s) if s else None


def dec(s: str | None) -> Decimal | None:
    return Decimal(s) if s is not None else None


def q8(x: Decimal | None) -> Decimal | None:
    return None if x is None else x.quantize(Q, rounding=ROUND_HALF_EVEN)


def assert_dec(actual: Decimal | None, expected: str | None, label: str) -> None:
    if expected is None:
        assert actual is None, label
        return
    assert actual is not None, label
    assert q8(actual) == q8(Decimal(expected)), f"{label}: {actual} != {expected}"


# ---------- schedule ----------

SCHED = load("schedule_cases.json")


def make_calendar(name: str) -> TradingCalendar:
    c = SCHED["calendars"][name]
    return TradingCalendar(
        holidays=frozenset(d(x) for x in c["holidays"]),
        known_through=d(c.get("known_through")),
    )


def make_plan(p: dict) -> Plan:
    return Plan(
        frequency=p["frequency"],
        start_date=d(p["start_date"]),
        end_date=d(p.get("end_date")),
        weekdays=tuple(p.get("weekdays", ())),
        month_days=tuple(p.get("month_days", ())),
        specific_dates=tuple(d(x) for x in p.get("specific_dates", ())),
        holiday_rule=p.get("holiday_rule", "NEXT_TRADING_DAY"),
        paused=p.get("paused", False),
    )


def occ_dict(o) -> dict:
    return {
        "period_key": o.period_key,
        "nominal_date": o.nominal_date.isoformat(),
        "scheduled_date": o.scheduled_date.isoformat(),
        "adjust_reasons": list(o.adjust_reasons),
        "merged_keys": list(o.merged_keys),
    }


@pytest.mark.parametrize("case", SCHED["due_cases"], ids=lambda c: c["id"])
def test_due(case):
    got = due_occurrences(
        make_plan(case["plan"]),
        make_calendar(case["calendar"]),
        d(case["today"]),
        existing_keys=set(case["existing_keys"]),
        since=d(case.get("since")),
    )
    assert [occ_dict(o) for o in got] == case["expect"]


@pytest.mark.parametrize("case", SCHED["upcoming_cases"], ids=lambda c: c["id"])
def test_upcoming(case):
    got = upcoming_occurrences(
        make_plan(case["plan"]), make_calendar(case["calendar"]), d(case["today"]), case["count"]
    )
    assert [occ_dict(o) for o in got] == case["expect"]


@pytest.mark.parametrize("case", SCHED["market_today_cases"], ids=lambda c: c["id"])
def test_market_today(case):
    now = datetime.fromisoformat(case["now_utc"].replace("Z", "+00:00"))
    assert market_today(case["market"], now).isoformat() == case["expect"]


# ---------- ledger ----------

def make_tx(t: dict) -> Transaction:
    return Transaction(
        type=t["type"],
        trade_date=d(t["trade_date"]),
        currency=t["currency"],
        gross_amount=Decimal(t.get("gross_amount", "0")),
        price=dec(t.get("price")),
        quantity=dec(t.get("quantity")),
        fee=Decimal(t.get("fee", "0")),
        tax=Decimal(t.get("tax", "0")),
        other_cost=Decimal(t.get("other_cost", "0")),
        cost_currency=t.get("cost_currency"),
        fx_rate_at_trade=dec(t.get("fx_rate_at_trade")),
        seq=t.get("seq", 0),
    )


LEDGER = load("ledger_cases.json")


@pytest.mark.parametrize("case", LEDGER["cases"], ids=lambda c: c["id"])
def test_ledger(case):
    txs = [make_tx(t) for t in case["transactions"]]
    if "expect_error" in case:
        with pytest.raises(LedgerError) as ei:
            build_position(txs, as_of=d(case.get("as_of")))
        assert ei.value.code == case["expect_error"]
        return
    p = build_position(txs, as_of=d(case.get("as_of")))
    e = case["expect"]
    for k in ["quantity", "cost_basis", "reinvested_cost", "historical_invested",
              "realized_pnl", "dividends_net", "standalone_fees", "last_trade_price"]:
        assert_dec(getattr(p, k), e[k], k)
    assert_dec(p.invested_current, e["invested_current"], "invested_current")
    assert_dec(p.avg_cost, e["avg_cost"], "avg_cost")


# ---------- valuation ----------

VAL = load("valuation_cases.json")


def make_overrides(lst) -> tuple[Override, ...]:
    return tuple(
        Override(value=Decimal(o["value"]), effective_date=d(o["effective_date"]),
                 set_at=o["set_at"], active=o.get("active", True))
        for o in (lst or [])
    )


def make_price_input(p: dict | None) -> PriceInput | None:
    if p is None:
        return None
    return PriceInput(overrides=make_overrides(p.get("overrides")),
                      auto_value=dec(p.get("auto_value")), auto_data_date=d(p.get("auto_data_date")))


def make_fx_input(p: dict) -> FxInput:
    return FxInput(overrides=make_overrides(p.get("overrides")),
                   auto_value=dec(p.get("auto_value")), auto_data_date=d(p.get("auto_data_date")))


@pytest.mark.parametrize("case", VAL["overview_cases"], ids=lambda c: c["id"])
def test_overview(case):
    holdings = [
        Holding(portfolio_id=h["portfolio_id"], instrument_id=h["instrument_id"], currency=h["currency"],
                position=build_position([make_tx(t) for t in h["transactions"]]),
                include_in_overview=h.get("include_in_overview", True))
        for h in VAL["holdings"]
    ]
    prices = {k: make_price_input(v) for k, v in VAL["prices"].items()}
    fx = {k: make_fx_input(v) for k, v in VAL["fx"].items() if k not in case["drop_fx"]}
    ov = overview(holdings, prices, fx, case["view"], d(VAL["as_of"]))
    e = case["expect"]
    for k in ["total_assets", "invested_current", "historical_invested", "pnl_ex_div",
              "pnl_inc_div", "return_ex_div", "return_inc_div"]:
        assert_dec(getattr(ov, k), e[k], k)
    assert ov.missing_fx == e["missing_fx"]
    assert ov.estimated_instruments == e["estimated_instruments"]
    rows = {r.instrument_id: r for r in ov.rows}
    for iid, er in e.get("rows", {}).items():
        r = rows[iid]
        assert_dec(r.quantity, er["quantity"], f"{iid}.quantity")
        assert_dec(r.avg_cost, er["avg_cost"], f"{iid}.avg_cost")
        assert_dec(r.price, er["price"], f"{iid}.price")
        assert r.price_source == er["price_source"]


@pytest.mark.parametrize("case", VAL["resolve_price_cases"], ids=lambda c: c["id"])
def test_resolve_price(case):
    v, src = resolve_price(make_price_input(case["input"]), d(case["as_of"]),
                           dec(case["last_trade_price"]))
    assert_dec(v, case["expect"]["value"], "value")
    assert src == case["expect"]["source"]


# ---------- snapshots ----------

SNAP = load("snapshot_cases.json")


def make_series(s: dict) -> Series:
    return Series(points=tuple((d(p[0]), Decimal(p[1])) for p in s.get("points", [])),
                  overrides=make_overrides(s.get("overrides")))


@pytest.mark.parametrize("case", SNAP["cases"], ids=lambda c: c["id"])
def test_snapshots(case):
    hs = [SnapshotHolding(instrument_id=h["instrument_id"], currency=h["currency"],
                          transactions=tuple(make_tx(t) for t in h["transactions"]))
          for h in case["holdings"]]
    pts = monthly_snapshots(
        hs,
        {k: make_series(v) for k, v in case["price_history"].items()},
        {k: make_series(v) for k, v in case["fx_history"].items()},
        case["view"],
        d(case["as_of"]),
        only_currency=case.get("only_currency"),
    )
    assert len(pts) == len(case["expect"])
    for p, e in zip(pts, case["expect"]):
        assert p.month == e["month"]
        assert p.date.isoformat() == e["date"]
        for k in ["market_value", "invested_current", "historical_invested", "pnl_ex_div", "pnl_inc_div"]:
            assert_dec(getattr(p, k), e[k], f"{e['month']}.{k}")
        assert p.estimated == e["estimated"], e["month"]
        assert p.estimated_items == e["estimated_items"], e["month"]
        assert p.missing_fx == e["missing_fx"], e["month"]
