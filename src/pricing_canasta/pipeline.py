import argparse
from datetime import date

from .build import build_analytics
from .download import download_all
from .export import export_all
from .ingest import ingest_all
from .validate import validate


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Pipeline de pricing y canasta con Precios Claros SEPA."
    )
    parser.add_argument(
        "stage",
        choices=["download", "ingest", "build", "export", "validate", "all"],
        help="Etapa que se desea ejecutar.",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="Reconstruye snapshots previamente ingeridos.",
    )
    parser.add_argument(
        "--as-of",
        type=date.fromisoformat,
        help="Fecha de corte reproducible en formato YYYY-MM-DD.",
    )
    parser.add_argument(
        "--only-snapshot",
        type=date.fromisoformat,
        help="Limita la ingestion a un snapshot YYYY-MM-DD.",
    )
    arguments = parser.parse_args()

    if arguments.stage in ("download", "all"):
        download_all()
    if arguments.stage in ("ingest", "all"):
        ingest_all(
            force=arguments.force,
            as_of=arguments.as_of,
            only_snapshot=arguments.only_snapshot,
        )
    if arguments.stage in ("build", "all"):
        build_analytics(as_of=arguments.as_of)
    if arguments.stage == "validate":
        validate()
    if arguments.stage in ("export", "all"):
        export_all()


if __name__ == "__main__":
    main()
