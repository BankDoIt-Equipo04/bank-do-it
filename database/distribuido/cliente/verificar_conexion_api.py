"""BANKDOIT · Verificación de la conexión de la API a los fragmentos (#32).

Se conecta como lo hará la API de Python (rol ``bankdoit_api``, TLS con
``sslmode=verify-full``) y comprueba:

1. Que cada conexión usa TLS y que el servidor es el esperado (certificado
   firmado por la CA de BANKDOIT y nombre del servidor correcto).
2. Que la cuenta de la API no tiene privilegios de administración ni
   acceso directo a las tablas.
3. El flujo completo con dos cuentas (una par y una impar): registro en el
   directorio, bankroll en su fragmento, apuesta, reenvío con la misma
   clave, resolución, historial y sesión.

Variables de entorno (sin secretos en el código):
    BANKDOIT_PG_IMPAR_DSN       primario impar (Nodo A); también aloja el directorio
    BANKDOIT_PG_PAR_DSN         primario par (Nodo B)
    BANKDOIT_PG_DIRECTORIO_DSN  opcional; por omisión, el mismo que el impar
    BANKDOIT_PG_PASSWORD        contraseña de bankdoit_api
    BANKDOIT_CA_NO_CONFIABLE    opcional; CA ajena para la prueba negativa

Al final imprime una línea ``RESULTADO_JSON:{...}`` con los resultados.
"""
from __future__ import annotations

import hashlib
import json
import os
import secrets
import sys
import time
from datetime import datetime, timedelta, timezone
from decimal import Decimal

import psycopg
from psycopg import errors
from psycopg.conninfo import conninfo_to_dict, make_conninfo

DSN = {
    "impar": os.environ["BANKDOIT_PG_IMPAR_DSN"],
    "par": os.environ["BANKDOIT_PG_PAR_DSN"],
}
DSN["directorio"] = os.environ.get("BANKDOIT_PG_DIRECTORIO_DSN", DSN["impar"])
PASSWORD = os.environ["BANKDOIT_PG_PASSWORD"]
MARCA_HASH = "cuenta-en-directorio"  # la credencial real vive en el directorio
resultados: list[dict] = []
fallos = 0


# ----------------------------------------------------------------- base
def conectar(destino: str, **cambios) -> psycopg.Connection:
    """Abre una conexión de la API. ``destino`` = impar | par | directorio."""
    dsn = make_conninfo(DSN[destino], **cambios) if cambios else DSN[destino]
    return psycopg.connect(dsn, password=PASSWORD, autocommit=True, connect_timeout=10)


def fragmento_de(usuario_id: int) -> str:
    """Regla de la propuesta: usuario_id impar -> Nodo A, par -> Nodo B."""
    return "impar" if usuario_id % 2 else "par"


def registrar(usuario: str, fragmento: str, operacion: str, esperado: str, obtenido, ok: bool):
    global fallos
    obtenido = str(obtenido)
    resultados.append(dict(usuario=usuario, fragmento=fragmento, operacion=operacion,
                           esperado=esperado, obtenido=obtenido, ok=ok))
    marca = "OK   " if ok else "FALLO"
    print(f"{marca} [{usuario} · {fragmento}] {operacion}: {obtenido}")
    if not ok:
        fallos += 1


def error_de(func) -> str:
    """Ejecuta ``func`` y devuelve el mensaje de error (o '' si no falló)."""
    try:
        func()
    except psycopg.Error as exc:
        return (exc.diag.message_primary or str(exc)).strip()
    return ""


def saldo(c, usuario_id) -> str:
    fila = c.execute("SELECT saldo_disponible, monto_en_juego FROM consultar_bankroll(%s)",
                     (usuario_id,)).fetchone()
    return f"{fila[0]} / {fila[1]}"


