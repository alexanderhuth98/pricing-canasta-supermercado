import io

import pytest

from pricing_canasta.ingest import SchemaContractError, sanitize_csv, validate_header

EXPECTED = ["id", "value"]


def test_sanitize_accepts_bom_and_removes_only_final_footer(tmp_path):
    source = io.BytesIO(
        b"\xef\xbb\xbfid|value\r\n1|ok\x00\r\n   \r\n2|also_ok\n\nUltima actualizacion: now\n"
    )
    destination = tmp_path / "clean.csv"
    metrics = sanitize_csv(source, destination, EXPECTED)
    assert destination.read_text(encoding="utf-8") == "id|value\n1|ok\n2|also_ok\n"
    assert metrics == {
        "source_rows": 2,
        "footer_rows": 1,
        "null_bytes_removed": 1,
        "reconstructed_lines": 0,
    }


def test_documented_wrapped_record_is_reconstructed_and_counted(tmp_path):
    source = io.BytesIO(b"a|b|c|d\n1|2\n|3\n|4\nUltima actualizacion: now\n")
    destination = tmp_path / "wrapped.csv"
    metrics = sanitize_csv(source, destination, ["a", "b", "c", "d"])
    assert destination.read_text(encoding="utf-8") == "a|b|c|d\n1|2|3|4\n"
    assert metrics["reconstructed_lines"] == 2


@pytest.mark.parametrize(
    "header",
    [
        b"value|id\n",
        b"id\n",
        b"id|value|extra\n",
        b"id|id\n",
    ],
)
def test_header_order_count_and_names_are_strict(header):
    with pytest.raises(SchemaContractError):
        validate_header(header, EXPECTED)


def test_empty_and_header_only_csv_fail(tmp_path):
    with pytest.raises(SchemaContractError):
        sanitize_csv(io.BytesIO(b""), tmp_path / "empty.csv", EXPECTED)
    with pytest.raises(SchemaContractError):
        sanitize_csv(io.BytesIO(b"id|value\n"), tmp_path / "header.csv", EXPECTED)


def test_footer_detection_does_not_swallow_arbitrary_text(tmp_path):
    source = io.BytesIO(b"id|value\n1|ok\nactualizacion pendiente\n")
    destination = tmp_path / "not_a_footer.csv"
    metrics = sanitize_csv(source, destination, EXPECTED)
    assert metrics["footer_rows"] == 0
    assert destination.read_text(encoding="utf-8").endswith("actualizacion pendiente\n")
