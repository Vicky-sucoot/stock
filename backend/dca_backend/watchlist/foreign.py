"""外資分 F（docs/06 §2）。使用「外資及陸資（不含外資自營商）」買賣超股數。"""

from __future__ import annotations

from dataclasses import dataclass, field
from decimal import Decimal

from .params import Params


@dataclass
class ForeignInput:
    symbol: str
    net_shares: int
    streak: int  # 連續同方向天數（含當日）
    close: Decimal | None
    volume: int | None  # 當日成交股數
    pct_rank: Decimal | None = None  # 同方向 |金額| 由大到小的名次 ÷ 家數（0～1）
    flags: list[str] = field(default_factory=list)


@dataclass
class ForeignScore:
    score: int
    s1: int
    s2: int
    s3: int
    direction: int  # +1 買超、-1 賣超、0
    amount: Decimal | None  # 以收盤價估算的買賣超金額
    ratio: Decimal | None  # |買賣超| ÷ 成交量
    consecutive: bool
    big_day: bool


def streak_points(streak: int, p: Params) -> int:
    for min_days, pts in p.streak_points:
        if streak >= min_days:
            return pts
    return 0


def score_foreign(x: ForeignInput, p: Params) -> ForeignScore:
    direction = (x.net_shares > 0) - (x.net_shares < 0)
    amount = Decimal(x.net_shares) * x.close if x.close is not None else None
    ratio = Decimal(abs(x.net_shares)) / Decimal(x.volume) if x.volume else None
    if direction == 0:
        return ForeignScore(0, 0, 0, 0, 0, amount, ratio, False, False)
    s1 = streak_points(min(x.streak, p.streak_cap), p)
    s2 = 0
    if ratio is not None and amount is not None and ratio >= p.big_ratio and abs(amount) >= p.big_amount:
        s2 = p.big_points + (p.big_extra_points if ratio >= p.big_ratio_extra else 0)
    s3 = 0
    if x.pct_rank is not None:
        for tier, pts in p.size_tiers:
            if x.pct_rank <= tier:
                s3 = pts
                break
    total = min(p.foreign_cap, s1 + s2 + s3)
    return ForeignScore(direction * total, s1, s2, s3, direction, amount, ratio, s1 > 0, s2 > 0)


def percentile_ranks(amounts: dict[str, Decimal]) -> dict[str, Decimal]:
    """同方向 |金額| 由大到小排名；回傳 名次 ÷ 家數（第 1 名 = 1/n）。"""
    ordered = sorted(amounts.items(), key=lambda kv: (-abs(kv[1]), kv[0]))
    n = len(ordered)
    return {sym: Decimal(i + 1) / Decimal(n) for i, (sym, _) in enumerate(ordered)}
