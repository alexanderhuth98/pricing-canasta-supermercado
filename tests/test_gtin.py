import duckdb
import pytest

from pricing_canasta.config import SQL_DIR


@pytest.mark.parametrize(
    ("raw", "normalized", "valid"),
    [
        ("96385074", "00000096385074", True),
        ("96385075", "00000096385075", False),
        ("036000291452", "00036000291452", True),
        ("036000291453", "00036000291453", False),
        ("4006381333931", "04006381333931", True),
        ("4006381333932", "04006381333932", False),
        ("10012345000017", "10012345000017", True),
        ("10012345000018", "10012345000018", False),
    ],
)
def test_gtin_lengths_and_check_digits(raw, normalized, valid):
    connection = duckdb.connect(":memory:")
    connection.execute((SQL_DIR / "01_schema.sql").read_text(encoding="utf-8"))
    result = connection.execute(
        "SELECT normalize_gtin14(?, '1'), is_valid_gtin14(normalize_gtin14(?, '1'))",
        [raw, raw],
    ).fetchone()
    assert result == (normalized, valid)


@pytest.mark.parametrize("raw", ["1234567", "123456789", "12345678901", "123456789012345", "ABC"])
def test_invalid_gtin_format_returns_null(raw):
    connection = duckdb.connect(":memory:")
    connection.execute((SQL_DIR / "01_schema.sql").read_text(encoding="utf-8"))
    assert connection.execute("SELECT normalize_gtin14(?, '1')", [raw]).fetchone()[0] is None


def test_restricted_prefix_is_not_global():
    connection = duckdb.connect(":memory:")
    connection.execute((SQL_DIR / "01_schema.sql").read_text(encoding="utf-8"))
    assert connection.execute(
        "SELECT classify_product_code('20000000', true, true)"
    ).fetchone()[0] == "RESTRICTED_LOCAL"
