"""從原始回應檔產生網頁 App 用的收盤價檔（官方開放資料，附來源標示；**不含觀察名單**）。

    python -m dca_backend.export_quotes --raw-dir <data 分支>/raw --out ../web/public/data/quotes.json

格式：
{
  "generated_at": "...", "disclaimer": "...",
  "sources": [{"id", "name", "attribution", "url", "license_url", "data_date"}],
  "quotes": {"2330": ["台積電", "TWSE", "2170.00", "2026-11-17"], ...}   # 收盤價為 null 代表當日無成交
}
"""

from __future__ import annotations

import argparse
import gzip
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

from .parsing import dec, norm_keys, roc_date
from .sources import SOURCES

FIELDS = {
    "TWSE_STOCK_DAY_ALL": ("TWSE", "Code", "Name", "ClosingPrice", "Date"),
    "TPEX_MAINBOARD_QUOTES": ("TPEX", "SecuritiesCompanyCode", "CompanyName", "Close", "Date"),
}


def latest_file(raw_dir: Path, source_id: str) -> Path | None:
    files = sorted((raw_dir / source_id).glob("*/*.json.gz"), key=lambda p: (p.parent.name, p.name))
    return files[-1] if files else None


def build(raw_dir: Path, now: datetime | None = None) -> dict:
    out = {"generated_at": (now or datetime.now(timezone.utc)).isoformat(),
           "disclaimer": "官方收盤資料可能延遲 1 個交易日以上；僅供記錄參考，不構成投資建議。",
           "sources": [], "quotes": {}}
    for sid, (board, k_sym, k_name, k_close, k_date) in FIELDS.items():
        f = latest_file(raw_dir, sid)
        if f is None:
            continue
        rows = json.loads(gzip.decompress(f.read_bytes()).decode("utf-8-sig"))
        dates = set()
        for raw in rows:
            r = norm_keys(raw)
            sym, d = (r.get(k_sym) or "").strip(), roc_date(r.get(k_date))
            if not sym or d is None:
                continue
            close = dec(r.get(k_close))
            out["quotes"][sym] = [(r.get(k_name) or "").strip(), board, str(close) if close is not None and close > 0 else None, d.isoformat()]
            dates.add(d)
        s = SOURCES[sid]
        out["sources"].append({"id": sid, "name": s.name, "attribution": s.attribution, "url": s.endpoint,
                               "license_url": s.license_url, "data_date": max(dates).isoformat() if dates else None})
    return out


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="dca_backend.export_quotes")
    ap.add_argument("--raw-dir", type=Path, required=True)
    ap.add_argument("--out", type=Path, required=True)
    a = ap.parse_args(argv)
    data = build(a.raw_dir)
    a.out.parent.mkdir(parents=True, exist_ok=True)
    a.out.write_text(json.dumps(data, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    print(f"quotes: {len(data['quotes'])} symbols, sources={[s['data_date'] for s in data['sources']]}")
    return 0 if data["quotes"] else 1


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
