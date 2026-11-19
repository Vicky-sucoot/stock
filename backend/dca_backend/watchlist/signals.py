"""訊息判定與訊息分 N（docs/06 §3）。

MVP 的訊息來源只有官方公司重大訊息（政府開放資料）；未授權新聞不爬取、不保存、不送 LLM。
判定流程：規則先行 → 規則無法確定時才交給 LLM（預設停用）→ 否定語句與衝突檢查。
"""

from __future__ import annotations

import math
import re
import unicodedata
from dataclasses import dataclass, field
from datetime import date, datetime, time, timedelta
from decimal import Decimal
from typing import Protocol

from ..parsing import TAIPEI
from .params import Params

# --- 規則表（只看主旨；說明欄多為固定表單文字，只交給 LLM）---
# 2026-11-18 以真實重大訊息校準：原本把「處分」（多為處分基金或資產）與說明欄的表單文字當成利空，誤判大量例行公告。

NEGATIVE_KEYWORDS = [
    "更正財報", "重編財報", "財報更正", "更正後財報", "停止交易", "暫停交易", "終止上櫃", "終止上市", "下市",
    "變更交易方法", "分盤集合競價", "全額交割", "處置股票", "重整", "破產", "跳票", "退票", "違約",
    "裁罰", "罰鍰", "糾正", "停業", "減資彌補", "虧損", "淨損", "營收衰退", "獲利衰退", "下修",
    "停工", "停產", "火災", "爆炸", "起訴", "訴訟", "求償", "掏空", "背信", "搜索", "羈押", "查扣",
    "資訊安全事件", "無法表示意見", "保留意見",
]
POSITIVE_KEYWORDS = [
    "現金股利", "股票股利", "取得重大訂單", "重大訂單", "簽訂重大合約", "得標", "庫藏股",
    "買回本公司股份", "獲利成長", "營收成長", "營收創新高", "創新高", "上修", "擴產", "擴廠", "新產品量產",
]
# 例行行政事項：出現時直接判為中性，優先於利多／利空關鍵字（例如除息基準日公告、庫藏股註銷登記完成）
ROUTINE_MARKERS = [
    "基準日", "發放日", "變更登記完成", "主管異動", "主管任命", "發言人異動", "使用權資產", "處理程序",
    "得標廠商", "取得機器設備", "取得營業用", "取得不動產", "理財商品", "理財產品", "存款", "基金",
]
NEUTRAL_KEYWORDS = [
    "更名", "股東會", "股東常會", "股東臨時會", "董事會召開", "召開董事會", "法人說明會", "法說會", "人事異動",
    "發言人", "代理發言人", "背書保證", "資金貸與", "取得有價證券", "處分有價證券",
    "內部稽核", "會計師變更", "簽證會計師",
]
NEGATION_WORDS = ["未", "不", "否認", "非屬", "無", "取消", "終止", "撤回", "並非"]
CLARIFICATION_WORDS = ["澄清", "說明媒體報導", "媒體報導"]

# 否定詞與關鍵字之間最多相隔幾個字，視為否定該關鍵字
NEGATION_SPAN = 6


@dataclass
class RuleResult:
    polarity: int
    confidence: Decimal
    decided: bool
    matched: list[str]
    negation: bool
    clarification: bool
    rationale: str


def _norm(s: str) -> str:
    s = unicodedata.normalize("NFKC", s or "")
    return re.sub(r"\s+", "", s)


def _negated(text: str, start: int) -> bool:
    window = text[max(0, start - NEGATION_SPAN):start]
    return any(w in window for w in NEGATION_WORDS)


