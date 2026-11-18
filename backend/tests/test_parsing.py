from datetime import date, time
from decimal import Decimal

from dca_backend.parsing import dec, integer, norm_keys, roc_date, roc_time, taipei_datetime


def test_roc_date():
    assert roc_date("1151118") == date(2026, 11, 18)
    assert roc_date(" 991231 ") == date(2010, 12, 31)
    assert roc_date("1150230") is None
    assert roc_date("abc") is None
    assert roc_date(None) is None


def test_roc_time_pads_missing_leading_zero():
    assert roc_time("70004") == time(7, 0, 4)
    assert roc_time("133613") == time(13, 36, 13)
    assert roc_time("256000") is None
    assert roc_time("") is None


def test_taipei_datetime():
    dt = taipei_datetime(date(2026, 11, 17), time(7, 0, 4))
    assert dt.isoformat() == "2026-11-17T07:00:04+08:00"
    assert taipei_datetime(None, None) is None


def test_dec_and_integer():
    assert dec("11.22") == Decimal("11.22")
    assert dec("1,234.5") == Decimal("1234.5")
    assert dec("-0.5100") == Decimal("-0.51")
    for empty in ["", "----", "---", " -- ", None, "abc", "NaN"]:
        assert dec(empty) is None
    assert integer("-1090000") == -1090000
    assert integer("1.5") is None


def test_norm_keys_removes_spaces():
    assert norm_keys({" Foreign Dealers-Total Buy": 1, "主旨 ": 2}) == {"ForeignDealers-TotalBuy": 1, "主旨": 2}
