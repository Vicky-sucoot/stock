"""Claude 評分（外資動向、訊息情緒）與加密發布：以假的 API 用戶端測試，不連網。"""

from __future__ import annotations

import json
from decimal import Decimal
from types import SimpleNamespace

import pytest

from dca_backend.watchlist import publish
from dca_backend.watchlist.engine import BEARISH, BULLISH, UNCERTAIN, build_watchlist, export_run
from dca_backend.watchlist.llm import AnthropicClassifier, AnthropicScorer, parse_scores
from dca_backend.watchlist.signals import LLMJudgement

from .test_watchlist_engine import NOW, db, entries, seed  # noqa: F401


def resp(payload, stop="end_turn"):
    text = payload if isinstance(payload, str) else json.dumps(payload, ensure_ascii=False)
    return SimpleNamespace(content=[SimpleNamespace(type="text", text=text)], stop_reason=stop,
                           usage=SimpleNamespace(input_tokens=100, output_tokens=50))


class FakeClient:
    def __init__(self, handler):
        self.handler = handler
        self.requests = []
        self.beta = SimpleNamespace(messages=SimpleNamespace(create=self._create))

    def _create(self, **kw):
        self.requests.append(kw)
        return self.handler(kw)


def test_parse_scores_validates_strictly():
    exp = {"A": 1, "B": -1, "C": 1}
    text = json.dumps({"items": [
        {"symbol": "A", "score": 30, "confidence": 0.8, "reason": "連 5 日買超"},
        {"symbol": "B", "score": 99, "confidence": 0.8, "reason": "超出範圍"},
        {"symbol": "C", "score": True, "confidence": 0.8, "reason": "布林值"},
        {"symbol": "Z", "score": 10, "confidence": 0.8, "reason": "未要求"},
        {"symbol": "A", "score": -5, "confidence": 0.8, "reason": "重複"},
    ]})
    out = parse_scores(text, exp)
    assert set(out) == {"A"} and out["A"].score == 30 and out["A"].confidence == Decimal("0.8")
    assert parse_scores("not json", exp) == {}
    assert parse_scores(json.dumps({"items": [], "extra": 1}), exp) == {}


def test_scorer_request_shape_and_refusal():
    calls = []

    def handler(kw):
        calls.append(kw)
        return resp("", stop="refusal")

    sc = AnthropicScorer(client=FakeClient(handler), batch_size=2)
    from dca_backend.watchlist.llm import FlowDay, FlowInput
    xs = [FlowInput(f"S{i}", "測試", 1, Decimal("10"), [FlowDay("2026-11-18", 1000, 10000)], 1, Decimal("0.5"))
          for i in range(3)]
    assert sc.score(xs) == {}
    assert len(calls) == 2  # 3 檔分 2 批
    kw = calls[0]
    assert kw["model"] == "claude-opus-5-5" and "temperature" not in kw
    assert kw["output_config"]["format"]["type"] == "json_schema"
    assert "<data>" in kw["messages"][0]["content"] and "淨買 1 張" in kw["messages"][0]["content"]


def scorer_handler(scores):
    def h(kw):
        body = kw["messages"][0]["content"]
        items = [{"symbol": sym, "score": sc, "confidence": 0.9, "reason": f"{sym} 理由"}
                 for sym, sc in scores.items() if f"代號 {sym}" in body]
        return resp({"items": items})
    return h


def test_engine_uses_claude_foreign_scores(db):  # noqa: F811
    # A001 規則 35 → Claude 20；A003 規則 −38 → Claude 給 +10（方向相反，不採用）；A004 未回傳 → 規則備援
    client = FakeClient(scorer_handler({"A001": 20, "A003": 10, "A002": 5}))
    sc = AnthropicScorer(client=client)
    with db() as s:
        run = build_watchlist(s, now=lambda: NOW, scorer=sc)
        e = entries(s, run.run_id)
        stats = json.loads(run.stats)
        assert stats["llm_foreign_calls"] == 1 and stats["llm_foreign_symbols"] == 4  # A001 A002 A003 A004
        assert json.loads(run.coverage)["llm_foreign"] is True

        bull = {x.symbol: x for x in e[BULLISH]}
        assert bull["A001"].score_foreign == 20 and bull["A001"].score_total == 39
        ev = json.loads(bull["A001"].evidence)["foreign"]
        assert ev["method"] == "CLAUDE" and ev["rule_F"] == 35 and ev["claude"]["reason"] == "A001 理由"

        bear = {x.symbol: x for x in e[BEARISH]}
        assert bear["A003"].score_foreign == -38
        assert "LLM_SIGN_MISMATCH" in json.loads(bear["A003"].flags)
        assert json.loads(bear["A003"].evidence)["foreign"]["method"] == "RULE"

        a004 = next(x for x in e[UNCERTAIN] if x.symbol == "A004")
        assert "LLM_FAILED" in json.loads(a004.flags)


