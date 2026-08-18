@echo off
setlocal

set "PROJECT_ROOT=%~dp0.."
cd /d "%PROJECT_ROOT%"

set "PYTHON=%PROJECT_ROOT%\.venv\Scripts\python.exe"

if not exist "%PYTHON%" (
    echo ERROR: No se encontro el entorno virtual en:
    echo %PYTHON%
    echo.
    echo Crea el entorno con: python -m venv .venv
    echo Instala el proyecto con: .venv\Scripts\python.exe -m pip install -e ".[dev]"
    pause
    exit /b 1
)

echo ============================================================
echo  Pricing y canasta de supermercado
echo  Pipeline completo: download, ingest, build, export, validate
echo ============================================================
echo.
echo El build puede tardar porque procesa cerca de 97 millones de filas.
echo No cierres esta ventana hasta que finalice.
echo.

"%PYTHON%" -m pricing_canasta.pipeline all

if errorlevel 1 (
    echo.
    echo ERROR: El pipeline no pudo completarse.
    echo Revisa el mensaje mostrado arriba.
    pause
    exit /b 1
)

echo.
echo ============================================================
echo  Pipeline completado correctamente
echo ============================================================
echo.

if exist "%PROJECT_ROOT%\outputs\dashboard_pricing_canasta.html" (
    start "" "%PROJECT_ROOT%\outputs\dashboard_pricing_canasta.html"
)

if exist "%PROJECT_ROOT%\outputs\pricing_canasta_supermercado.xlsx" (
    start "" "%PROJECT_ROOT%\outputs\pricing_canasta_supermercado.xlsx"
)

pause
exit /b 0
