"""Conteos públicos del último corte analítico para usuarios autenticados."""
import os

from fastapi import APIRouter, HTTPException
from pymongo import MongoClient
from pymongo.errors import PyMongoError

router = APIRouter(tags=["Resultados"])


@router.get("/resultados/globales")
def resultados_globales():
    campos = {"_id": 0, "corte_utc": 1, "auditoria.validas": 1,
              "por_deporte.deporte": 1, "por_deporte.apuestas": 1,
              "por_partido.partido_id": 1, "por_partido.apuestas": 1}
    try:
        with MongoClient(os.getenv("MONGODB_URI", "mongodb://127.0.0.1:27017"),
                         tz_aware=True, serverSelectionTimeoutMS=3000) as cliente:
            corte = cliente.bankdoit_analytics.resumenes.find_one(
                {}, campos, sort=[("corte_utc", -1), ("_id", -1)])
    except PyMongoError as error:
        raise HTTPException(503, "MongoDB no está disponible.") from error
    if corte is None:
        return {"corte_utc": None, "total_apuestas": 0, "por_deporte": [], "por_partido": []}
    if "por_partido" not in corte:
        raise HTTPException(503, "Ejecuta analytics/procesar.py para preparar los conteos.")
    return {"corte_utc": corte["corte_utc"], "total_apuestas": corte["auditoria"]["validas"],
            "por_deporte": corte["por_deporte"], "por_partido": corte["por_partido"]}
