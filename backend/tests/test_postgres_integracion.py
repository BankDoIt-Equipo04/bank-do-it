"""Prueba #33. Requiere dos fragmentos con catálogo 101 y escribe cuentas de prueba."""
import os
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient

from app.main import app

pytestmark = pytest.mark.skipif(os.getenv("BANKDOIT_BACKEND") != "postgres",
                                reason="Requiere el entorno de integración PostgreSQL")


def test_apuestas_en_ambos_fragmentos():
    from app.postgres import conexion
    cliente = TestClient(app)
    paridades = set()
    for _ in range(2):
        datos = {"alias": "prueba_" + uuid4().hex, "password": uuid4().hex}
        registro = cliente.post("/auth/registro", json={**datos, "saldo_inicial": 1000})
        assert registro.status_code == 201, registro.text
        uid = registro.json()["usuario_id"]
        paridades.add(uid % 2)
        login = cliente.post("/auth/login", json=datos)
        assert login.status_code == 200, login.text
        headers = {"Authorization": "Bearer " + login.json()["access_token"], "Idempotency-Key": "apuesta-100"}
        ruta = f"/usuarios/{uid}"
        apuesta = {"partido_id": 101, "seleccion": "Local", "monto": 100, "cuota": 2}
        primera = cliente.post(ruta + "/apuestas", json=apuesta, headers=headers)
        segunda = cliente.post(ruta + "/apuestas", json=apuesta, headers=headers)
        assert primera.status_code == 201, primera.text
        assert segunda.status_code == 200, segunda.text
        assert primera.json() == segunda.json()
        historial = cliente.get(ruta + "/historial", headers=headers).json()
        assert len(historial["apuestas"]) == 1
        assert historial["bankroll"] == {"disponible": "900.00", "en_juego": "100.00"}
        with conexion(uid) as db:
            assert db.execute("SELECT nombre FROM fragmento_local").fetchone()["nombre"] == (
                "impar" if uid % 2 else "par")
        apuesta_id = primera.json()["apuesta"]["id"]
        resuelta = cliente.put(f"{ruta}/apuestas/{apuesta_id}/resultado",
                               headers=headers, json={"resultado": "ganada"})
        assert resuelta.status_code == 200, resuelta.text
        assert resuelta.json()["bankroll"] == {"disponible": "1100.00", "en_juego": "0.00"}
        assert cliente.post("/auth/logout", headers=headers).status_code == 204
        assert cliente.get(ruta + "/historial", headers=headers).status_code == 401
    assert paridades == {0, 1}
