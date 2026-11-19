"""Desde backend: python -m tests.servidor_flutter (base temporal para la prueba #10)."""
from pathlib import Path
from tempfile import TemporaryDirectory

import uvicorn

from app.datos_demo import preparar, ruta_demo
from app.main import app

if __name__ == "__main__":
    with TemporaryDirectory() as directorio:
        ruta = Path(directorio) / "prueba.sqlite3"
        preparar(ruta)
        app.dependency_overrides[ruta_demo] = lambda: ruta
        uvicorn.run(app, host="127.0.0.1", port=18810)