def classify_rule(subject: str, description: str | None = None) -> RuleResult:
    """只依主旨判定利多／利空；只有單一方向且未被否定時才視為「已判定」。

    `description`（說明欄）不參與規則判定：真實資料顯示它多為固定表單文字，容易誤判；它只會交給 LLM。
    """
    del description
    raw_text = _norm(subject)
    clar = any(w in raw_text for w in CLARIFICATION_WORDS)
    routine = [w for w in ROUTINE_MARKERS if w in raw_text]
    neu = [(w, False) for w in NEUTRAL_KEYWORDS if w in raw_text]
    # 先遮蔽中性片語，避免「處分有價證券」等被當成其他關鍵字
    text = raw_text
    for w, _ in neu:
        text = text.replace(w, "＿" * len(w))

    def hits(words: list[str], src: str) -> list[tuple[str, bool]]:
        out = []
        for w in words:
            i = src.find(w)
            if i >= 0:
                out.append((w, _negated(src, i)))
        return out

    pos = hits(POSITIVE_KEYWORDS, text)
    neg = hits(NEGATIVE_KEYWORDS, text)
    negation = any(n for _, n in pos + neg)
    eff_pos = [w for w, n in pos if not n]
    eff_neg = [w for w, n in neg if not n]
    # 被否定的利多（例如「取消庫藏股」「未取得訂單」）視為利空線索，但不算已判定
    negated_pos = [w for w, n in pos if n]
    matched = routine + [w for w, _ in pos + neg + neu]

    if clar:
        # 澄清公告預設中性（docs/06 §3.2-4）
        return RuleResult(0, Decimal("0.7"), True, matched, negation, True, "澄清媒體報導，預設中性")
    if routine:
        return RuleResult(0, Decimal("0.7"), True, matched, False, False, f"例行行政事項：{'、'.join(routine)}")
    if eff_pos and not eff_neg and not negation:
        return RuleResult(1, Decimal("0.8"), True, matched, False, False, f"主旨含利多關鍵字：{'、'.join(eff_pos)}")
    if eff_neg and not eff_pos and not negation:
        return RuleResult(-1, Decimal("0.8"), True, matched, False, False, f"主旨含利空關鍵字：{'、'.join(eff_neg)}")
    if not pos and not neg and neu:
        return RuleResult(0, Decimal("0.7"), True, matched, False, False, f"例行或中性事項：{'、'.join(w for w, _ in neu)}")
    if negated_pos and not eff_pos:
        return RuleResult(-1, Decimal("0.4"), False, matched, True, False,
                          f"利多關鍵字前有否定詞（{'、'.join(negated_pos)}），需進一步判定")
    if eff_pos and eff_neg:
        return RuleResult(0, Decimal("0.3"), False, matched, negation, False, "同時含利多與利空關鍵字")
    if negation:
        return RuleResult(0, Decimal("0.4"), False, matched, True, False, "含否定語句，需進一步判定")
    return RuleResult(0, Decimal("0.3"), False, matched, False, False, "規則無法判定")


# --- LLM 介面（預設停用；見 llm.py） ---


@dataclass
class LLMJudgement:
    polarity: int
    confidence: Decimal
    relevance: Decimal
    negation_detected: bool
    rationale: str


class LLMClassifier(Protocol):
    model: str
    prompt_version: str

    def classify(self, symbol: str, company: str, subject: str, description: str | None) -> LLMJudgement | None:
        """失敗時回傳 None（記為中性並標示 LLM_FAILED）。"""


@dataclass
class Assessment:
    item_id: int
    symbol: str
    polarity: int
    confidence: Decimal
    relevance: Decimal
    method: str  # RULE / LLM / RULE+LLM / NONE
    rationale: str
    has_negation: bool
    flags: list[str] = field(default_factory=list)
    model: str | None = None
    prompt_version: str | None = None


