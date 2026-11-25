
from fastapi import Depends, FastAPI
from fastapi.middleware.cors import CORSMiddleware

from .apuestas import router
from .cuentas import exigir_titular
from .cuentas import router as cuentas
from .movimientos import router as movimientos
from .recuerdos import router as recuerdos

app = FastAPI(
    title="BANKDOIT API",
    version="0.1.0",
    description="Sistema de gestión de apuestas deportivas simuladas"
)

app.add_middleware(
    CORSMiddleware,
    allow_origin_regex=r"http://(localhost|127\.0\.0\.1)(:[0-9]+)?",
    allow_methods=["GET", "POST", "PUT"],
    allow_headers=["Content-Type", "Idempotency-Key", "Authorization"],
)
app.include_router(cuentas)
app.include_router(movimientos, dependencies=[Depends(exigir_titular)])
app.include_router(router, dependencies=[Depends(exigir_titular)])
app.include_router(recuerdos, dependencies=[Depends(exigir_titular)])


@app.get("/health")
def verificar_estado():
    return {
        "estado": "activo",
        "proyecto": "BANKDOIT",
        "empresa": "ROL Studios"
    }