# ---------------------------------------------------------- 1. TLS
tls = {}
for frag in ("impar", "par"):
    with conectar(frag) as c:
        quien = c.execute("SELECT current_user, current_database(), nombre FROM fragmento_local").fetchone()
        sesion = c.execute("SELECT ssl, version, cipher, bits FROM pg_stat_ssl "
                           "WHERE pid = pg_backend_pid()").fetchone()
        modo = conninfo_to_dict(DSN[frag]).get("sslmode")
        tls[frag] = dict(host=f"{c.info.host} ({c.info.hostaddr})", puerto=c.info.port, usuario=quien[0], base=quien[1],
                         fragmento=quien[2], ssl=sesion[0], version=sesion[1], cifrado=sesion[2],
                         bits=sesion[3], sslmode=modo)
        registrar("conexión", frag, "Sesión cifrada (pg_stat_ssl)", "ssl = true, TLSv1.2+",
                  f"ssl={sesion[0]}, {sesion[1]}, {sesion[2]}", sesion[0] is True)
        registrar("conexión", frag, "Identidad del servidor", "verify-full contra la CA de BANKDOIT",
                  f"sslmode={modo}, fragmento={quien[2]}", modo == "verify-full" and quien[2] == frag)

    msg = error_de(lambda: conectar(frag, sslmode="disable").close())
    registrar("conexión", frag, "Conectar sin TLS", "rechazada por pg_hba", msg[:90],
              "pg_hba.conf rejects connection" in msg)
    ajena = os.environ.get("BANKDOIT_CA_NO_CONFIABLE")
    if ajena:
        msg = error_de(lambda: conectar(frag, sslrootcert=ajena).close())
        registrar("conexión", frag, "Servidor con CA no confiable", "rechazada por el cliente", msg[:90],
                  "certificate verify failed" in msg)
    msg = error_de(lambda: conectar(frag, host="servidor-equivocado.bankdoit").close())
    registrar("conexión", frag, "Nombre de servidor distinto", "rechazada (no coincide el certificado)",
              msg[:90], "does not match host name" in msg)

# ------------------------------------------------- 2. Privilegios mínimos
with conectar("impar") as c:
    flags = c.execute("SELECT rolsuper, rolcreaterole, rolcreatedb, rolreplication, rolbypassrls "
                      "FROM pg_roles WHERE rolname = current_user").fetchone()
    registrar("bankdoit_api", "impar", "Atributos de administración", "todos en false",
              dict(zip(["super", "createrole", "createdb", "replication", "bypassrls"], flags)),
              not any(flags))
for frag, sql, nombre in (
        ("impar", "SELECT * FROM movimiento LIMIT 1", "Leer tabla de movimientos"),
        ("impar", "UPDATE bankroll SET saldo_disponible = 0", "Modificar saldo directo"),
        ("par", "DELETE FROM apuesta", "Borrar apuestas"),
        ("par", "CREATE TABLE intruso (x int)", "Crear tablas"),
        ("par", "SELECT bloquear_bankroll(1)", "Función interna no publicada"),
        ("directorio", "SELECT * FROM cuenta", "Leer el directorio de cuentas"),
        ("directorio", "DROP FUNCTION registrar_apuesta(BIGINT, VARCHAR, BIGINT, VARCHAR, NUMERIC, NUMERIC, VARCHAR)",
         "Eliminar funciones")):
    with conectar(frag) as c:
        msg = error_de(lambda: c.execute(sql))
    registrar("bankdoit_api", frag, nombre, "permiso denegado", msg[:80],
              "permission denied" in msg or "must be owner" in msg)

# ------------------------------------------- 3. Flujo con dos cuentas
sello = time.strftime("%m%d%H%M%S")
cuentas = []
for n in (1, 2):
    alias = f"Prueba-{n}_{sello}"
    sal = secrets.token_bytes(16)
    clave = hashlib.pbkdf2_hmac("sha256", b"ClaveDePrueba123", sal, 600_000)
    with conectar("directorio") as c:
        uid = c.execute("SELECT registrar_cuenta(%s, %s, %s)", (alias, sal, clave)).fetchone()[0]
    cuentas.append(dict(alias=alias, usuario_id=uid, fragmento=fragmento_de(uid), sal=sal, clave=clave))

