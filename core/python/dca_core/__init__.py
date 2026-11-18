"""DCA 投資管理 App 計算核心（Python 參考實作）。

與 iOS 的 Swift 實作（ios/DCACore）共用 core/testcases/*.json 的測試案例，
兩邊必須產生相同結果。規則來源見 docs/02-portfolio-plans-calc.md 與 docs/05。
"""

from .calendar import TradingCalendar, market_today
from .schedule import Plan, Occurrence, due_occurrences, upcoming_occurrences
from .ledger import Transaction, Position, build_position, LedgerError
from .valuation import (
    PriceInput,
    Override,
    FxInput,
    resolve_price,
    resolve_fx,
    convert,
    overview,
)
from .snapshots import monthly_snapshots

__all__ = [
    "TradingCalendar",
    "market_today",
    "Plan",
    "Occurrence",
    "due_occurrences",
    "upcoming_occurrences",
    "Transaction",
    "Position",
    "build_position",
    "LedgerError",
    "PriceInput",
    "Override",
    "FxInput",
    "resolve_price",
    "resolve_fx",
    "convert",
    "overview",
    "monthly_snapshots",
]
