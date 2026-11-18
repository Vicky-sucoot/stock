"""評分參數（docs/06 §2–§4）。所有門檻集中於此；上線前需以累積資料回測後定案。"""

from __future__ import annotations

from dataclasses import asdict, dataclass
from decimal import Decimal

RULE_VERSION = "2026.11-draft2"


@dataclass(frozen=True)
class Params:
    # 外資分 F
    streak_points: tuple[tuple[int, int], ...] = ((8, 20), (5, 15), (4, 13), (3, 10))  # (最少天數, 分數)
    streak_cap: int = 10
    big_ratio: Decimal = Decimal("0.10")  # 買賣超占成交量
    big_ratio_extra: Decimal = Decimal("0.20")
    big_amount: Decimal = Decimal("30000000")  # NT$
    big_points: int = 20
    big_extra_points: int = 5
    size_tiers: tuple[tuple[Decimal, int], ...] = ((Decimal("0.01"), 5), (Decimal("0.05"), 3), (Decimal("0.10"), 1))
    foreign_cap: int = 50
    # 流動性過濾：近 20 日平均成交金額
    liquidity_days: int = 20
    min_avg_turnover: Decimal = Decimal("10000000")
    # 訊息分 N
    news_scale: int = 50
    news_divisor: Decimal = Decimal("2")
    low_confidence: Decimal = Decimal("0.5")
    window_cutoff_hhmm: tuple[int, int] = (13, 30)
    dedupe_jaccard: Decimal = Decimal("0.8")
    dedupe_hours: int = 24
    # 綜合
    conflict_min: int = 15
    list_threshold: int = 25
    max_entries: int = 10
    max_uncertain: int = 20

    def to_dict(self) -> dict:
        def conv(v):
            if isinstance(v, Decimal):
                return str(v)
            if isinstance(v, tuple):
                return [conv(x) for x in v]
            return v

        return {k: conv(v) for k, v in asdict(self).items()}
