"""Inicia la API distribuida con la configuración local de Docker."""
import argparse
import os
from pathlib import Path

import uvicorn
from psycopg.conninfo import make_conninfo

CARPETA = Path(__file__).resolve().parents[1] / "database" / "distribuido"


def configurar():
    cfg = {}
    for linea in (CARPETA / ".env").read_text(encoding="utf-8-sig").splitlines():
        if "=" in linea and not linea.lstrip().startswith("#"):
            nombre, valor = linea.split("=", 1)
            cfg[nombre.strip()] = valor.strip()

    def valor(nombre, omision):
        return os.environ.get(nombre) or cfg.get(nombre) or omision

    for nodo, puerto, variable in [("IMPAR", 5441, "PUERTO_A_PRIMARIO"), ("PAR", 5451, "PUERTO_B_PRIMARIO")]:
        os.environ.setdefault(f"BANKDOIT_PG_{nodo}_DSN", make_conninfo(
            host=valor("BANKDOIT_PG_HOST", "localhost"),
            hostaddr=valor("BANKDOIT_PG_HOSTADDR", "127.0.0.1"),
            port=valor(variable, puerto), dbname=valor("POSTGRES_DB", "bankdoit"),
            user="bankdoit_api", sslmode="verify-full", sslrootcert=(CARPETA / "certs/ca.crt").as_posix(),
        ))
    os.environ.setdefault("BANKDOIT_PG_PASSWORD", cfg["BANKDOIT_API_PASSWORD"])
    os.environ["BANKDOIT_BACKEND"] = "postgres"


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--probar", action="store_true", help="Comprueba el issue 33 con dos cuentas nuevas")
    args = parser.parse_args()
    configurar()
    if args.probar:
        import pytest

        archivo = Path(__file__).parent / "tests" / "test_postgres_integracion.py"
        raise SystemExit(pytest.main(["-q", str(archivo)]))
    uvicorn.run("app.main:app", host="127.0.0.1", port=8000)
