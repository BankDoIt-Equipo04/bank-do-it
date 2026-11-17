
from fastapi import FastAPI

app = FastAPI(
    title="BANKDOIT API",
    version="0.1.0",
    description="Sistema de gestión de apuestas deportivas simuladas"
)

@app.get("/health")
def verificar_estado():
    return {
        "estado": "activo",
        "proyecto": "BANKDOIT",
        "empresa": "ROL Studios"
    }
