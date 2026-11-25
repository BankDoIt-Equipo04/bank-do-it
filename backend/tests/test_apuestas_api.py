import sqlite3
from concurrent.futures import ThreadPoolExecutor
from contextlib import closing
from io import BytesIO

import pytest
from fastapi.testclient import TestClient
from PIL import Image

from app.cuentas import huella
from app.datos_demo import preparar, ruta_demo
from app.main import app

URL = "/usuarios/3/apuestas"
SALDO = "/usuarios/3/bankroll"
DATOS = {"partido_id": 101, "seleccion": "América", "monto": "100.00", "cuota": "2.00"}


@pytest.fixture
def demo(tmp_path):
    ruta = tmp_path / "prueba.sqlite3"
    preparar(ruta)
    # Sesiones de prueba para las dos cuentas precargadas del escenario anterior.
    with closing(sqlite3.connect(ruta)) as db, db:
        for usuario in (3, 4):
            db.execute("INSERT INTO cuenta VALUES (?, ?, ?, ?)", (usuario, f"demo{usuario}", b"", b""))
            db.execute("INSERT INTO sesion VALUES (?, ?, strftime('%s', 'now') + 3600)",
                       (huella(f"prueba-{usuario}"), usuario))
    app.dependency_overrides[ruta_demo] = lambda: ruta
    try:
        with TestClient(app) as cliente:
            cliente.headers.update({"Authorization": "Bearer prueba-3"})
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
    assert cliente.get("/usuarios/4/bankroll", headers={"Authorization": "Bearer prueba-4"}).json()["disponible"] == "800.00"
    res = cliente.put("/usuarios/3" + ruta, json={"resultado": "ganada"})
    assert res.json()["bankroll"]["disponible"] == "1000.03"


def test_dos_apuestas_compiten_por_el_mismo_saldo(demo):
    cliente, _ = demo
    with ThreadPoolExecutor(max_workers=2) as pool:
        respuestas = list(pool.map(lambda clave: enviar(cliente, clave, monto="700.00"), ("a", "b")))
    assert sorted(r.status_code for r in respuestas) == [201, 409]
    assert cliente.get(SALDO).json() == {"disponible": "300.00", "en_juego": "700.00"}


def test_historial_y_limite_semanal_al_confirmar(demo):
    cliente, _ = demo
    url = '/usuarios/3/historial'
    inicial = cliente.get(url).json()
    assert inicial['apuestas'] == []
    assert {p['id'] for p in inicial['partidos']} == {42, 101, 202}
    assert inicial['presupuesto'] == {'limite_centavos': 50000, 'usado_centavos': 0}
    assert enviar(cliente, 'primera', monto='450.00', exceso_aceptado='0').status_code == 201
    rechazo = enviar(cliente, 'segunda', exceso_aceptado='0')
    assert rechazo.status_code == 409
    assert rechazo.json()['detail'] == {'exceso_centavos': 5000}
    assert cliente.get(url).json()['presupuesto']['usado_centavos'] == 45000
    aceptada = enviar(cliente, 'segunda', exceso_aceptado='50')
    assert aceptada.status_code == 201
    assert enviar(cliente, 'segunda', exceso_aceptado='50').status_code == 200
    final = cliente.get(url).json()
    assert len(final['apuestas']) == 2
    assert final['bankroll'] == aceptada.json()['bankroll']
    assert final['presupuesto']['usado_centavos'] == 55000
    assert cliente.get('/usuarios/4/historial', headers={'Authorization': 'Bearer prueba-4'}).json()['apuestas'] == []

def test_recuerdo_persiste_solo_en_su_apuesta(demo):
    cliente, _ = demo
    primera = enviar(cliente).json()["apuesta"]["id"]
    segunda = enviar(cliente, clave="otra").json()["apuesta"]["id"]
    url = f"{URL}/{primera}/recuerdo"
    antes = cliente.get(SALDO).json()
    assert cliente.get(url).status_code == 204
    foto = BytesIO()
    Image.new("RGB", (24, 16)).save(foto, format="PNG")
    assert cliente.put(url, content=foto.getvalue()).status_code == 204
    assert cliente.put(url, content=b"archivo incorrecto").status_code == 415
    assert cliente.put(url, content=bytes(10 * 1024 * 1024 + 1)).status_code == 413
    assert cliente.get(url).content == foto.getvalue()
    assert cliente.get(f"{URL}/{segunda}/recuerdo").status_code == 204
    otro = f"/usuarios/4/apuestas/{primera}/recuerdo"
    assert cliente.get(otro).status_code == 404
    assert cliente.put(otro, content=foto.getvalue()).status_code == 404
    assert cliente.get(SALDO).json() == antes


