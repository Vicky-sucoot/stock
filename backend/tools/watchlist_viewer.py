"""內部檢視工具（docs/09 §2 原型 P0）：檢視每日觀察名單的分數與證據，用來調整門檻。

不含任何個人投資資料，不對外開放。資料來源是 data 分支 watchlist/ 目錄下的 JSON。

    pip install streamlit
    streamlit run tools/watchlist_viewer.py -- --dir ../data-branch/watchlist
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import streamlit as st

LABELS = {"BULLISH": "偏多訊號觀察", "BEARISH": "偏空／避開訊號觀察", "UNCERTAIN": "訊號衝突／資料不足"}


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", default="watchlist")
    args = ap.parse_args()
    files = sorted(p for p in Path(args.dir).glob("*.json") if p.name != "latest.json")
    st.set_page_config(page_title="觀察名單檢視（內部）", layout="wide")
    st.title("每日觀察名單（內部檢視）")
    if not files:
        st.warning(f"{args.dir} 沒有任何結果檔")
        return
    chosen = st.sidebar.selectbox("資料日", [p.stem for p in reversed(files)])
    run = json.loads((Path(args.dir) / f"{chosen}.json").read_text(encoding="utf-8"))
    st.caption(f"狀態 {run['status']}｜規則 {run['rule_version']}｜產生於 {run['generated_at']}｜{run['disclaimer']}")
    st.json(run["coverage"], expanded=False)
    for lt, label in LABELS.items():
        rows = [e for e in run["entries"] if e["list_type"] == lt]
        st.subheader(f"{label}（{len(rows)}）")
        st.dataframe([{k: e[k] for k in ("rank", "symbol", "name", "board", "score_total", "score_foreign",
                                         "score_news", "reason_short")} | {"flags": ",".join(e["flags"])} for e in rows],
                     hide_index=True, use_container_width=True)
        for e in rows:
            with st.expander(f"{e['symbol']} {e['name']} 證據"):
                st.json(e["evidence"])


if __name__ == "__main__":
    main()
