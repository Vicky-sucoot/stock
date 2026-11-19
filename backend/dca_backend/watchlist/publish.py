"""產生每日名單並加密發布（只給使用者本人看）。

倉庫與網站都是公開的；名單內容屬於個股分析，依使用者決定**只給自己看**：
以使用者自訂的通關密語（GitHub Secret `WATCHLIST_PASSPHRASE`）加密成 JSON，
網頁 App 在手機上輸入同一組密語後才解密顯示。沒有設定密語時不輸出任何檔案。

加密格式（與網頁 WebCrypto 相容）：PBKDF2-HMAC-SHA256 衍生 256-bit 金鑰 → AES-256-GCM。

    WATCHLIST_PASSPHRASE=... python -m dca_backend.watchlist.publish --out ../web/public/data/watchlist.enc.json
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import sys

from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.pbkdf2 import PBKDF2HMAC

ITERATIONS = 310_000
MIN_PASSPHRASE = 12


def _key(passphrase: str, salt: bytes, iterations: int) -> bytes:
    return PBKDF2HMAC(algorithm=hashes.SHA256(), length=32, salt=salt, iterations=iterations).derive(passphrase.encode("utf-8"))


def encrypt(data: dict, passphrase: str, iterations: int | None = None) -> dict:
    iterations = iterations or ITERATIONS
    if len(passphrase) < MIN_PASSPHRASE:
        raise ValueError(f"通關密語至少需要 {MIN_PASSPHRASE} 個字元")
    salt, iv = os.urandom(16), os.urandom(12)
    ct = AESGCM(_key(passphrase, salt, iterations)).encrypt(iv, json.dumps(data, ensure_ascii=False).encode("utf-8"), None)
    b64 = lambda b: base64.b64encode(b).decode()
    return {"v": 1, "alg": "PBKDF2-SHA256/AES-256-GCM", "iter": iterations, "salt": b64(salt), "iv": b64(iv), "ct": b64(ct)}


def decrypt(blob: dict, passphrase: str) -> dict:
    d = lambda s: base64.b64decode(s)
    pt = AESGCM(_key(passphrase, d(blob["salt"]), blob["iter"])).decrypt(d(blob["iv"]), d(blob["ct"]), None)
    return json.loads(pt.decode("utf-8"))


def fingerprint(s, data_date=None, llm_enabled: bool = False) -> str:
    """名單輸入的摘要（只含公開資料的雜湊）。輸入沒變時沿用上一版，避免同一天重複呼叫 Claude。"""
    from datetime import timezone

    from sqlalchemy import func, select

    from ..models import Announcement, ForeignFlowDaily
    from .engine import _trading_days
    from .params import RULE_VERSION, Params
    from .signals import window

    board = "TPEX"
    if data_date is None:
        data_date = s.scalar(select(func.max(ForeignFlowDaily.trade_date)).where(ForeignFlowDaily.board == board))
    h = hashlib.sha256(f"{RULE_VERSION}|{llm_enabled}|{data_date}".encode())
    if data_date is not None:
        for sym, net in s.execute(select(ForeignFlowDaily.symbol, ForeignFlowDaily.fi_net).where(
                ForeignFlowDaily.board == board, ForeignFlowDaily.trade_date == data_date).order_by(ForeignFlowDaily.symbol)):
            h.update(f"|{sym}:{net}".encode())
        days = _trading_days(s, board, data_date)
        start, end = window(data_date, days[-2] if len(days) > 1 else None, Params())
        for (ch,) in s.execute(select(Announcement.content_hash).where(
                Announcement.published_at >= (start - (end - start) * 2).astimezone(timezone.utc),
                Announcement.published_at < end.astimezone(timezone.utc))
                .order_by(Announcement.content_hash)):
            h.update(f"|{ch}".encode())
    return h.hexdigest()


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="dca_backend.watchlist.publish")
    ap.add_argument("--out", required=True)
    ap.add_argument("--date", default=None)
    ap.add_argument("--previous", default=None, help="上一版密文檔；輸入沒有改變時直接沿用")
    args = ap.parse_args(argv)
    passphrase = os.environ.get("WATCHLIST_PASSPHRASE", "")
    if not passphrase:
        print("WATCHLIST_PASSPHRASE 未設定：不產生名單檔（名單不得以明文公開）")
        return 0
    from datetime import date

    from ..config import Settings
    from ..db import make_engine, make_session_factory
    from .engine import build_watchlist, export_run
    from .llm import classifier_from_env, scorer_from_env

    sf = make_session_factory(make_engine(Settings.from_env().db_url))
    d = date.fromisoformat(args.date) if args.date else None
    scorer = scorer_from_env()
    with sf() as s:
        fp = fingerprint(s, d, scorer is not None)
        prev = _load(args.previous)
        if prev is not None and prev.get("fp") == fp:
            try:
                decrypt(prev, passphrase)  # 密語改過時重新產生
                _write(args.out, prev)
                print("watchlist inputs unchanged → 沿用上一版（不重新呼叫 Claude）")
                return 0
            except Exception:
                pass
        run = build_watchlist(s, d, llm=classifier_from_env(), scorer=scorer)
        out = export_run(s, run.run_id)
    blob = encrypt(out, passphrase)
    blob["fp"] = fp
    _write(args.out, blob)
    print(f"watchlist {out['data_date']} {out['status']} → {args.out}（已加密）")
    return 0


def _load(path: str | None) -> dict | None:
    if not path or not os.path.exists(path):
        return None
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError):
        return None


def _write(path: str, blob: dict) -> None:
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(blob, f)


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