def test_movimientos_y_ganancia_separada(demo):
    cliente, _ = demo
    url = SALDO + "/movimientos"
    apuesta = enviar(cliente).json()["apuesta"]["id"]
    assert cliente.get(url).json()["ganancia_deportiva"] == "0.00"
    assert cliente.put(f"{URL}/{apuesta}/resultado", json={"resultado": "ganada"}).status_code == 200
    cabecera = {"Idempotency-Key": "recarga"}
    datos = {"tipo": "aportacion", "monto": "250.25"}
    with ThreadPoolExecutor(max_workers=2) as pool:
        respuestas = list(pool.map(lambda _: cliente.post(url, headers=cabecera, json=datos), range(2)))
    assert sorted(r.status_code for r in respuestas) == [200, 201]
    assert respuestas[0].json() == respuestas[1].json()
    assert cliente.post(url, headers=cabecera, json={**datos, "tipo": "retiro"}).status_code == 409
    retiro = cliente.post(url, headers={"Idempotency-Key": "retiro"}, json={"tipo": "retiro", "monto": "50.25"})
    assert retiro.json()["bankroll"]["disponible"] == "1300.00"
    historial = cliente.get(url).json()
    assert historial["ganancia_deportiva"] == "100.00"
    assert [m["tipo"] for m in historial["movimientos"]] == [
        "retiro", "aportacion", "liquidacion", "reserva", "saldo_inicial"]
    assert historial["presupuesto"]["usado_centavos"] == 10000
    assert cliente.get(SALDO).json() == historial["bankroll"]
    assert cliente.get("/usuarios/3/historial").json()["bankroll"] == historial["bankroll"]


def test_retiros_compiten_por_el_disponible(demo):
    cliente, _ = demo
    enviar(cliente)
    url = SALDO + "/movimientos"
    def retirar(clave):
        return cliente.post(url, headers={"Idempotency-Key": clave}, json={"tipo": "retiro", "monto": "600"})
    with ThreadPoolExecutor(max_workers=2) as pool:
        respuestas = list(pool.map(retirar, ("uno", "dos")))
    assert sorted(r.status_code for r in respuestas) == [201, 409]
    assert next(r for r in respuestas if r.status_code == 409).json()["detail"] == "saldo_insuficiente"
    assert cliente.get(SALDO).json() == {"disponible": "300.00", "en_juego": "100.00"}
    assert len(cliente.get(url).json()["movimientos"]) == 3


def test_presupuesto_y_aislamiento(demo):
    cliente, ruta = demo
    url = SALDO + "/presupuesto"
    assert cliente.put(url, json={"limite": "25.50"}).json() == {"limite_centavos": 2550, "usado_centavos": 0}
    assert enviar(cliente, exceso_aceptado="0").json()["detail"] == {"exceso_centavos": 7450}
    assert cliente.put(url, json={"limite": "-1"}).status_code == 422
    assert cliente.put(url, json={"limite": None}).json()["limite_centavos"] is None
    preparar(ruta)
    assert cliente.get("/usuarios/3/historial").json()["presupuesto"]["limite_centavos"] is None
    assert enviar(cliente, exceso_aceptado="0").status_code == 201
    url_ajena = "/usuarios/4/bankroll"
    assert cliente.get(url_ajena + "/movimientos").status_code == 404
    assert cliente.put(url_ajena + "/presupuesto", json={"limite": 1}).status_code == 404
    assert cliente.post(url_ajena + "/movimientos", headers={"Idempotency-Key": "x"},
                        json={"tipo": "retiro", "monto": 1}).status_code == 404


def test_actualizar_base_anterior_con_apuesta_resuelta(demo):
    cliente, ruta = demo
    apuesta = enviar(cliente).json()["apuesta"]["id"]
    assert cliente.put(f"{URL}/{apuesta}/resultado", json={"resultado": "perdida"}).status_code == 200
    with closing(sqlite3.connect(ruta)) as db, db:
        db.execute("ALTER TABLE movimiento RENAME TO nuevo")
        db.execute("""CREATE TABLE movimiento (
                   apuesta_id INTEGER NOT NULL, tipo TEXT NOT NULL, cambio_disponible INTEGER NOT NULL,
                   cambio_en_juego INTEGER NOT NULL, PRIMARY KEY (apuesta_id, tipo))""")
        db.execute("""INSERT INTO movimiento SELECT apuesta_id, tipo, cambio_disponible, cambio_en_juego
                      FROM nuevo ORDER BY id""")
        db.execute("DROP TABLE nuevo")
    preparar(ruta)
    preparar(ruta)
    historial = cliente.get(SALDO + "/movimientos").json()
    assert historial["ganancia_deportiva"] == "-100.00"
    assert historial["bankroll"] == {"disponible": "900.00", "en_juego": "0.00"}
    assert [m["tipo"] for m in historial["movimientos"]] == ["liquidacion", "reserva", "saldo_inicial"]
