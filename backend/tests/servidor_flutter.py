"""Desde backend: python -m tests.servidor_flutter (base temporal para la prueba #10)."""
import sqlite3
from pathlib import Path
from tempfile import TemporaryDirectory

import uvicorn

from app.datos_demo import preparar, ruta_demo
from app.main import app

if __name__ == "__main__":
    with TemporaryDirectory() as directorio:
        ruta = Path(directorio) / "prueba.sqlite3"
        preparar(ruta)
        # Las cuentas nuevas de esta prueba usan el presupuesto del escenario #10.
        with sqlite3.connect(ruta) as db:
            db.execute("""CREATE TRIGGER presupuesto_de_prueba AFTER INSERT ON bankroll
                          BEGIN INSERT INTO presupuesto(usuario_id, limite)
                          VALUES (NEW.usuario_id, 50000); END""")
        app.dependency_overrides[ruta_demo] = lambda: ruta
        uvicorn.run(app, host="127.0.0.1", port=18810)
