import sqlite3
from contextlib import closing
from io import BytesIO

import pytest
from fastapi.testclient import TestClient
from PIL import Image

from app.datos_demo import preparar, ruta_demo
from app.main import app


@pytest.fixture
def api(tmp_path):
    ruta = tmp_path / "cuentas.sqlite3"
    preparar(ruta)
    app.dependency_overrides[ruta_demo] = lambda: ruta
    try:
        with TestClient(app) as cliente:
            yield cliente, ruta
    finally:
        app.dependency_overrides.pop(ruta_demo)


def crear(cliente, alias, saldo):
    datos = {"alias": alias, "password": "Solo-para-prueba"}
    registro = cliente.post("/auth/registro", json={**datos, "saldo_inicial": saldo})
    assert registro.status_code == 201
    login = cliente.post("/auth/login", json=datos)
    assert login.status_code == 200
    assert login.json()["usuario_id"] == registro.json()["usuario_id"]
    return f"/usuarios/{registro.json()['usuario_id']}", {"Authorization": "Bearer " + login.json()["access_token"]}


def test_dos_cuentas_y_sus_fotos(api):
    cliente, _ = api
    a, ha = crear(cliente, "equipo_a", "1000.00")
    b, hb = crear(cliente, "equipo_b", "250.00")
    datos = {"partido_id": 101, "seleccion": "Local", "monto": "100", "cuota": "2"}
    cab = {"Idempotency-Key": "prueba"}
    registro = cliente.post(a + "/apuestas", headers={**ha, **cab}, json=datos)
    assert registro.status_code == 201
    apuesta = f"/apuestas/{registro.json()['apuesta']['id']}"
    foto = BytesIO()
    Image.new("RGB", (2, 2)).save(foto, format="PNG")
    assert cliente.put(a + apuesta + "/recuerdo", headers=ha, content=foto.getvalue()).status_code == 204
    assert cliente.get(a + apuesta + "/recuerdo", headers=ha).content == foto.getvalue()

    for sufijo in ("/bankroll", "/historial", apuesta + "/recuerdo"):
        assert cliente.get(a + sufijo).status_code == 401
        assert cliente.get(a + sufijo, headers=hb).status_code == 404
    assert cliente.get(b + apuesta + "/recuerdo", headers=hb).status_code == 404
    assert cliente.put(a + apuesta + "/recuerdo", headers=hb, content=foto.getvalue()).status_code == 404
    assert cliente.put(a + apuesta + "/resultado", headers=hb, json={"resultado": "ganada"}).status_code == 404
    assert cliente.post(a + "/apuestas", headers={**hb, **cab}, json=datos).status_code == 404
    assert cliente.get(a + "/bankroll", headers=ha).json()["disponible"] == "900.00"
    assert cliente.get(b + "/bankroll", headers=hb).json()["disponible"] == "250.00"
    assert cliente.get(b + "/historial", headers=hb).json()["apuestas"] == []
    assert cliente.post("/auth/logout", headers=ha).status_code == 204
    assert cliente.get(a + "/bankroll", headers=ha).status_code == 401
    assert cliente.get(b + "/bankroll", headers=hb).status_code == 200


def test_credenciales_y_caducidad(api):
    cliente, ruta = api
    usuario, headers = crear(cliente, "Prueba", "0")
    datos = {"alias": "prueba", "password": "Solo-para-prueba"}
    assert cliente.post("/auth/registro", json={**datos, "saldo_inicial": "10"}).status_code == 409
    assert cliente.post("/auth/registro", json={**datos, "alias": "otro", "saldo_inicial": "-1"}).status_code == 422
    for alias in ("prueba", "no_existe"):
        res = cliente.post("/auth/login", json={"alias": alias, "password": "incorrecta"})
        assert res.status_code == 401
        assert res.json()["detail"] == "Alias o contraseña incorrectos."
    with closing(sqlite3.connect(ruta)) as db, db:
        assert db.execute("SELECT COUNT(*) FROM bankroll").fetchone() == (3,)
        sal, clave = db.execute("SELECT sal, clave_derivada FROM cuenta").fetchone()
        assert len(sal) == 16 and len(clave) == 32
        db.execute("UPDATE sesion SET vence = 0")
    assert cliente.get(usuario + "/bankroll", headers=headers).status_code == 401
