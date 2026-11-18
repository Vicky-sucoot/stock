"""後端資料表（docs/04 §2）。只存公開市場資料。"""

from __future__ import annotations

from datetime import date, datetime, timezone
from decimal import Decimal

from sqlalchemy import (
    BigInteger,
    Boolean,
    Date,
    DateTime,
    ForeignKey,
    Integer,
    Numeric,
    String,
    Text,
    TypeDecorator,
    UniqueConstraint,
)
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column


class ExactDecimal(TypeDecorator):
    """PostgreSQL 用 NUMERIC；SQLite 存成字串，避免浮點誤差。"""

    impl = Numeric(24, 8)
    cache_ok = True

    def load_dialect_impl(self, dialect):
        if dialect.name == "sqlite":
            return dialect.type_descriptor(String(40))
        return dialect.type_descriptor(Numeric(24, 8))

    def process_bind_param(self, value, dialect):
        if value is None:
            return None
        return str(value) if dialect.name == "sqlite" else value

    def process_result_value(self, value, dialect):
        if value is None:
            return None
        return Decimal(value) if isinstance(value, str) else Decimal(str(value))


class UTCDateTime(TypeDecorator):
    """一律以 UTC 儲存；讀回時附上 UTC 時區（SQLite 本身不保存時區）。"""

    impl = DateTime(timezone=True)
    cache_ok = True

    def process_bind_param(self, value, dialect):
        if value is None:
            return None
        if value.tzinfo is None:
            raise ValueError("naive datetime is not allowed")
        v = value.astimezone(timezone.utc)
        return v.replace(tzinfo=None) if dialect.name == "sqlite" else v

    def process_result_value(self, value, dialect):
        if value is None:
            return None
        return value.replace(tzinfo=timezone.utc) if value.tzinfo is None else value.astimezone(timezone.utc)


class Base(DeclarativeBase):
    pass


class RawPayload(Base):
    """原始回應：檔案存在 raw_dir，表中記錄位置與雜湊，供追溯（docs/06 §1 來源追蹤）。"""

    __tablename__ = "raw_payload"
    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    source_id: Mapped[str] = mapped_column(String(64), index=True)
    url: Mapped[str] = mapped_column(Text)
    fetched_at: Mapped[datetime] = mapped_column(UTCDateTime)
    http_status: Mapped[int] = mapped_column(Integer)
    sha256: Mapped[str] = mapped_column(String(64), index=True)
    size_bytes: Mapped[int] = mapped_column(Integer)
    path: Mapped[str] = mapped_column(Text)


class FetchLog(Base):
    __tablename__ = "fetch_log"
    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    job: Mapped[str] = mapped_column(String(64), index=True)
    source_id: Mapped[str] = mapped_column(String(64))
    url: Mapped[str] = mapped_column(Text)
    attempt: Mapped[int] = mapped_column(Integer)
    started_at: Mapped[datetime] = mapped_column(UTCDateTime)
    duration_ms: Mapped[int] = mapped_column(Integer)
    http_status: Mapped[int | None] = mapped_column(Integer, nullable=True)
    size_bytes: Mapped[int | None] = mapped_column(Integer, nullable=True)
    error: Mapped[str | None] = mapped_column(Text, nullable=True)


class JobRun(Base):
    __tablename__ = "job_run"
    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    job: Mapped[str] = mapped_column(String(64), index=True)
    started_at: Mapped[datetime] = mapped_column(UTCDateTime)
    finished_at: Mapped[datetime | None] = mapped_column(UTCDateTime, nullable=True)
    # OK / NOT_UPDATED / FAILED
    status: Mapped[str] = mapped_column(String(16))
    data_date: Mapped[date | None] = mapped_column(Date, nullable=True)
    rows_upserted: Mapped[int] = mapped_column(Integer, default=0)
    message: Mapped[str | None] = mapped_column(Text, nullable=True)


class MarketInstrument(Base):
    __tablename__ = "market_instrument"
    __table_args__ = (UniqueConstraint("market", "symbol", name="uq_instrument_market_symbol"),)
    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    market: Mapped[str] = mapped_column(String(8))  # TW / US / JP
    board: Mapped[str | None] = mapped_column(String(8), nullable=True)  # TWSE / TPEX
    symbol: Mapped[str] = mapped_column(String(16))
    name: Mapped[str] = mapped_column(String(128))
    asset_type: Mapped[str] = mapped_column(String(8))  # STOCK / ETF / OTHER
    currency: Mapped[str] = mapped_column(String(3))
    active: Mapped[bool] = mapped_column(Boolean, default=True)
    updated_at: Mapped[datetime] = mapped_column(UTCDateTime)