def assess(item_id: int, symbol: str, company: str, subject: str, description: str | None,
           llm: LLMClassifier | None, llm_first: bool = False) -> Assessment:
    """`llm_first=True`（使用者決定以 Claude 判定訊息情緒）：規則已判定也交給 Claude，規則只做交叉檢查與備援。"""
    rule = classify_rule(subject, description)
    one = Decimal(1)
    if rule.decided and not (llm_first and llm is not None):
        return Assessment(item_id, symbol, rule.polarity, rule.confidence, one, "RULE", rule.rationale, rule.negation)
    if llm is None:
        # 規則無法確定、又沒有 LLM：中性，不計分
        return Assessment(item_id, symbol, 0, rule.confidence, one, "RULE", rule.rationale, rule.negation,
                          ["RULE_UNDECIDED"])
    j = llm.classify(symbol, company, subject, description)
    if j is None:
        # Claude 失敗：規則已判定時沿用規則結果，否則中性
        return Assessment(item_id, symbol, rule.polarity if rule.decided else 0, rule.confidence, one, "RULE",
                          rule.rationale, rule.negation, ["LLM_FAILED"], llm.model, llm.prompt_version)
    flags: list[str] = []
    polarity, confidence = j.polarity, j.confidence
    # 規則有傾向而與 LLM 相反：取 0（docs/06 §3.2-5）
    if rule.polarity != 0 and j.polarity != 0 and rule.polarity != j.polarity:
        polarity = 0
        flags.append("MODEL_RULE_CONFLICT")
    # 否定語句判斷不一致：信心減半（docs/06 §3.2-3）
    if rule.negation != j.negation_detected:
        confidence = confidence * Decimal("0.5")
        flags.append("NEGATION_DISAGREE")
    return Assessment(item_id, symbol, polarity, confidence, min(one, max(Decimal(0), j.relevance)), "RULE+LLM",
                      j.rationale[:80], rule.negation or j.negation_detected, flags, llm.model, llm.prompt_version)


# --- 時效窗口與去重複 ---


def window(data_date: date, prev_trading_day: date | None, p: Params) -> tuple[datetime, datetime]:
    """前一交易日 13:30 到當日 13:30（台灣時間）。沒有前一交易日資料時，往前推一個平日。"""
    hh, mm = p.window_cutoff_hhmm
    if prev_trading_day is None:
        prev_trading_day = data_date - timedelta(days=3 if data_date.isoweekday() == 1 else 1)
    start = datetime.combine(prev_trading_day, time(hh, mm), tzinfo=TAIPEI)
    end = datetime.combine(data_date, time(hh, mm), tzinfo=TAIPEI)
    return start, end


def normalize_title(s: str) -> str:
    s = unicodedata.normalize("NFKC", s or "")
    return re.sub(r"[\s\W_]+", "", s)


def trigrams(s: str) -> set[str]:
    return {s[i:i + 3] for i in range(max(0, len(s) - 2))} or ({s} if s else set())


def jaccard(a: set[str], b: set[str]) -> Decimal:
    if not a or not b:
        return Decimal(0)
    return Decimal(len(a & b)) / Decimal(len(a | b))


@dataclass
class Item:
    item_id: int
    symbol: str
    subject: str
    published_at: datetime


def cluster(items: list[Item], p: Params) -> list[list[Item]]:
    """同一代號、24 小時內，標題相同或 3-gram Jaccard ≥ 0.8 的歸為一群；每群以最早發布者為代表。"""
    clusters: list[list[Item]] = []
    for it in sorted(items, key=lambda x: (x.published_at, x.item_id)):
        key = normalize_title(it.subject)
        tg = trigrams(key)
        placed = False
        for c in clusters:
            rep = c[0]
            if rep.symbol != it.symbol or it.published_at - rep.published_at > timedelta(hours=p.dedupe_hours):
                continue
            rk = normalize_title(rep.subject)
            if rk == key or jaccard(trigrams(rk), tg) >= p.dedupe_jaccard:
                c.append(it)
                placed = True
                break
        if not placed:
            clusters.append([it])
    return clusters


@dataclass
class NewsScore:
    score: int
    raw_sum: Decimal
    low_confidence: bool
    counted: list[Assessment]


def score_news(reps: list[Assessment], p: Params) -> NewsScore:
    """N = 50 × tanh(Σ polarity × confidence × relevance / 2)；有方向的判定平均信心 < 0.5 時再減半。"""
    total = sum((Decimal(a.polarity) * a.confidence * a.relevance for a in reps), Decimal(0))
    directional = [a for a in reps if a.polarity != 0]
    low = bool(directional) and (sum((a.confidence for a in directional), Decimal(0)) / len(directional)) < p.low_confidence
    value = Decimal(p.news_scale) * Decimal(str(math.tanh(float(total / p.news_divisor))))
    if low:
        value = value * Decimal("0.5")
    return NewsScore(int(value.to_integral_value(rounding="ROUND_HALF_EVEN")), total, low, reps)
