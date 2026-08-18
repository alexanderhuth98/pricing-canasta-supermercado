import csv
import io
import zipfile
from datetime import date, timedelta
from pathlib import Path

import pytest

from pricing_canasta.config import EXPECTED_COLUMNS

SCOPE = [
    ("10", "1", "Hipermercado Carrefour"),
    ("12", "1", "COTO CICSA"),
    ("11", "2", "Changomas"),
    ("15", "1", "Supermercados DIA"),
    ("2", "1", "La Anonima"),
    ("9", "3", "Jumbo"),
    ("13", "1", "Cooperativa Obrera"),
]

PRODUCTS = [
    ("07790272001029", "ACEITE DE GIRASOL NATURA 1.5 L", 1.5, "L", "NATURA", 1500),
    ("07791120031557", "ARROZ BLANCO ALA 1 KG", 1, "KG", "ALA", 1000),
    ("07792540250450", "AZUCAR BLANCA LEDESMA 1 KG", 1, "KG", "LEDESMA", 1200),
    ("07790550022234", "CAFE TOSTADO MOLIDO CABRALES 250 GR", 250, "GR", "CABRALES", 2000),
    ("07790070320285", "FIDEOS SECOS FAVORITA 500 GR", 500, "GR", "FAVORITA", 700),
    ("07790070562258", "HARINA DE TRIGO 000 FAVORITA 1 KG", 1, "KG", "FAVORITA", 800),
    ("07790742363008", "LECHE ENTERA UHT LA SERENISIMA 1 L", 1, "L", "LA SERENISIMA", 1300),
    ("07792710000182", "YERBA MATE AMANDA TRADICIONAL 500 GR", 500, "GR", "AMANDA", 900),
]


def _csv_bytes(columns: list[str], rows: list[list], header: list[str] | None = None) -> bytes:
    buffer = io.StringIO(newline="")
    writer = csv.writer(buffer, delimiter="|", quotechar='"', lineterminator="\r\n")
    writer.writerow(header or columns)
    writer.writerows(rows)
    buffer.write("\r\nUltima actualizacion: 2026-08-02T04:00:00-03:00\r\n")
    return buffer.getvalue().encode("utf-8")


def _zip_bytes(files: dict[str, bytes]) -> bytes:
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for name in sorted(files):
            info = zipfile.ZipInfo(name, date_time=(2026, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(info, files[name])
    return output.getvalue()


def create_snapshot_zip(
    raw_root: Path,
    snapshot_date: date,
    transform=None,
) -> Path:
    date_dir = raw_root / snapshot_date.isoformat()
    date_dir.mkdir(parents=True, exist_ok=True)
    outer_path = date_dir / f"sepa_{snapshot_date:%Y%m%d}.zip"
    chain_factors = [0.94, 0.96, 0.98, 1.00, 1.02, 1.04, 1.06]
    packages = {}

    for chain_index, ((commerce_id, banner_id, banner_name), factor) in enumerate(
        zip(SCOPE, chain_factors, strict=False), start=1
    ):
        commerce_rows = [[
            commerce_id, banner_id, f"30{chain_index:09d}9", banner_name,
            banner_name, "https://example.test", f"{snapshot_date}T04:00:00-03:00", "1.0",
        ]]
        store_rows = []
        product_rows = []
        for store_number in range(1, 21):
            store_id = str(store_number)
            store_rows.append([
                commerce_id, banner_id, store_id, f"Sucursal {store_number}", "Supermercado",
                "Calle", str(100 + store_number), "-34.60", "-58.40", "", "Centro",
                "1000", "CABA", "AR-C", "08:00-20:00", "08:00-20:00",
                "08:00-20:00", "08:00-20:00", "08:00-20:00", "08:00-20:00",
                "08:00-20:00",
            ])
            for product_id, description, quantity, unit, brand, base_price in PRODUCTS:
                daily_factor = 1 + (snapshot_date.day % 3 - 1) * 0.005
                price = round(base_price * factor * daily_factor, 2)
                product_rows.append([
                    commerce_id, banner_id, store_id, product_id, "1", description,
                    quantity, unit, brand, price, price, quantity, unit, "", "", "", "",
                ])

        files = {
            "comercio.csv": _csv_bytes(EXPECTED_COLUMNS["comercio.csv"], commerce_rows),
            "sucursales.csv": _csv_bytes(EXPECTED_COLUMNS["sucursales.csv"], store_rows),
            "productos.csv": _csv_bytes(EXPECTED_COLUMNS["productos.csv"], product_rows),
        }
        if transform:
            files = transform(chain_index, files)
        package_name = (
            f"sepa_1_comercio-sepa-{commerce_id}_{snapshot_date.isoformat()}_09-05-10.zip"
        )
        packages[f"{snapshot_date.isoformat()}/{package_name}"] = _zip_bytes(files)

    with zipfile.ZipFile(outer_path, "w", compression=zipfile.ZIP_STORED) as outer:
        for name in sorted(packages):
            info = zipfile.ZipInfo(name, date_time=(2026, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_STORED
            outer.writestr(info, packages[name])
    return outer_path


@pytest.fixture
def fixture_raw(tmp_path):
    raw_root = tmp_path / "raw"
    start = date(2026, 7, 27)
    archives = [create_snapshot_zip(raw_root, start + timedelta(days=offset)) for offset in range(7)]
    return raw_root, archives
