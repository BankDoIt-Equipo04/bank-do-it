"""Base local reproducible para probar la API con datos simulados."""
from contextlib import closing
from pathlib import Path
import sqlite3


def ruta_demo() -> Path:
    return Path(__file__).resolve().parents[1] / ".bankdoit-demo" / "apuestas.sqlite3"


def preparar(ruta: Path) -> None:
    ruta.parent.mkdir(parents=True, exist_ok=True)
    with closing(sqlite3.connect(ruta)) as db, db:
        db.executescript("""
            CREATE TABLE IF NOT EXISTS bankroll (
                usuario_id INTEGER PRIMARY KEY,
                inicial INTEGER NOT NULL CHECK (inicial >= 0)
            );
            CREATE TABLE IF NOT EXISTS partido (id INTEGER PRIMARY KEY);
            CREATE TABLE IF NOT EXISTS apuesta (
                id INTEGER PRIMARY KEY,
                usuario_id INTEGER NOT NULL REFERENCES bankroll(usuario_id),
                clave TEXT NOT NULL,
                partido_id INTEGER NOT NULL REFERENCES partido(id),
                seleccion TEXT NOT NULL,
                monto INTEGER NOT NULL CHECK (monto > 0),
                cuota TEXT NOT NULL,
                estado TEXT NOT NULL CHECK (estado IN ('pendiente','ganada','perdida','anulada')),
                UNIQUE (usuario_id, clave)
            );
            CREATE TABLE IF NOT EXISTS movimiento (
                apuesta_id INTEGER NOT NULL REFERENCES apuesta(id),
                tipo TEXT NOT NULL CHECK (tipo IN ('reserva','liquidacion')),
                cambio_disponible INTEGER NOT NULL,
                cambio_en_juego INTEGER NOT NULL,
                PRIMARY KEY (apuesta_id, tipo)
            );
        """)
        db.executemany("INSERT OR IGNORE INTO bankroll VALUES (?, ?)",
                       [(3, 100000), (4, 80000)])
        db.executemany("INSERT OR IGNORE INTO partido VALUES (?)", [(42,), (101,), (202,)])


if __name__ == "__main__":
    preparar(ruta_demo())
    print("Base de demostración lista. Usuarios 3 y 4.")