registrar("directorio", "impar", "Registrar dos cuentas seguidas", "una impar y una par",
          [(x["usuario_id"], x["fragmento"]) for x in cuentas],
          {x["fragmento"] for x in cuentas} == {"impar", "par"})
with conectar("directorio") as c:
    duplicado = cuentas[0]["alias"].upper()
    msg = error_de(lambda: c.execute("SELECT registrar_cuenta(%s, %s, %s)",
                                     (duplicado, secrets.token_bytes(16), secrets.token_bytes(32))))
registrar("directorio", "impar", f"Alias repetido con otras mayúsculas ({duplicado})", "alias_duplicado",
          msg, msg == "alias_duplicado")

with conectar("impar") as c:
    p_impar = c.execute("SELECT p.partido_id, el.nombre, ev.nombre, p.fecha_hora FROM partido p "
                        "JOIN equipo el ON el.equipo_id = p.equipo_local_id "
                        "JOIN equipo ev ON ev.equipo_id = p.equipo_visitante_id WHERE p.partido_id = 101").fetchone()
with conectar("par") as c:
    p_par = c.execute("SELECT p.partido_id, el.nombre, ev.nombre, p.fecha_hora FROM partido p "
                      "JOIN equipo el ON el.equipo_id = p.equipo_local_id "
                      "JOIN equipo ev ON ev.equipo_id = p.equipo_visitante_id WHERE p.partido_id = 101").fetchone()
registrar("catálogo", "ambos", "Partido de prueba 101 en los dos fragmentos", "mismo id, equipos y fecha",
          f"{p_impar[1]} vs. {p_impar[2]}" if p_impar else None, p_impar is not None and p_impar == p_par)

