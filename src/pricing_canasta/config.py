import os
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[2]
DATA_DIR = PROJECT_ROOT / "data"
RAW_DIR = DATA_DIR / "raw"
INTERIM_DIR = DATA_DIR / "interim"
MANIFEST_DIR = DATA_DIR / "manifests"
WAREHOUSE_DIR = DATA_DIR / "warehouse"
EXPORT_DIR = DATA_DIR / "exports"
OUTPUT_DIR = PROJECT_ROOT / "outputs"
SITE_DIR = PROJECT_ROOT / "site"
PORTFOLIO_DATA_DIR = PROJECT_ROOT / "portfolio_data"
SQL_DIR = PROJECT_ROOT / "sql"
DATABASE_PATH = WAREHOUSE_DIR / "pricing_v2_strict.duckdb"
PUBLIC_MANIFEST_DIR = PROJECT_ROOT / "manifests"
SCHEMA_VERSION = "2.0.0"
WINDOW_DAYS = 7
DUCKDB_THREADS = int(os.getenv("DUCKDB_THREADS", "4"))
KNOWN_EMPTY_PACKAGE_PATTERN = r"comercio-sepa-36_"

CATALOG_URL = (
    "https://datos.gob.ar/api/3/action/"
    "package_show?id=precios-claros-base-sepa"
)

EXPECTED_COLUMNS = {
    "comercio.csv": [
        "id_comercio",
        "id_bandera",
        "comercio_cuit",
        "comercio_razon_social",
        "comercio_bandera_nombre",
        "comercio_bandera_url",
        "comercio_ultima_actualizacion",
        "comercio_version_sepa",
    ],
    "sucursales.csv": [
        "id_comercio",
        "id_bandera",
        "id_sucursal",
        "sucursales_nombre",
        "sucursales_tipo",
        "sucursales_calle",
        "sucursales_numero",
        "sucursales_latitud",
        "sucursales_longitud",
        "sucursales_observaciones",
        "sucursales_barrio",
        "sucursales_codigo_postal",
        "sucursales_localidad",
        "sucursales_provincia",
        "sucursales_lunes_horario_atencion",
        "sucursales_martes_horario_atencion",
        "sucursales_miercoles_horario_atencion",
        "sucursales_jueves_horario_atencion",
        "sucursales_viernes_horario_atencion",
        "sucursales_sabado_horario_atencion",
        "sucursales_domingo_horario_atencion",
    ],
    "productos.csv": [
        "id_comercio",
        "id_bandera",
        "id_sucursal",
        "id_producto",
        "productos_ean",
        "productos_descripcion",
        "productos_cantidad_presentacion",
        "productos_unidad_medida_presentacion",
        "productos_marca",
        "productos_precio_lista",
        "productos_precio_referencia",
        "productos_cantidad_referencia",
        "productos_unidad_medida_referencia",
        "productos_precio_unitario_promo1",
        "productos_leyenda_promo1",
        "productos_precio_unitario_promo2",
        "productos_leyenda_promo2",
    ],
}


def ensure_directories() -> None:
    for directory in (
        RAW_DIR,
        INTERIM_DIR,
        MANIFEST_DIR,
        WAREHOUSE_DIR,
        EXPORT_DIR,
        OUTPUT_DIR,
        SITE_DIR,
        PORTFOLIO_DATA_DIR,
        PUBLIC_MANIFEST_DIR,
    ):
        directory.mkdir(parents=True, exist_ok=True)
