
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from .apuestas import router

app = FastAPI(
    title="BANKDOIT API",
    version="0.1.0",
    description="Sistema de gestión de apuestas deportivas simuladas"
)

app.add_middleware(
    CORSMiddleware,
    allow_origin_regex=r"http://(localhost|127\.0\.0\.1)(:[0-9]+)?",
    allow_methods=["GET", "POST", "PUT"],
    allow_headers=["Content-Type", "Idempotency-Key"],
)
app.include_router(router)


@app.get("/health")
def verificar_estado():
    return {
        "estado": "activo",
        "proyecto": "BANKDOIT",
        "empresa": "ROL Studios"
    }
