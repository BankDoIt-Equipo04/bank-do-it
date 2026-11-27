"""Cuentas y apuestas del entorno distribuido (#33)."""
import hashlib
import os
import secrets
from contextlib import contextmanager
from datetime import UTC, datetime, timedelta
from typing import Annotated

import psycopg
from fastapi import APIRouter, Depends, HTTPException, Response
from psycopg.rows import dict_row
from pydantic import AwareDatetime, BaseModel, Field

from .apuestas import (
    Clave,
    Identificador,
    NuevaApuesta,
    Origen,
    Resolucion,
    filtrar_apuestas,
)
from .cuentas import (
    DURACION_SEGUNDOS,
    ESQUEMA_HTTP,
    Credenciales,
    Portador,
    Registro,
    derivar,
    huella,
)
from .resultados import resultados_personales

cuentas_pg = APIRouter(prefix="/auth", tags=["Cuentas"])
admin_pg = APIRouter(prefix="/admin", tags=["Administración"])
ERRORES = {
    "partido_duplicado": 409, "equipos_invalidos": 422,
    "administrador_requerido": 403, "sesion_invalida": 401,
    "alias_duplicado": 409, "cuenta_no_activa": 403, "usuario_inexistente": 404,
    "apuesta_inexistente": 404, "partido_inexistente": 404, "partido_no_disponible": 409,
    "saldo_insuficiente": 409, "clave_reutilizada": 409, "resultado_en_conflicto": 409,
}


@contextmanager
def conexion(usuario_id=None):
    nodo = "PAR" if usuario_id is not None and usuario_id % 2 == 0 else "IMPAR"
    dsn = os.environ.get(f"BANKDOIT_PG_{nodo}_DSN")
    if usuario_id is None:
        dsn = os.environ.get("BANKDOIT_PG_DIRECTORIO_DSN") or dsn
    if not dsn:
        raise HTTPException(503, "Falta configurar la conexión a PostgreSQL.")
    try:
        with psycopg.connect(dsn, password=os.environ.get("BANKDOIT_PG_PASSWORD"),
                             row_factory=dict_row, connect_timeout=5) as db:
            yield db
    except psycopg.errors.RaiseException as error:
        mensaje = error.diag.message_primary
        if mensaje not in ERRORES:
            raise
        raise HTTPException(ERRORES[mensaje], mensaje) from error
    except psycopg.OperationalError as error:
        raise HTTPException(503, "PostgreSQL no está disponible.") from error


@cuentas_pg.post("/registro", status_code=201)
def registrar(datos: Registro):
    sal = secrets.token_bytes(16)
    clave = derivar(datos.password, sal)
    with conexion() as db:
        try:
            with db.transaction():
                uid = db.execute("SELECT registrar_cuenta(%s,%s,%s) AS id",
                                 (datos.alias, sal, clave)).fetchone()["id"]
            alias = datos.alias
        except psycopg.errors.RaiseException as error:
            if error.diag.message_primary != "alias_duplicado":
                raise
            cuenta = db.execute("SELECT * FROM buscar_cuenta(%s)", (datos.alias,)).fetchone()
            if (cuenta["estado"] != "pendiente" or not secrets.compare_digest(
                    derivar(datos.password, cuenta["sal"]), cuenta["clave_derivada"])):
                raise HTTPException(409, "El alias ya está registrado.") from error
            uid, alias = cuenta["usuario_id"], cuenta["alias"]
            clave = cuenta["clave_derivada"]
    with conexion(uid) as db:
        marca = hashlib.sha256(clave).hexdigest()
        db.execute("SELECT asegurar_usuario_api(%s,%s,%s,%s)", (uid, alias, marca, datos.saldo_inicial))
    with conexion() as db:
        db.execute("SELECT activar_cuenta(%s)", (uid,))
    return {"usuario_id": uid, "alias": alias}


@cuentas_pg.post("/login")
def iniciar(datos: Credenciales, response: Response):
    with conexion() as db:
        cuenta = db.execute("SELECT * FROM buscar_cuenta(%s)", (datos.alias,)).fetchone()
        candidato = derivar(datos.password, cuenta["sal"] if cuenta else bytes(16))
        if not cuenta or not secrets.compare_digest(candidato, cuenta["clave_derivada"]):
            raise HTTPException(401, "Alias o contraseña incorrectos.")
        token = secrets.token_urlsafe(32)
        vence = datetime.now(UTC) + timedelta(seconds=DURACION_SEGUNDOS)
        db.execute("SELECT crear_sesion(%s,%s,%s)", (huella(token), cuenta["usuario_id"], vence))
    response.headers["Cache-Control"] = "no-store"
    return {"usuario_id": cuenta["usuario_id"], "alias": cuenta["alias"], "access_token": token,
            "token_type": ESQUEMA_HTTP, "expires_in": DURACION_SEGUNDOS}


