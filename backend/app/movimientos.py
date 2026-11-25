"""Movimientos del bankroll simulado y límite semanal de la cuenta."""
from decimal import Decimal
from typing import Literal

from fastapi import APIRouter, HTTPException, Response
from pydantic import BaseModel, Field

from .apuestas import (
    CENTAVO,
    Clave,
    Identificador,
    Ruta,
    obtener_saldo,
    presupuesto,
    saldos,
    transaccion,
)

router = APIRouter(prefix="/usuarios/{usuario_id}/bankroll", tags=["Bankroll"])


class Operacion(BaseModel):
    tipo: Literal["aportacion", "retiro"]
    monto: Decimal = Field(gt=0, max_digits=10, decimal_places=2)


class LimiteSemanal(BaseModel):
    limite: Decimal | None = Field(gt=0, max_digits=10, decimal_places=2)


@router.get("/movimientos")
def consultar_movimientos(usuario_id: Identificador, ruta: Ruta):
    with transaccion(ruta) as db:
        saldo = obtener_saldo(db, usuario_id)
        inicial = db.execute("SELECT inicial FROM bankroll WHERE usuario_id = ?", (usuario_id,)).fetchone()[0]
        filas = db.execute("""
            SELECT id, tipo, apuesta_id, creado_en, cambio_disponible, cambio_en_juego
            FROM movimiento WHERE usuario_id = ? ORDER BY id DESC""", (usuario_id,))
        movimientos = []
        ganancia = 0
        for fila in filas:
            movimiento = dict(fila)
            if movimiento["apuesta_id"] is not None:
                ganancia += movimiento["cambio_disponible"] + movimiento["cambio_en_juego"]
            for campo in ("cambio_disponible", "cambio_en_juego"):
                movimiento[campo] = format(movimiento[campo] * CENTAVO, ".2f")
            movimientos.append(movimiento)
        movimientos.append({"id": None, "tipo": "saldo_inicial", "apuesta_id": None,
                            "creado_en": None, "cambio_disponible": format(inicial * CENTAVO, ".2f"),
                            "cambio_en_juego": "0.00"})
        return {"bankroll": saldos(saldo), "ganancia_deportiva": format(ganancia * CENTAVO, ".2f"),
                "presupuesto": presupuesto(db, usuario_id), "movimientos": movimientos}


@router.post("/movimientos", status_code=201)
def registrar_movimiento(usuario_id: Identificador, datos: Operacion, clave: Clave, ruta: Ruta, response: Response):
    cambio = int(datos.monto * 100)
    if datos.tipo == "retiro":
        cambio = -cambio
    with transaccion(ruta, escritura=True) as db:
        previo = db.execute("SELECT id, cambio_disponible FROM movimiento WHERE usuario_id = ? AND clave = ?",
                            (usuario_id, clave)).fetchone()
        if previo:
            if previo["cambio_disponible"] != cambio:
                raise HTTPException(409, "clave_reutilizada")
            response.status_code = 200
            movimiento_id = previo["id"]
        else:
            if datos.tipo == "retiro" and datos.monto > obtener_saldo(db, usuario_id).disponible:
                raise HTTPException(409, "saldo_insuficiente")
            movimiento_id = db.execute("""
                INSERT INTO movimiento (usuario_id, tipo, cambio_disponible, clave)
                VALUES (?, ?, ?, ?)""", (usuario_id, datos.tipo, cambio, clave)).lastrowid
        return {"movimiento_id": movimiento_id, "bankroll": saldos(obtener_saldo(db, usuario_id))}


@router.put("/presupuesto")
def cambiar_limite(usuario_id: Identificador, datos: LimiteSemanal, ruta: Ruta):
    with transaccion(ruta, escritura=True) as db:
        if datos.limite is None:
            db.execute("DELETE FROM presupuesto WHERE usuario_id = ?", (usuario_id,))
        else:
            db.execute("""INSERT INTO presupuesto (usuario_id, limite) VALUES (?, ?)
                          ON CONFLICT(usuario_id) DO UPDATE SET limite = excluded.limite""",
                       (usuario_id, int(datos.limite * 100)))
        return presupuesto(db, usuario_id)
