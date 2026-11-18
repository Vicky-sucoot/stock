"""單一持有部位（某組合中的某標的）的交易回放：移動平均成本法（docs/02 §2.1）。

所有金額為原幣（標的計價幣別）。費用若以其他幣別收取（例如複委託以台幣收費），
以 fx_rate_at_trade（1 單位標的幣別 = ? TWD）換算；沒有則用 fx_fallback。

口徑：
- cost_basis：持有成本（含買入費用與股利再投入金額），移動平均。
- reinvested_cost：cost_basis 中屬於股利再投入的部分（賣出時等比例扣減）。
- invested_current：目前仍在部位中的「自己投入的錢」= cost_basis − reinvested_cost。
- historical_invested：歷史總投入 = Σ 買入總成本（不含股利再投入），作為報酬率分母。
- realized_pnl：賣出淨額 − 賣出部分的平均成本。
- dividends_net：現金股利淨額 + 再投入的股利金額（只計入「含股利」損益）。
- standalone_fees：獨立費用（FEE 類型，例如帳戶管理費），兩種損益都扣除。
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import date
from decimal import Decimal
from typing import Callable

BUY = "BUY"
SELL = "SELL"
DIVIDEND_CASH = "DIVIDEND_CASH"
DIVIDEND_STOCK = "DIVIDEND_STOCK"
DIVIDEND_REINVEST = "DIVIDEND_REINVEST"
FEE = "FEE"
SPLIT_ADJUST = "SPLIT_ADJUST"

TYPES = {BUY, SELL, DIVIDEND_CASH, DIVIDEND_STOCK, DIVIDEND_REINVEST, FEE, SPLIT_ADJUST}

ZERO = Decimal(0)

FxFallback = Callable[[str, str, date], Decimal]


class LedgerError(ValueError):
    """code：OVERSELL / FX_REQUIRED / INVALID_QUANTITY / INVALID_SPLIT / UNKNOWN_TYPE"""

    def __init__(self, code: str, message: str = "") -> None:
        super().__init__(f"{code}: {message}" if message else code)
        self.code = code


@dataclass(frozen=True)
class Transaction:
    type: str
    trade_date: date
    currency: str
    gross_amount: Decimal = ZERO
    price: Decimal | None = None
    quantity: Decimal | None = None
    fee: Decimal = ZERO
    tax: Decimal = ZERO
    other_cost: Decimal = ZERO
    cost_currency: str | None = None
    fx_rate_at_trade: Decimal | None = None  # 1 單位 currency = ? TWD
    seq: int = 0  # 同日排序；依輸入順序

    def __post_init__(self) -> None:
        if self.type not in TYPES:
            raise LedgerError("UNKNOWN_TYPE", self.type)


@dataclass(frozen=True)
class Position:
    quantity: Decimal
    cost_basis: Decimal
    reinvested_cost: Decimal
    historical_invested: Decimal
    realized_pnl: Decimal
    dividends_net: Decimal
    standalone_fees: Decimal
    last_trade_price: Decimal | None

    @property
    def invested_current(self) -> Decimal:
        return self.cost_basis - self.reinvested_cost

    @property
    def avg_cost(self) -> Decimal | None:
        if self.quantity == 0:
            return None
        return self.cost_basis / self.quantity


def _costs_in_ccy(t: Transaction, fx_fallback: FxFallback | None) -> Decimal:
    """fee + tax + other_cost 換算成標的幣別。"""
    total = t.fee + t.tax + t.other_cost
    cc = t.cost_currency or t.currency
    if cc == t.currency or total == 0:
        return total
    # 只支援 TWD ↔ 標的幣別（複委託情境），其他組合需要 fallback
    if cc == "TWD" and t.fx_rate_at_trade:
        return total / t.fx_rate_at_trade
    if t.currency == "TWD" and t.fx_rate_at_trade:
        return total * t.fx_rate_at_trade
    if fx_fallback is None:
        raise LedgerError("FX_REQUIRED", f"{cc}->{t.currency} on {t.trade_date}")
    return total * fx_fallback(cc, t.currency, t.trade_date)


def build_position(
    transactions: list[Transaction],
    as_of: date | None = None,
    fx_fallback: FxFallback | None = None,
) -> Position:
    qty = ZERO
    cost = ZERO
    reinv = ZERO
    hist = ZERO
    realized = ZERO
    divs = ZERO
    fees = ZERO
    last_price: Decimal | None = None

    ordered = sorted(enumerate(transactions), key=lambda it: (it[1].trade_date, it[1].seq, it[0]))
    for _, t in ordered:
        if as_of is not None and t.trade_date > as_of:
            continue
        extra = _costs_in_ccy(t, fx_fallback)
        if t.type == BUY:
            q = _req_qty(t)
            total = t.gross_amount + extra
            qty += q
            cost += total
            hist += total
            if t.price is not None:
                last_price = t.price
        elif t.type == SELL:
            q = _req_qty(t)
            if q > qty:
                raise LedgerError("OVERSELL", f"sell {q} > holding {qty} on {t.trade_date}")
            removed = cost * q / qty
            removed_reinv = reinv * q / qty
            proceeds = t.gross_amount - extra
            realized += proceeds - removed
            qty -= q
            if qty == 0:
                cost = ZERO
                reinv = ZERO
            else:
                cost -= removed
                reinv -= removed_reinv
            if t.price is not None:
                last_price = t.price
        elif t.type == DIVIDEND_CASH:
            divs += t.gross_amount - extra
        elif t.type == DIVIDEND_REINVEST:
            q = _req_qty(t)
            net = t.gross_amount - extra
            divs += net
            qty += q
            cost += net
            reinv += net
            if t.price is not None:
                last_price = t.price
        elif t.type == DIVIDEND_STOCK:
            qty += _req_qty(t)
        elif t.type == SPLIT_ADJUST:
            ratio = _req_qty(t)
            if ratio <= 0:
                raise LedgerError("INVALID_SPLIT", "ratio must be positive")
            qty *= ratio
        elif t.type == FEE:
            fees += t.gross_amount + extra
    return Position(
        quantity=qty,
        cost_basis=cost,
        reinvested_cost=reinv,
        historical_invested=hist,
        realized_pnl=realized,
        dividends_net=divs,
        standalone_fees=fees,
        last_trade_price=last_price,
    )


def _req_qty(t: Transaction) -> Decimal:
    if t.quantity is None or t.quantity <= 0:
        raise LedgerError("INVALID_QUANTITY", f"{t.type} on {t.trade_date}")
    return t.quantity
