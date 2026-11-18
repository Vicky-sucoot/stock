"""設定：一律從環境變數讀取，不在程式碼中放任何金鑰。"""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Settings:
    # 原型用 SQLite；正式改成 postgresql+psycopg://...（docs/09 §4）
    db_url: str = "sqlite:///./data/dca.db"
    # 原始回應保存目錄（正式環境可換成物件儲存）
    raw_dir: Path = Path("./data/raw")
    # 對同一主機兩次請求的最短間隔（秒），避免對官方 API 造成負擔（docs/06 §1）
    request_interval_s: float = 10.0
    # 網路錯誤或 5xx 時的重試等待（秒）
    retry_backoff_s: tuple[float, ...] = (5.0, 15.0)
    http_timeout_s: float = 30.0
    # 不含任何個人或專案資訊的通用識別
    user_agent: str = "dca-backend/0.1"

    @classmethod
    def from_env(cls) -> "Settings":
        d = cls()
        backoff = os.environ.get("DCA_RETRY_BACKOFF_S")
        return cls(
            db_url=os.environ.get("DCA_DB_URL", d.db_url),
            raw_dir=Path(os.environ.get("DCA_RAW_DIR", str(d.raw_dir))),
            request_interval_s=float(os.environ.get("DCA_REQUEST_INTERVAL_S", d.request_interval_s)),
            retry_backoff_s=tuple(float(x) for x in backoff.split(",")) if backoff else d.retry_backoff_s,
            http_timeout_s=float(os.environ.get("DCA_HTTP_TIMEOUT_S", d.http_timeout_s)),
        )