def test_claude_first_news_for_scored_symbols(db):  # noqa: F811
    class FakeLLM:
        model, prompt_version = "fake", "t"

        def __init__(self):
            self.subjects = []
            self.calls = 0

        def classify(self, symbol, company, subject, description):
            self.calls += 1
            self.subjects.append((symbol, subject))
            return LLMJudgement(-1 if "訂單" in subject else 0, Decimal("0.9"), Decimal(1), False, "測試")

    llm = FakeLLM()
    sc = AnthropicScorer(client=FakeClient(scorer_handler({"A001": 35})))
    with db() as s:
        run = build_watchlist(s, now=lambda: NOW, llm=llm, scorer=sc)
        syms = {x for x, _ in llm.subjects}
        # A001（Claude 評分標的）的公告即使規則已判定也交給 Claude；上市 B001、無外資的 C001 維持規則
        assert "A001" in syms and "B001" not in syms and "C001" not in syms
        out = export_run(s, run.run_id)
        a001 = next(x for x in out["entries"] if x["symbol"] == "A001")
        item = next(i for i in a001["evidence"]["news"]["items"] if i["counted"])
        # 規則判利多、Claude 判利空 → 取 0 並標示衝突
        assert item["polarity"] == 0 and "MODEL_RULE_CONFLICT" in item["flags"] and item["method"] == "RULE+LLM"


def test_classifier_failure_keeps_decided_rule():
    def boom(kw):
        raise RuntimeError("network")

    from dca_backend.watchlist.signals import assess
    cl = AnthropicClassifier(client=FakeClient(boom))
    a = assess(1, "X", "測試", "公告本公司取得重大訂單", None, cl, llm_first=True)
    assert a.polarity == 1 and "LLM_FAILED" in a.flags


def test_encrypt_round_trip_and_wrong_passphrase():
    data = {"entries": [{"symbol": "A001", "reason_short": "外資連續 5 日買超"}]}
    blob = publish.encrypt(data, "correct horse battery", iterations=1000)
    assert set(blob) == {"v", "alg", "iter", "salt", "iv", "ct"} and "A001" not in json.dumps(blob)
    assert publish.decrypt(blob, "correct horse battery") == data
    with pytest.raises(Exception):
        publish.decrypt(blob, "wrong passphrase!!")
    with pytest.raises(ValueError):
        publish.encrypt(data, "short")


def test_publish_without_passphrase_writes_nothing(tmp_path, monkeypatch):
    monkeypatch.delenv("WATCHLIST_PASSPHRASE", raising=False)
    out = tmp_path / "w.enc.json"
    assert publish.main(["--out", str(out)]) == 0
    assert not out.exists()


def test_publish_encrypts_and_reuses_when_inputs_unchanged(tmp_path, monkeypatch):
    from dca_backend.db import create_all, make_engine, make_session_factory

    url = f"sqlite:///{tmp_path}/w.db"
    eng = make_engine(url)
    create_all(eng)
    with make_session_factory(eng)() as s:
        seed(s)
    monkeypatch.setenv("DCA_DB_URL", url)
    monkeypatch.setenv("WATCHLIST_PASSPHRASE", "correct horse battery")
    monkeypatch.delenv("DCA_LLM_ENABLED", raising=False)
    monkeypatch.setattr(publish, "ITERATIONS", 1000)
    out1, out2 = tmp_path / "a.json", tmp_path / "b.json"
    assert publish.main(["--out", str(out1)]) == 0
    blob = json.loads(out1.read_text())
    assert "A001" not in out1.read_text() and blob["fp"]
    data = publish.decrypt(blob, "correct horse battery")
    assert data["data_date"] == "2026-11-18" and any(e["symbol"] == "A001" for e in data["entries"])
    assert publish.main(["--out", str(out2), "--previous", str(out1)]) == 0
    assert out2.read_text() == out1.read_text()  # 輸入沒變：沿用，不重新產生
