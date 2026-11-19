"""Foto opcional de cada apuesta en la API de demostración."""
from io import BytesIO

from fastapi import APIRouter, HTTPException, Request, Response
from PIL import Image, UnidentifiedImageError
from starlette.concurrency import run_in_threadpool

from .apuestas import Identificador, Ruta, transaccion

router = APIRouter(prefix="/usuarios/{usuario_id}/apuestas/{apuesta_id}/recuerdo")
MAX_BYTES = 10 * 1024 * 1024
TIPOS = {"JPEG": "image/jpeg", "PNG": "image/png", "WEBP": "image/webp"}


def comprobar_apuesta(db, usuario_id, apuesta_id):
    if not db.execute("SELECT 1 FROM apuesta WHERE usuario_id = ? AND id = ?",
                      (usuario_id, apuesta_id)).fetchone():
        raise HTTPException(404, "Apuesta inexistente.")


@router.get("")
def leer(usuario_id: Identificador, apuesta_id: Identificador, ruta: Ruta):
    with transaccion(ruta) as db:
        comprobar_apuesta(db, usuario_id, apuesta_id)
        fila = db.execute("SELECT tipo, contenido FROM recuerdo WHERE apuesta_id = ?",
                          (apuesta_id,)).fetchone()
        headers = {"Cache-Control": "private, no-store"}
        if not fila:
            return Response(status_code=204, headers=headers)
        return Response(fila["contenido"], media_type=fila["tipo"], headers=headers)


def guardar(ruta, usuario_id, apuesta_id, datos):
    try:
        with Image.open(BytesIO(datos), formats=list(TIPOS)) as imagen:
            tipo = TIPOS[imagen.format]
            if imagen.width * imagen.height > 32_000_000:
                raise HTTPException(413, "La imagen supera los 32 megapíxeles.")
            imagen.verify()
        with Image.open(BytesIO(datos), formats=list(TIPOS)) as imagen:
            imagen.load()
    except (OSError, ValueError, SyntaxError, UnidentifiedImageError, Image.DecompressionBombError) as error:
        raise HTTPException(415, "Elige una imagen JPEG, PNG o WebP válida.") from error
    with transaccion(ruta, escritura=True) as db:
        comprobar_apuesta(db, usuario_id, apuesta_id)
        db.execute("""INSERT INTO recuerdo VALUES (?, ?, ?)
                      ON CONFLICT(apuesta_id) DO UPDATE SET tipo=excluded.tipo,
                      contenido=excluded.contenido""", (apuesta_id, tipo, datos))


@router.put("", status_code=204)
async def adjuntar(usuario_id: Identificador, apuesta_id: Identificador, ruta: Ruta, request: Request):
    datos = bytearray()
    async for bloque in request.stream():
        if len(datos) + len(bloque) > MAX_BYTES:
            raise HTTPException(413, "El tamaño máximo es de 10 MB.")
        datos.extend(bloque)
    await run_in_threadpool(guardar, ruta, usuario_id, apuesta_id, bytes(datos))
    return Response(status_code=204)
