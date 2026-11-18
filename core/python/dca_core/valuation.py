"""價格與匯率解析、幣別換算、合併總覽（docs/02 §2.2–2.4、docs/05 §3）。

匯率以「1 單位幣別 = ? TWD」表示；TWD 固定為 1。換算到檢視幣別 V：
    amount × rate[ccy] ÷ rate[V]
成本與投入採「目前匯率重估」口徑（預設）。
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import date
from decimal import Decimal

from .ledger import Position

ZERO = Decimal(0)

MANUAL = "MANUAL"
AUTO = "AUTO"
LAST_TRADE = "LAST_TRADE"
COST = "COST"  # 沒有任何價格時以成本估市值
NONE = "NONE"


@dataclass(frozen=True)
class Override:
    value: Decimal
    effective_date: date
    set_at: str  # ISO 時間字串，同生效日時以較晚者為準
    active: bool = True


@dataclass(frozen=True)
class PriceInput:
    overrides: tuple[Override, ...] = ()
    auto_value: Decimal | None = None
    auto_data_date: date | None = None


@dataclass(frozen=True)
class FxInput:
    overrides: tuple[Override, ...] = ()
    auto_value: Decimal | None = None
    auto_data_date: date | None = None


def _active_override(overrides: tuple[Override, ...], as_of: date) -> Override | None:
    cands = [o for o in overrides if o.active and o.effective_date <= as_of]
    if not cands:
        return None
    return max(cands, key=lambda o: (o.effective_date, o.set_at))


def resolve_price(
    inp: PriceInput | None, as_of: date, last_trade_price: Decimal | None
) -> tuple[Decimal | None, str]:
    """優先序：使用者手動值 → 自動行情 → 最後成交價 → 無。"""
    if inp is not None:
        o = _active_override(inp.overrides, as_of)
        if o is not None:
            return o.value, MANUAL
        if inp.auto_value is not None:
            return inp.auto_value, AUTO
    if last_trade_price is not None:
        return last_trade_price, LAST_TRADE
    return None, NONE


def resolve_fx(currency: str, inp: FxInput | None, as_of: date) -> tuple[Decimal | None, str]:
    if currency == "TWD":
        return Decimal(1), AUTO
    if inp is not None:
        o = _active_override(inp.overrides, as_of)
        if o is not None:
            return o.value, MANUAL
        if inp.auto_value is not None:
            return inp.auto_value, AUTO
    return None, NONE


def convert(amount: Decimal, ccy: str, view: str, rates: dict[str, Decimal]) -> Decimal | None:
    if ccy == view:
        return amount
    r_from = Decimal(1) if ccy == "TWD" else rates.get(ccy)
    r_to = Decimal(1) if view == "TWD" else rates.get(view)
    if r_from is None or r_to is None:
        return None
    return amount * r_from / r_to


@dataclass(frozen=True)
class Holding:
    """overview 的輸入：某組合中的某標的。"""

    portfolio_id: str
    instrument_id: str
    currency: str
    position: Position
    include_in_overview: bool = True


@dataclass
class HoldingRow:
    instrument_id: str
    currency: str
    quantity: Decimal
    avg_cost: Decimal | None
    price: Decimal | None
    price_source: str
    market_value: Decimal  # 原幣
    market_value_view: Decimal | None


@dataclass
class Overview:
    view: str
    total_assets: Decimal
    invested_current: Decimal
    historical_invested: Decimal
    pnl_ex_div: Decimal
    pnl_inc_div: Decimal
    return_ex_div: Decimal | None
    return_inc_div: Decimal | None
    rows: list[HoldingRow] = field(default_factory=list)
    missing_fx: list[str] = field(default_factory=list)
    estimated_instruments: list[str] = field(default_factory=list)


def overview(
    holdings: list[Holding],
    prices: dict[str, PriceInput],
    fx: dict[str, FxInput],
    view: str,
    as_of: date,
) -> Overview:
    rates: dict[str, Decimal] = {}
    missing_fx: set[str] = set()
    for c in {h.currency for h in holdings} | {view}:
        r, _ = resolve_fx(c, fx.get(c), as_of)
        if r is None:
            missing_fx.add(c)
        else:
            rates[c] = r

    # 合併跨組合的同一標的（平均成本 = Σ成本 / Σ數量）
    merged: dict[str, dict] = {}
    for h in holdings:
        if not h.include_in_overview:
            continue
        m = merged.setdefault(
            h.instrument_id,
            {"currency": h.currency, "qty": ZERO, "cost": ZERO, "reinv": ZERO, "hist": ZERO,
             "realized": ZERO, "divs": ZERO, "fees": ZERO, "last": None},
        )
        p = h.position
        m["qty"] += p.quantity
        m["cost"] += p.cost_basis
        m["reinv"] += p.reinvested_cost
        m["hist"] += p.historical_invested
        m["realized"] += p.realized_pnl
        m["divs"] += p.dividends_net
        m["fees"] += p.standalone_fees
        if p.last_trade_price is not None:
            m["last"] = p.last_trade_price

    total = inv = hist = ex = divs = ZERO
    rows: list[HoldingRow] = []
    estimated: list[str] = []
    for iid in sorted(merged):
        m = merged[iid]
        ccy = m["currency"]
        price, src = resolve_price(prices.get(iid), as_of, m["last"])
        if price is None:
            mv = m["cost"]
            src = COST
        else:
            mv = m["qty"] * price
        if src in (LAST_TRADE, COST) and m["qty"] != 0:
            estimated.append(iid)
        mv_v = convert(mv, ccy, view, rates) if view not in missing_fx else None
        rows.append(
            HoldingRow(
                instrument_id=iid,
                currency=ccy,
                quantity=m["qty"],
                avg_cost=(m["cost"] / m["qty"]) if m["qty"] != 0 else None,
                price=price,
                price_source=src,
                market_value=mv,
                market_value_view=mv_v,
            )
        )
        if mv_v is None:
            continue  # 該幣別無法換算：不計入 KPI，由 missing_fx 提示
        def cv(x: Decimal) -> Decimal:
            v = convert(x, ccy, view, rates)
            assert v is not None
            return v
        total += mv_v
        inv += cv(m["cost"] - m["reinv"])
        hist += cv(m["hist"])
        ex += cv(mv - m["cost"] + m["realized"] - m["fees"])
        divs += cv(m["divs"])

    inc = ex + divs
    return Overview(
        view=view,
        total_assets=total,
        invested_current=inv,
        historical_invested=hist,
        pnl_ex_div=ex,
        pnl_inc_div=inc,
        return_ex_div=(ex / hist) if hist != 0 else None,
        return_inc_div=(inc / hist) if hist != 0 else None,
        rows=rows,
        missing_fx=sorted(missing_fx),
        estimated_instruments=estimated,
    )
