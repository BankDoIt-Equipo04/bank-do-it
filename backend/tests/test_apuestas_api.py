import sqlite3
from concurrent.futures import ThreadPoolExecutor
from contextlib import closing

import pytest
from fastapi.testclient import TestClient

from app.datos_demo import preparar, ruta_demo
from app.main import app

URL = "/usuarios/3/apuestas"
SALDO = "/usuarios/3/bankroll"
DATOS = {"partido_id": 101, "seleccion": "América", "monto": "100.00", "cuota": "2.00"}


@pytest.fixture
def demo(tmp_path):
    ruta = tmp_path / "prueba.sqlite3"
    preparar(ruta)
    app.dependency_overrides[ruta_demo] = lambda: ruta
    try:
        with TestClient(app) as cliente:
            yield cliente, ruta
    finally:
        app.dependency_overrides.pop(ruta_demo)


def enviar(cliente, clave="borrador-a", **cambios):
    return cliente.post(URL, headers={"Idempotency-Key": clave}, json={**DATOS, **cambios})


@pytest.mark.parametrize(("estado", "final"), [
    ("ganada", "1100.00"), ("perdida", "900.00"), ("anulada", "1000.00")
])
def test_flujo_y_repeticion(demo, estado, final):
    cliente, ruta = demo
    assert cliente.get(SALDO).json() == {"disponible": "1000.00", "en_juego": "0.00"}
    registrada = enviar(cliente)
    assert registrada.status_code == 201
    apuesta = registrada.json()["apuesta"]
    assert apuesta["estado"] == "pendiente"
    assert registrada.json()["bankroll"] == {"disponible": "900.00", "en_juego": "100.00"}
    destino = f"{URL}/{apuesta['id']}/resultado"
    for _ in range(2):
        res = cliente.put(destino, json={"resultado": estado})
        assert res.status_code == 200 and res.json()["apuesta"]["estado"] == estado
        assert res.json()["bankroll"] == {"disponible": final, "en_juego": "0.00"}
    otro = "perdida" if estado == "ganada" else "ganada"
    assert cliente.put(destino, json={"resultado": otro}).status_code == 409
    preparar(ruta)  # Reinicializar la demo conserva las operaciones.
    assert cliente.get(SALDO).json()["disponible"] == final
    with closing(sqlite3.connect(ruta)) as db:
        assert db.execute("SELECT COUNT(*) FROM movimiento").fetchone() == (2,)


def test_reenvio_simultaneo(demo):
    cliente, ruta = demo
    with ThreadPoolExecutor(max_workers=2) as pool:
        respuestas = list(pool.map(lambda _: enviar(cliente), range(2)))
    assert sorted(r.status_code for r in respuestas) == [200, 201]
    assert respuestas[0].json() == respuestas[1].json()
    assert enviar(cliente, monto="120.00").status_code == 409
    assert cliente.get(SALDO).json()["disponible"] == "900.00"
    with closing(sqlite3.connect(ruta)) as db:
        assert db.execute("SELECT COUNT(*) FROM apuesta").fetchone() == (1,)
        assert db.execute("SELECT COUNT(*) FROM movimiento").fetchone() == (1,)


@pytest.mark.parametrize(("cambios", "codigo"), [
    ({"cuota": "1.00"}, 422), ({"monto": "0.00"}, 422),
    ({"monto": "1000.01"}, 409), ({"partido_id": 99}, 404)
])
def test_rechazo_sin_cargo(demo, cambios, codigo):
    cliente, _ = demo
    assert enviar(cliente, **cambios).status_code == codigo
    assert cliente.get(SALDO).json() == {"disponible": "1000.00", "en_juego": "0.00"}


def test_usuario_y_redondeo(demo):
    cliente, _ = demo
    apuesta = enviar(cliente, monto="0.05", cuota="1.50").json()["apuesta"]
    ruta = f"/apuestas/{apuesta['id']}/resultado"
    assert cliente.put("/usuarios/4" + ruta, json={"resultado": "ganada"}).status_code == 404
    assert cliente.get("/usuarios/4/bankroll").json()["disponible"] == "800.00"
    res = cliente.put("/usuarios/3" + ruta, json={"resultado": "ganada"})
    assert res.json()["bankroll"]["disponible"] == "1000.03"


def test_dos_apuestas_compiten_por_el_mismo_saldo(demo):
    cliente, _ = demo
    with ThreadPoolExecutor(max_workers=2) as pool:
        respuestas = list(pool.map(lambda clave: enviar(cliente, clave, monto="700.00"), ("a", "b")))
    assert sorted(r.status_code for r in respuestas) == [201, 409]
    assert cliente.get(SALDO).json() == {"disponible": "300.00", "en_juego": "700.00"}
