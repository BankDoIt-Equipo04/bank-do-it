"""Base local reproducible para probar la API con datos simulados."""
import sqlite3
from contextlib import closing
from pathlib import Path


def ruta_demo() -> Path:
    return Path(__file__).resolve().parents[1] / ".bankdoit-demo" / "apuestas.sqlite3"


def preparar_movimientos(db):
    columnas = {c[1] for c in db.execute("PRAGMA table_info(movimiento)")}
    if "usuario_id" in columnas:
        return
    if columnas:
        db.execute("ALTER TABLE movimiento RENAME TO movimiento_anterior")
    db.execute("""
        CREATE TABLE movimiento (
            id INTEGER PRIMARY KEY,
            usuario_id INTEGER NOT NULL REFERENCES bankroll(usuario_id),
            apuesta_id INTEGER REFERENCES apuesta(id),
            tipo TEXT NOT NULL,
            cambio_disponible INTEGER NOT NULL,
            cambio_en_juego INTEGER NOT NULL DEFAULT 0,
            clave TEXT,
            creado_en TEXT DEFAULT CURRENT_TIMESTAMP,
            UNIQUE (apuesta_id, tipo), UNIQUE (usuario_id, clave),
            CHECK (
                (tipo IN ('reserva', 'liquidacion') AND apuesta_id IS NOT NULL AND clave IS NULL)
                OR (tipo IN ('aportacion', 'retiro') AND apuesta_id IS NULL AND clave IS NOT NULL
                    AND cambio_en_juego = 0 AND
                    ((tipo = 'aportacion' AND cambio_disponible > 0)
                     OR (tipo = 'retiro' AND cambio_disponible < 0)))
            )
        )""")
    if columnas:
        # El esquema anterior conservaba el orden, pero no fechaba sus movimientos.
        db.execute("""
            INSERT INTO movimiento (usuario_id, apuesta_id, tipo, cambio_disponible, cambio_en_juego, creado_en)
            SELECT a.usuario_id, m.apuesta_id, m.tipo, m.cambio_disponible, m.cambio_en_juego, NULL
            FROM movimiento_anterior m JOIN apuesta a ON a.id = m.apuesta_id ORDER BY m.rowid""")
        db.execute("DROP TABLE movimiento_anterior")


def preparar(ruta: Path) -> None:
    ruta.parent.mkdir(parents=True, exist_ok=True)
    with closing(sqlite3.connect(ruta)) as db, db:
        db.executescript("""
            CREATE TABLE IF NOT EXISTS bankroll (
                usuario_id INTEGER PRIMARY KEY,
                inicial INTEGER NOT NULL CHECK (inicial >= 0)
            );
            CREATE TABLE IF NOT EXISTS cuenta (
                usuario_id INTEGER PRIMARY KEY REFERENCES bankroll(usuario_id),
                alias TEXT NOT NULL UNIQUE COLLATE NOCASE,
                sal BLOB NOT NULL,
                clave_derivada BLOB NOT NULL
            );
            CREATE TABLE IF NOT EXISTS sesion (
                huella BLOB PRIMARY KEY NOT NULL,
                usuario_id INTEGER NOT NULL REFERENCES cuenta(usuario_id),
                vence INTEGER NOT NULL
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
            CREATE TABLE IF NOT EXISTS recuerdo (
                apuesta_id INTEGER PRIMARY KEY REFERENCES apuesta(id),
                tipo TEXT NOT NULL,
                contenido BLOB NOT NULL
            );
        """)
        db.execute("BEGIN IMMEDIATE")
        preparar_movimientos(db)
        # La demo anterior no guardaba fechas: se conserva su historial sin
        # atribuir operaciones antiguas a la semana actual.
        columnas = {c[1] for c in db.execute("PRAGMA table_info(apuesta)")}
        if "creada" not in columnas:
            db.execute("ALTER TABLE apuesta ADD COLUMN creada TEXT")
        db.execute("""CREATE TABLE IF NOT EXISTS presupuesto (
            usuario_id INTEGER PRIMARY KEY REFERENCES bankroll(usuario_id),
            limite INTEGER NOT NULL CHECK (limite >= 0))""")
        if db.execute("INSERT OR IGNORE INTO bankroll VALUES (3, 100000)").rowcount:
            db.execute("INSERT INTO presupuesto VALUES (3, 50000)")
        db.execute("INSERT OR IGNORE INTO bankroll VALUES (4, 80000)")
        db.executemany("INSERT OR IGNORE INTO partido VALUES (?)", [(42,), (101,), (202,)])


if __name__ == "__main__":
    preparar(ruta_demo())
    print("Base de demostración lista. Usuarios 3 y 4.")
