import duckdb
import pytest


def test_dispersion_formula_p10_median_p90():
    connection = duckdb.connect(":memory:")
    values = [(80,)] * 5 + [(120,)] * 5
    connection.execute("CREATE TABLE prices(value DOUBLE)")
    connection.executemany("INSERT INTO prices VALUES (?)", values)
    p10, median, p90, dispersion = connection.execute(
        """
        SELECT quantile_cont(value, 0.10), median(value), quantile_cont(value, 0.90),
               (quantile_cont(value, 0.90) - quantile_cont(value, 0.10)) / median(value)
        FROM prices
        """
    ).fetchone()
    assert (p10, median, p90) == (80, 100, 120)
    assert dispersion == pytest.approx(0.4)


def test_equal_weight_geometric_index_centers_at_100():
    connection = duckdb.connect(":memory:")
    indexes = connection.execute(
        """
        WITH prices(chain, product, price) AS (
            VALUES ('A','X',80.0), ('A','Y',40.0),
                   ('B','X',120.0), ('B','Y',60.0)
        ), benchmark AS (
            SELECT product, exp(avg(ln(price))) AS benchmark
            FROM prices GROUP BY product
        ), chain_index AS (
            SELECT chain, 100 * exp(avg(ln(price / benchmark))) AS price_index
            FROM prices JOIN benchmark USING (product) GROUP BY chain
        )
        SELECT chain, price_index,
               100 * exp(avg(ln(price_index / 100)) OVER ()) AS center
        FROM chain_index ORDER BY chain
        """
    ).fetchall()
    assert indexes[0][1] == pytest.approx(81.6497, rel=0.001)
    assert indexes[1][1] == pytest.approx(122.4745, rel=0.001)
    assert all(row[2] == pytest.approx(100) for row in indexes)