class DailyQuote(Base):
    __tablename__ = "daily_quote"
    instrument_id: Mapped[int] = mapped_column(ForeignKey("market_instrument.id"), primary_key=True)
    trade_date: Mapped[date] = mapped_column(Date, primary_key=True)
    source_id: Mapped[str] = mapped_column(String(64), primary_key=True)
    open: Mapped[Decimal | None] = mapped_column(ExactDecimal, nullable=True)
    high: Mapped[Decimal | None] = mapped_column(ExactDecimal, nullable=True)
    low: Mapped[Decimal | None] = mapped_column(ExactDecimal, nullable=True)
    close: Mapped[Decimal | None] = mapped_column(ExactDecimal, nullable=True)
    change: Mapped[Decimal | None] = mapped_column(ExactDecimal, nullable=True)
    volume: Mapped[int | None] = mapped_column(BigInteger, nullable=True)
    turnover: Mapped[int | None] = mapped_column(BigInteger, nullable=True)
    suspicious: Mapped[bool] = mapped_column(Boolean, default=False)
    suspicious_reason: Mapped[str | None] = mapped_column(String(64), nullable=True)
    raw_payload_id: Mapped[int | None] = mapped_column(ForeignKey("raw_payload.id"), nullable=True)
    fetched_at: Mapped[datetime] = mapped_column(UTCDateTime)


class ForeignFlowDaily(Base):
    """外資及陸資買賣超原始資料（單位：股）。"""

    __tablename__ = "foreign_flow_daily"
    trade_date: Mapped[date] = mapped_column(Date, primary_key=True)
    board: Mapped[str] = mapped_column(String(8), primary_key=True)
    symbol: Mapped[str] = mapped_column(String(16), primary_key=True)
    name: Mapped[str] = mapped_column(String(128))
    # 外資及陸資（不含外資自營商）
    fi_buy: Mapped[int] = mapped_column(BigInteger)
    fi_sell: Mapped[int] = mapped_column(BigInteger)
    fi_net: Mapped[int] = mapped_column(BigInteger)
    # 外資自營商
    fd_buy: Mapped[int] = mapped_column(BigInteger)
    fd_sell: Mapped[int] = mapped_column(BigInteger)
    fd_net: Mapped[int] = mapped_column(BigInteger)
    # 外資及陸資合計
    fi_total_buy: Mapped[int] = mapped_column(BigInteger)
    fi_total_sell: Mapped[int] = mapped_column(BigInteger)
    fi_total_net: Mapped[int] = mapped_column(BigInteger)
    it_net: Mapped[int | None] = mapped_column(BigInteger, nullable=True)
    dealer_net: Mapped[int | None] = mapped_column(BigInteger, nullable=True)
    total_net: Mapped[int | None] = mapped_column(BigInteger, nullable=True)
    source_id: Mapped[str] = mapped_column(String(64))
    source_url: Mapped[str] = mapped_column(Text)
    raw_payload_id: Mapped[int | None] = mapped_column(ForeignKey("raw_payload.id"), nullable=True)
    fetched_at: Mapped[datetime] = mapped_column(UTCDateTime)


class Announcement(Base):
    """公司重大訊息（政府開放資料）。"""

    __tablename__ = "announcement"
    __table_args__ = (UniqueConstraint("source_id", "content_hash", name="uq_announcement_hash"),)
    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    source_id: Mapped[str] = mapped_column(String(64))
    board: Mapped[str] = mapped_column(String(8))
    symbol: Mapped[str] = mapped_column(String(16), index=True)
    company_name: Mapped[str] = mapped_column(String(128))
    published_at: Mapped[datetime] = mapped_column(UTCDateTime, index=True)
    subject: Mapped[str] = mapped_column(Text)
    clause: Mapped[str | None] = mapped_column(String(64), nullable=True)
    fact_date: Mapped[date | None] = mapped_column(Date, nullable=True)
    description: Mapped[str | None] = mapped_column(Text, nullable=True)
    source_url: Mapped[str] = mapped_column(Text)
    content_hash: Mapped[str] = mapped_column(String(64))
    license_basis: Mapped[str] = mapped_column(String(32))
    raw_payload_id: Mapped[int | None] = mapped_column(ForeignKey("raw_payload.id"), nullable=True)
    fetched_at: Mapped[datetime] = mapped_column(UTCDateTime)
