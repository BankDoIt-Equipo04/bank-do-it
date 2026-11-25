import sqlite3
from contextlib import closing, contextmanager
from decimal import ROUND_HALF_UP, Decimal
from pathlib import Path
from typing import Annotated, Literal

from fastapi import APIRouter, Depends, Header, HTTPException, Response
from fastapi import Path as PathParam
from pydantic import BaseModel, Field, StringConstraints

from .bankroll import Bankroll, SaldoInsuficienteError
from .datos_demo import ruta_demo

router = APIRouter(prefix="/usuarios/{usuario_id}", tags=["Apuestas"])
Identificador = Annotated[int, PathParam(gt=0, le=2**63 - 1)]
Ruta = Annotated[Path, Depends(ruta_demo)]
Clave = Annotated[str, Header(alias="Idempotency-Key", min_length=1, max_length=128,
                              pattern=r"^[!-~]+$")]
Resultado = Literal["ganada", "perdida", "anulada"]
CENTAVO = Decimal("0.01")


class NuevaApuesta(BaseModel):
    # Opcional para mantener el contrato de los clientes anteriores.
    exceso_aceptado: Decimal | None = Field(default=None, ge=0, decimal_places=2)
    partido_id: int = Field(gt=0, le=2**63 - 1)
    seleccion: Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=180)]
    monto: Decimal = Field(gt=0, max_digits=10, decimal_places=2)
    cuota: Decimal = Field(gt=1, max_digits=6, decimal_places=2)


class Resolucion(BaseModel):
    resultado: Resultado


@contextmanager
def transaccion(ruta: Path, *, escritura: bool = False):
    if not ruta.is_file():
        raise HTTPException(503, "Primero ejecuta python -m app.datos_demo.")
    with closing(sqlite3.connect(ruta, timeout=5)) as db:
        db.row_factory = sqlite3.Row
        db.execute("PRAGMA foreign_keys = ON")
        try:
            with db:
                db.execute("BEGIN IMMEDIATE" if escritura else "BEGIN")
                yield db
        except sqlite3.OperationalError as error:
            if error.sqlite_errorcode in (sqlite3.SQLITE_BUSY, sqlite3.SQLITE_LOCKED):
                raise HTTPException(503, "Base ocupada. Reintenta con la misma clave.") from error
            raise


def obtener_saldo(db, usuario_id):
    fila = db.execute("""
        SELECT b.inicial + COALESCE(SUM(m.cambio_disponible), 0) AS disponible,
               COALESCE(SUM(m.cambio_en_juego), 0) AS en_juego
        FROM bankroll b LEFT JOIN movimiento m ON m.usuario_id = b.usuario_id
        WHERE b.usuario_id = ? GROUP BY b.usuario_id
    """, (usuario_id,)).fetchone()
    if fila is None:
        raise HTTPException(404, "Usuario sin bankroll.")
    return Bankroll(Decimal(fila["disponible"]) * CENTAVO, Decimal(fila["en_juego"]) * CENTAVO)


def saldos(saldo):
    return {"disponible": format(saldo.disponible, ".2f"), "en_juego": format(saldo.en_juego, ".2f")}


def respuesta(db, usuario_id, apuesta_id):
    fila = db.execute("SELECT id, partido_id, seleccion, monto, cuota, estado FROM apuesta "
                      "WHERE usuario_id = ? AND id = ?", (usuario_id, apuesta_id)).fetchone()
    apuesta = dict(fila)
    apuesta["monto"] = format(Decimal(fila["monto"]) * CENTAVO, ".2f")
    return {"apuesta": apuesta, "bankroll": saldos(obtener_saldo(db, usuario_id))}


CATALOGO_DEMO = {
    42: ("Fútbol", "Chivas", "América"),
    101: ("Fútbol", "América", "Chivas"),
    202: ("Fútbol americano", "Chiefs", "Eagles"),
}


def presupuesto(db, usuario_id):
    # Semana del servidor local, de lunes a domingo (incluye apuestas resueltas).
    limite = db.execute("SELECT limite FROM presupuesto WHERE usuario_id = ?",
                        (usuario_id,)).fetchone()
    usado = db.execute("""
        SELECT COALESCE(SUM(monto), 0) FROM apuesta
        WHERE usuario_id = ? AND date(creada, 'localtime') >=
              date('now', 'localtime', '-6 days', 'weekday 1')
    """, (usuario_id,)).fetchone()[0]
    return {"limite_centavos": limite[0] if limite else None, "usado_centavos": usado}