for cta in cuentas:
    uid, frag, quien = cta["usuario_id"], cta["fragmento"], f"{cta['alias']} (id {cta['usuario_id']})"
    otro = "par" if frag == "impar" else "impar"
    with conectar(frag) as c:
        c.execute("SELECT crear_usuario(%s, %s, %s, %s, 'usuario', %s)",
                  (cta["alias"], MARCA_HASH, Decimal("1000.00"), Decimal("500.00"), uid))
        registrar(quien, frag, "Crear bankroll con saldo inicial $1,000", "1000.00 / 0.00", saldo(c, uid),
                  saldo(c, uid) == "1000.00 / 0.00")
        # Reintento del registro (por ejemplo, si se perdió la respuesta): no duplica.
        msg = error_de(lambda: c.execute("SELECT crear_usuario(%s, %s, %s, %s, 'usuario', %s)",
                                         (cta["alias"], MARCA_HASH, Decimal("1000.00"), None, uid)))
        registrar(quien, frag, "Repetir la creación del bankroll", "rechazada sin duplicar (llave duplicada)",
                  msg[:70], "duplicate key" in msg)
    with conectar("directorio") as c:
        c.execute("SELECT activar_cuenta(%s)", (uid,))
        fila = c.execute("SELECT usuario_id, estado FROM buscar_cuenta(%s)", (cta["alias"].lower(),)).fetchone()
        registrar(quien, "impar", "Iniciar sesión: buscar alias en el directorio", f"id {uid}, activa",
                  f"id {fila[0]}, {fila[1]}", fila == (uid, "activa"))
        token = secrets.token_urlsafe(32)
        huella = hashlib.sha256(token.encode()).digest()
        c.execute("SELECT crear_sesion(%s, %s, %s)",
                  (huella, uid, datetime.now(timezone.utc) + timedelta(hours=24)))
        vigente = c.execute("SELECT validar_sesion(%s)", (huella,)).fetchone()[0]
        registrar(quien, "impar", "Validar token de sesión", f"usuario {uid}", vigente, vigente == uid)
        cta["huella"] = huella

    clave_op = f"borrador-{secrets.token_hex(8)}"
    with conectar(frag) as c:
        r1 = c.execute("SELECT apuesta_id, saldo_disponible, monto_en_juego, es_reenvio FROM "
                       "registrar_apuesta(%s, %s, 101, 'Local', 100.00, 2.00)", (uid, clave_op)).fetchone()
        registrar(quien, frag, "Registrar apuesta de $100 a 2.00", "900.00 / 100.00, nueva",
                  f"apuesta {r1[0]}: {r1[1]} / {r1[2]}, reenvío={r1[3]}",
                  (str(r1[1]), str(r1[2]), r1[3]) == ("900.00", "100.00", False))
        r2 = c.execute("SELECT apuesta_id, saldo_disponible, monto_en_juego, es_reenvio FROM "
                       "registrar_apuesta(%s, %s, 101, 'Local', 100.00, 2.00)", (uid, clave_op)).fetchone()
        registrar(quien, frag, "Reenviar con la misma clave de operación", "misma apuesta, sin segundo cargo",
                  f"apuesta {r2[0]}: {r2[1]} / {r2[2]}, reenvío={r2[3]}",
                  r2[0] == r1[0] and r2[3] is True and str(r2[1]) == "900.00")
        msg = error_de(lambda: c.execute("SELECT registrar_apuesta(%s, %s, 101, 'Local', 5000, 2)",
                                         (uid, f"{clave_op}-x")))
        registrar(quien, frag, "Apuesta mayor al saldo", "saldo_insuficiente", msg, msg == "saldo_insuficiente")
        if frag == "impar":
            r3 = c.execute("SELECT saldo_disponible, monto_en_juego FROM resolver_apuesta(%s, %s, 'ganada')",
                           (uid, r1[0])).fetchone()
            registrar(quien, frag, "Resolver como ganada", "1100.00 / 0.00", f"{r3[0]} / {r3[1]}",
                      f"{r3[0]} / {r3[1]}" == "1100.00 / 0.00")
        historial = c.execute("SELECT consultar_historial(%s)", (uid,)).fetchone()[0]
        registrar(quien, frag, "Consultar historial (JSON de la API)", "1 apuesta y catálogo",
                  f"{len(historial['apuestas'])} apuesta(s), {len(historial['partidos'])} partidos, "
                  f"bankroll {historial['bankroll']}",
                  len(historial["apuestas"]) == 1 and len(historial["partidos"]) >= 3)
        cta.update(apuesta_id=r1[0], saldo_final=saldo(c, uid), clave_op=clave_op)
    with conectar(otro) as c:
        msg = error_de(lambda: c.execute("SELECT consultar_bankroll(%s)", (uid,)))
        registrar(quien, otro, "Consultar su saldo en el otro fragmento", "usuario_inexistente", msg,
                  msg == "usuario_inexistente")

with conectar("directorio") as c:
    huella = cuentas[0]["huella"]
    cerrada = c.execute("SELECT cerrar_sesion(%s)", (huella,)).fetchone()[0]
    despues = c.execute("SELECT validar_sesion(%s)", (huella,)).fetchone()[0]
registrar(cuentas[0]["alias"], "impar", "Cerrar sesión y validar el token otra vez", "token sin efecto (NULL)",
          f"cerrada={cerrada}, validar={despues}", cerrada is True and despues is None)

for cta in cuentas:
    cta.pop("sal"), cta.pop("clave"), cta.pop("huella", None)
print("RESULTADO_JSON:" + json.dumps(dict(tls=tls, cuentas=cuentas, resultados=resultados, fallos=fallos),
                                     default=str, ensure_ascii=False))
sys.exit(1 if fallos else 0)
