"""Genera un resumen reproducible del CSV de apuestas y lo guarda en MongoDB."""
import argparse
import hashlib
import io
import json
import os
from datetime import datetime, timezone
from pathlib import Path

import pandas as pd
from pymongo import MongoClient

CSV = Path(__file__).parent / "datos" / "BANKDOIT_apuestas_100000.csv"
ESTADOS = ("pendiente", "ganada", "perdida", "anulada")


def centesimas(serie, enteros):
    """Acepta la precisión del esquema PostgreSQL y convierte a enteros exactos."""
    patron = rf"[0-9]{{1,{enteros}}}(?:\.[0-9]{{1,2}})?"
    texto = serie.where(serie.str.fullmatch(patron), "").str.partition(".")
    unidad = pd.to_numeric(texto[0], errors="coerce").astype("Int64")
    fraccion = pd.to_numeric(texto[2].str.pad(2, side="right", fillchar="0"))
    return unidad * 100 + fraccion


def resumir(contenido):
    datos = pd.read_csv(io.BytesIO(contenido), dtype="string", keep_default_na=False, encoding="utf-8-sig")
    requeridas = {"apuesta_id", "usuario_id", "clave_operacion", "partido_id", "deporte",
                  "monto", "cuota", "estado", "registrada_en", "resuelta_en"}
    faltan = requeridas.difference(datos.columns)
    if faltan:
        raise ValueError("Faltan columnas: " + ", ".join(sorted(faltan)))
    auditoria = {"leidas": len(datos)}

    def descartar(mascara, motivo):
        nonlocal datos
        auditoria[motivo] = int(mascara.sum())
        datos = datos.loc[~mascara].copy()

    descartar(datos.duplicated(), "duplicadas_exactas")
    # Si dos versiones difieren para la misma apuesta, ninguna es autoritativa.
    descartar(datos.duplicated("apuesta_id", keep=False) |
              datos.duplicated(["usuario_id", "clave_operacion"], keep=False), "claves_en_conflicto")
    datos["centavos"] = centesimas(datos["monto"], 8)
    descartar(~datos.centavos.gt(0).fillna(False), "montos_invalidos")
    cuotas = centesimas(datos["cuota"], 4)
    descartar(~cuotas.gt(100).fillna(False), "cuotas_invalidas")
    descartar(~datos.estado.isin(ESTADOS), "estados_invalidos")
    registro = pd.to_datetime(datos.registrada_en, errors="coerce", utc=True, format="ISO8601")
    resolucion = pd.to_datetime(datos.resuelta_en, errors="coerce", utc=True, format="ISO8601")
    pendiente = datos.estado.eq("pendiente")
    descartar(registro.isna() | (pendiente & datos.resuelta_en.ne("")) |
              (~pendiente & (resolucion.isna() | resolucion.lt(registro))), "fechas_invalidas")
    auditoria["validas"] = len(datos)
    resumenes = []
    for deporte, grupo in datos.groupby("deporte", sort=True):
        resumenes.append({"deporte": deporte, "apuestas": len(grupo),
                          "monto_centavos": int(grupo.centavos.sum()),
                          "por_estado": {e: int(grupo.estado.eq(e).sum()) for e in ESTADOS}})
    return {"auditoria": auditoria, "por_deporte": resumenes}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--csv", type=Path, default=CSV)
    parser.add_argument("--solo-validar", action="store_true")
    args = parser.parse_args()
    contenido = args.csv.read_bytes()
    resumen = resumir(contenido)
    print(json.dumps(resumen, indent=2, ensure_ascii=False))
    if args.solo_validar:
        return
    # Una publicación atómica por archivo. Reprocesarlo conserva su primer corte.
    identificador = hashlib.sha256(contenido).hexdigest()
    with MongoClient(os.getenv("MONGODB_URI", "mongodb://127.0.0.1:27017"),
                     serverSelectionTimeoutMS=10000) as cliente:
        coleccion = cliente.bankdoit_analytics.resumenes
        coleccion.update_one({"_id": identificador}, {
            "$set": {**resumen, "archivo": args.csv.name},
            "$setOnInsert": {"corte_utc": datetime.now(timezone.utc)}}, upsert=True)
    print("Resumen guardado en bankdoit_analytics.resumenes:", identificador)


if __name__ == "__main__":
    main()