def sesion(credencial: Portador):
    if credencial:
        digest = huella(credencial.credentials)
        with conexion() as db:
            uid = db.execute("SELECT validar_sesion(%s) AS id", (digest,)).fetchone()["id"]
        if uid is not None:
            return uid, digest
    raise HTTPException(401, "Inicia sesión.", headers={"WWW-Authenticate": "Bearer"})


SesionPG = Annotated[tuple, Depends(sesion)]


@admin_pg.get("/cuentas")
def listar_cuentas(actual: SesionPG):
    with conexion() as db:
        return db.execute("SELECT alias, estado FROM listar_cuentas_admin(%s)", (actual[1],)).fetchall()


class NuevoPartido(BaseModel):
    deporte_id: int = Field(gt=0, le=32767)
    equipo_local_id: int = Field(gt=0, le=2**63 - 1)
    equipo_visitante_id: int = Field(gt=0, le=2**63 - 1)
    fecha_hora: AwareDatetime


@admin_pg.post("/partidos", status_code=201)
def crear_partido(datos: NuevoPartido, actual: SesionPG):
    with conexion() as db:
        return db.execute(
            "SELECT crear_partido_admin(%s,%s::smallint,%s,%s,%s) AS partido_id",
            (actual[1], datos.deporte_id, datos.equipo_local_id, datos.equipo_visitante_id, datos.fecha_hora),
        ).fetchone()


@cuentas_pg.post("/logout", status_code=204)
def cerrar(actual: SesionPG):
    with conexion() as db:
        db.execute("SELECT cerrar_sesion(%s)", (actual[1],))
    return Response(status_code=204)


def titular(usuario_id: Identificador, actual: SesionPG):
    if actual[0] != usuario_id:
        raise HTTPException(404, "Recurso inexistente.")


apuestas_pg = APIRouter(prefix="/usuarios/{usuario_id}", tags=["Apuestas"],
                        dependencies=[Depends(titular)])


def historial_db(db, uid):
    return db.execute("SELECT consultar_historial(%s) AS historial", (uid,)).fetchone()["historial"]


@apuestas_pg.get("/historial")
def historial(usuario_id: Identificador, origen: Origen | None = None, deporte: str | None = None):
    with conexion(usuario_id) as db:
        actual = historial_db(db, usuario_id)
        actual["apuestas"] = filtrar_apuestas(actual["apuestas"], actual["partidos"], origen, deporte)
        return actual


@apuestas_pg.get("/bankroll")
def consultar(usuario_id: Identificador):
    with conexion(usuario_id) as db:
        saldo = db.execute("SELECT * FROM consultar_bankroll(%s)", (usuario_id,)).fetchone()
        return {"disponible": format(saldo["saldo_disponible"], ".2f"),
                "en_juego": format(saldo["monto_en_juego"], ".2f")}


def respuesta(historial, apuesta_id):
    apuesta = next(a for a in historial["apuestas"] if a["id"] == apuesta_id)
    return {"apuesta": apuesta, "bankroll": historial["bankroll"]}


@apuestas_pg.post("/apuestas", status_code=201)
def apostar(usuario_id: Identificador, datos: NuevaApuesta, clave: Clave, response: Response):
    with conexion(usuario_id) as db:
        fila = db.execute("SELECT * FROM registrar_apuesta(%s,%s,%s,%s,%s,%s,%s)",
                          (usuario_id, clave, datos.partido_id, datos.seleccion,
                           datos.monto, datos.cuota, datos.origen)).fetchone()
        actual = historial_db(db, usuario_id)
        resultado = respuesta(actual, fila["apuesta_id"])
        if fila["es_reenvio"]:
            if resultado["apuesta"]["origen"] != datos.origen:
                raise HTTPException(409, "clave_reutilizada")
            response.status_code = 200
        elif datos.exceso_aceptado is not None:
            presupuesto = actual["presupuesto"]
            limite = presupuesto["limite_centavos"]
            if limite is not None:
                exceso = presupuesto["usado_centavos"] - limite
                if exceso > datos.exceso_aceptado * 100:
                    raise HTTPException(409, {"exceso_centavos": exceso})
        return resultado


@apuestas_pg.put("/apuestas/{apuesta_id}/resultado")
def resolver(usuario_id: Identificador, apuesta_id: Identificador, datos: Resolucion):
    with conexion(usuario_id) as db:
        db.execute("SELECT * FROM resolver_apuesta(%s,%s,%s)", (usuario_id, apuesta_id, datos.resultado))
        return respuesta(historial_db(db, usuario_id), apuesta_id)


@apuestas_pg.get("/resultados")
def mis_resultados(usuario_id: Identificador):
    with conexion(usuario_id) as db:
        filas = db.execute("SELECT * FROM movimientos_resultados(%s) ORDER BY movimiento_id", (usuario_id,))
        return resultados_personales(filas)
