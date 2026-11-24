"""Registro y sesiones para el bankroll personal."""
import hashlib
import secrets
import sqlite3
import time
from decimal import Decimal
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Response
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from pydantic import BaseModel, Field, SecretStr, StringConstraints

from .apuestas import Identificador, Ruta, transaccion

router = APIRouter(prefix="/auth", tags=["Cuentas"])
Alias = Annotated[str, StringConstraints(strip_whitespace=True, pattern=r"^[a-zA-Z0-9_.-]{3,40}$")]
Portador = Annotated[HTTPAuthorizationCredentials | None, Depends(HTTPBearer(auto_error=False))]
ESQUEMA_HTTP = "bearer"
DURACION_SEGUNDOS = 24 * 60 * 60


class Credenciales(BaseModel):
    alias: Alias
    password: SecretStr = Field(max_length=128)


class Registro(Credenciales):
    password: SecretStr = Field(min_length=8, max_length=128)
    saldo_inicial: Decimal = Field(ge=0, max_digits=10, decimal_places=2)


def derivar(password, sal):
    return hashlib.pbkdf2_hmac("sha256", password.get_secret_value().encode(), sal, 600_000)


def huella(token):
    return hashlib.sha256(token.encode()).digest()


@router.post("/registro", status_code=201)
def registrar(datos: Registro, ruta: Ruta):
    sal = secrets.token_bytes(16)
    clave = derivar(datos.password, sal)
    with transaccion(ruta, escritura=True) as db:
        if db.execute("SELECT 1 FROM cuenta WHERE alias = ?", (datos.alias,)).fetchone():
            raise HTTPException(409, "El alias ya está registrado.")
        usuario_id = db.execute("INSERT INTO bankroll (inicial) VALUES (?)",
                                (int(datos.saldo_inicial * 100),)).lastrowid
        db.execute("INSERT INTO cuenta (usuario_id, alias, sal, clave_derivada) VALUES (?, ?, ?, ?)",
                   (usuario_id, datos.alias, sal, clave))
    return {"usuario_id": usuario_id, "alias": datos.alias}


@router.post("/login")
def iniciar(datos: Credenciales, ruta: Ruta, response: Response):
    with transaccion(ruta) as db:
        cuenta = db.execute("SELECT * FROM cuenta WHERE alias = ?", (datos.alias,)).fetchone()
    # El alias desconocido también pasa por la derivación de contraseña.
    candidato = derivar(datos.password, cuenta["sal"] if cuenta else bytes(16))
    if cuenta is None or not secrets.compare_digest(candidato, cuenta["clave_derivada"]):
        raise HTTPException(401, "Alias o contraseña incorrectos.")
    ahora = int(time.time())
    token = secrets.token_urlsafe(32)
    with transaccion(ruta, escritura=True) as db:
        db.execute("DELETE FROM sesion WHERE vence <= ?", (ahora,))
        db.execute("INSERT INTO sesion (huella, usuario_id, vence) VALUES (?, ?, ?)",
                   (huella(token), cuenta["usuario_id"], ahora + DURACION_SEGUNDOS))
    response.headers["Cache-Control"] = "no-store"
    return {"usuario_id": cuenta["usuario_id"], "alias": cuenta["alias"],
            "access_token": token, "token_type": ESQUEMA_HTTP, "expires_in": DURACION_SEGUNDOS}


def sesion_actual(credencial: Portador, ruta: Ruta):
    if credencial:
        with transaccion(ruta) as db:
            sesion = db.execute("SELECT usuario_id, huella FROM sesion WHERE huella = ? AND vence > ?",
                                (huella(credencial.credentials), int(time.time()))).fetchone()
        if sesion:
            return sesion
    raise HTTPException(401, "Inicia sesión.", headers={"WWW-Authenticate": "Bearer"})


Sesion = Annotated[sqlite3.Row, Depends(sesion_actual)]


def exigir_titular(usuario_id: Identificador, sesion: Sesion):
    if usuario_id != sesion["usuario_id"]:
        raise HTTPException(404, "Recurso inexistente.")


@router.post("/logout", status_code=204)
def cerrar(ruta: Ruta, sesion: Sesion):
    with transaccion(ruta, escritura=True) as db:
        db.execute("DELETE FROM sesion WHERE huella = ?", (sesion["huella"],))
    return Response(status_code=204)