@router.get("/historial")
def historial(usuario_id: Identificador, ruta: Ruta):
    with transaccion(ruta) as db:
        saldo = saldos(obtener_saldo(db, usuario_id))
        filas = db.execute("SELECT id, partido_id, seleccion, monto, cuota, estado FROM apuesta "
                           "WHERE usuario_id = ? ORDER BY id DESC", (usuario_id,))
        apuestas = [dict(row) | {"monto": format(Decimal(row["monto"]) * CENTAVO, ".2f")}
                    for row in filas]
        partidos = [{"id": i, "deporte": deporte, "local": local, "visitante": visitante}
                    for i, (deporte, local, visitante) in CATALOGO_DEMO.items()]
        return {"bankroll": saldo, "presupuesto": presupuesto(db, usuario_id),
                "apuestas": apuestas, "partidos": partidos}


@router.get("/bankroll")
def consultar(usuario_id: Identificador, ruta: Ruta):
    with transaccion(ruta) as db:
        return saldos(obtener_saldo(db, usuario_id))


@router.post("/apuestas", status_code=201)
def registrar(usuario_id: Identificador, datos: NuevaApuesta, clave: Clave, ruta: Ruta, response: Response):
    monto = int(datos.monto * 100)
    cuota = format(datos.cuota, ".2f")
    with transaccion(ruta, escritura=True) as db:
        previa = db.execute("SELECT * FROM apuesta WHERE usuario_id = ? AND clave = ?",
                            (usuario_id, clave)).fetchone()
        if previa:
            original = (previa["partido_id"], previa["seleccion"], previa["monto"], previa["cuota"])
            if original != (datos.partido_id, datos.seleccion, monto, cuota):
                raise HTTPException(409, "clave_reutilizada")
            response.status_code = 200
            return respuesta(db, usuario_id, previa["id"])

        saldo = obtener_saldo(db, usuario_id)
        if not db.execute("SELECT 1 FROM partido WHERE id = ?", (datos.partido_id,)).fetchone():
            raise HTTPException(404, "Partido inexistente.")
        try:
            saldo.reservar(datos.monto)
        except SaldoInsuficienteError as error:
            raise HTTPException(409, "saldo_insuficiente") from error
        if datos.exceso_aceptado is not None:
            semana = presupuesto(db, usuario_id)
            limite = semana["limite_centavos"]
            if limite is not None:
                exceso = semana["usado_centavos"] + monto - limite
                if exceso > int(datos.exceso_aceptado * 100):
                    raise HTTPException(409, {"exceso_centavos": exceso})
        apuesta_id = db.execute("""
            INSERT INTO apuesta (usuario_id, clave, partido_id, seleccion, monto, cuota, estado, creada)
            VALUES (?, ?, ?, ?, ?, ?, 'pendiente', CURRENT_TIMESTAMP)
        """, (usuario_id, clave, datos.partido_id, datos.seleccion, monto, cuota)).lastrowid
        db.execute("""INSERT INTO movimiento (usuario_id, apuesta_id, tipo, cambio_disponible, cambio_en_juego)
                      VALUES (?, ?, 'reserva', ?, ?)""", (usuario_id, apuesta_id, -monto, monto))
        return respuesta(db, usuario_id, apuesta_id)


@router.put("/apuestas/{apuesta_id}/resultado")
def resolver(usuario_id: Identificador, apuesta_id: Identificador, datos: Resolucion, ruta: Ruta):
    with transaccion(ruta, escritura=True) as db:
        fila = db.execute("SELECT estado, monto, cuota FROM apuesta WHERE usuario_id = ? AND id = ?",
                          (usuario_id, apuesta_id)).fetchone()
        if fila is None:
            raise HTTPException(404, "Apuesta inexistente.")
        if fila["estado"] == datos.resultado:
            return respuesta(db, usuario_id, apuesta_id)
        if fila["estado"] != "pendiente":
            raise HTTPException(409, "resultado_en_conflicto")

        monto = fila["monto"]  # Centavos.
        retorno = 0
        if datos.resultado == "ganada":
            retorno = int((monto * Decimal(fila["cuota"])).to_integral_value(rounding=ROUND_HALF_UP))
        elif datos.resultado == "anulada":
            retorno = monto
        db.execute("UPDATE apuesta SET estado = ? WHERE id = ?", (datos.resultado, apuesta_id))
        db.execute("""INSERT INTO movimiento (usuario_id, apuesta_id, tipo, cambio_disponible, cambio_en_juego)
                      VALUES (?, ?, 'liquidacion', ?, ?)""", (usuario_id, apuesta_id, retorno, -monto))
        return respuesta(db, usuario_id, apuesta_id)
