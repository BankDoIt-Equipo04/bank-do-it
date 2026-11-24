# Evidencia: acceso de la API a los fragmentos (#32)

Generado por `database/distribuido/configurar_acceso_api.ps1` el 2026-11-23 19:44. Simulación de los dos nodos con Docker en una sola computadora (proyecto `bankdoit-ensayo`). Sin contraseñas ni llaves.

## 1. Configuración aplicada dos veces (idempotente)

| Instancia | Datos antes | Datos después | Resultado de la segunda vuelta |
| --- | --- | --- | --- |
| `ensayo-nodo-a-primario-impar` | 2/2/3/6/4 | 2/2/3/6/4 |  rol bankdoit_api listo en el fragmento impar ·  directorio de cuentas listo en el primario impar · Acceso de la API configurado (ssl=on, API desde: 172.29.0.0/16). |
| `ensayo-nodo-b-primario-par` | 2/2/1/3/4 | 2/2/1/3/4 |  rol bankdoit_api listo en el fragmento par · Acceso de la API configurado (ssl=on, API desde: 172.29.0.0/16). |
| `ensayo-nodo-b-replica-impar` | 2/2/3/6/4 | 2/2/3/6/4 | Réplica: el rol bankdoit_api llega desde su primario. · Acceso de la API configurado (ssl=on, API desde: 172.29.0.0/16). |
| `ensayo-nodo-a-replica-par` | 2/2/1/3/4 | 2/2/1/3/4 | Réplica: el rol bankdoit_api llega desde su primario. · Acceso de la API configurado (ssl=on, API desde: 172.29.0.0/16). |

Conteo: usuarios/bankrolls/apuestas/movimientos/partidos.

`pg_hba.conf` del primario impar (`pg_hba_file_rules`):

```
local   all          all                            trust
host    all          all            127.0.0.1       scram-sha-256
hostssl bankdoit     bankdoit_api   172.29.0.0      scram-sha-256
host    all          bankdoit_api   all             reject
host    replication  replicador     172.29.0.0      scram-sha-256
host    bankdoit     replicador     172.29.0.0      scram-sha-256
host    all          bankdoit       172.29.0.0      scram-sha-256
```

## 2. Sesión TLS desde el cliente de la API

Consulta ejecutada por el cliente con cada conexión:

```sql
SELECT current_user, current_database(), nombre FROM fragmento_local;
SELECT ssl, version, cipher, bits FROM pg_stat_ssl WHERE pid = pg_backend_pid();
```

| Conexión | Servidor | Usuario | Fragmento | sslmode | ssl | Versión | Cifrado |
| --- | --- | --- | --- | --- | --- | --- | --- |
| impar | localhost (127.0.0.1):6441 | bankdoit_api | impar | verify-full | True | TLSv1.3 | TLS_AES_256_GCM_SHA384 (256 bits) |
| par | localhost (127.0.0.1):6451 | bankdoit_api | par | verify-full | True | TLSv1.3 | TLS_AES_256_GCM_SHA384 (256 bits) |

## 3. Cuentas de prueba

| Cuenta | usuario_id | Fragmento | Primario | Réplica | Saldo inicial | Saldo final |
| --- | --- | --- | --- | --- | --- | --- |
| Prueba-1_1123194430 | 1001 | impar | `ensayo-nodo-a-primario-impar (Nodo A)` | `ensayo-nodo-b-replica-impar (Nodo B)` | 1000.00 / 0.00 | 1100.00 / 0.00 |
| Prueba-2_1123194430 | 1002 | par | `ensayo-nodo-b-primario-par (Nodo B)` | `ensayo-nodo-a-replica-par (Nodo A)` | 1000.00 / 0.00 | 900.00 / 100.00 |

## 4. Resultados del cliente (rol bankdoit_api)

| Usuario de prueba | Fragmento esperado | Operación | Resultado esperado | Resultado obtenido | |
| --- | --- | --- | --- | --- | --- |
| conexión | impar | Sesión cifrada (pg_stat_ssl) | ssl = true, TLSv1.2+ | ssl=True, TLSv1.3, TLS_AES_256_GCM_SHA384 | ✔ |
| conexión | impar | Identidad del servidor | verify-full contra la CA de BANKDOIT | sslmode=verify-full, fragmento=impar | ✔ |
| conexión | impar | Conectar sin TLS | rechazada por pg_hba | connection failed: connection to server at "127.0.0.1", port 6441 failed: FATAL:  pg_hba.c | ✔ |
| conexión | impar | Servidor con CA no confiable | rechazada por el cliente | connection failed: connection to server at "127.0.0.1", port 6441 failed: SSL error: certi | ✔ |
| conexión | impar | Nombre de servidor distinto | rechazada (no coincide el certificado) | connection failed: connection to server at "127.0.0.1", port 6441 failed: server certifica | ✔ |
| conexión | par | Sesión cifrada (pg_stat_ssl) | ssl = true, TLSv1.2+ | ssl=True, TLSv1.3, TLS_AES_256_GCM_SHA384 | ✔ |
| conexión | par | Identidad del servidor | verify-full contra la CA de BANKDOIT | sslmode=verify-full, fragmento=par | ✔ |
| conexión | par | Conectar sin TLS | rechazada por pg_hba | connection failed: connection to server at "127.0.0.1", port 6451 failed: FATAL:  pg_hba.c | ✔ |
| conexión | par | Servidor con CA no confiable | rechazada por el cliente | connection failed: connection to server at "127.0.0.1", port 6451 failed: SSL error: certi | ✔ |
| conexión | par | Nombre de servidor distinto | rechazada (no coincide el certificado) | connection failed: connection to server at "127.0.0.1", port 6451 failed: server certifica | ✔ |
| bankdoit_api | impar | Atributos de administración | todos en false | {'super': False, 'createrole': False, 'createdb': False, 'replication': False, 'bypassrls': False} | ✔ |
| bankdoit_api | impar | Leer tabla de movimientos | permiso denegado | permission denied for table movimiento | ✔ |
| bankdoit_api | impar | Modificar saldo directo | permiso denegado | permission denied for table bankroll | ✔ |
| bankdoit_api | par | Borrar apuestas | permiso denegado | permission denied for table apuesta | ✔ |
| bankdoit_api | par | Crear tablas | permiso denegado | permission denied for schema public | ✔ |
| bankdoit_api | par | Función interna no publicada | permiso denegado | permission denied for function bloquear_bankroll | ✔ |
| bankdoit_api | directorio | Leer el directorio de cuentas | permiso denegado | permission denied for table cuenta | ✔ |
| bankdoit_api | directorio | Eliminar funciones | permiso denegado | must be owner of function registrar_apuesta | ✔ |
| directorio | impar | Registrar dos cuentas seguidas | una impar y una par | [(1001, 'impar'), (1002, 'par')] | ✔ |
| directorio | impar | Alias repetido con otras mayúsculas (PRUEBA-1_1123194430) | alias_duplicado | alias_duplicado | ✔ |
| catálogo | ambos | Partido de prueba 101 en los dos fragmentos | mismo id, equipos y fecha | América vs. Chivas | ✔ |
| Prueba-1_1123194430 (id 1001) | impar | Crear bankroll con saldo inicial $1,000 | 1000.00 / 0.00 | 1000.00 / 0.00 | ✔ |
| Prueba-1_1123194430 (id 1001) | impar | Repetir la creación del bankroll | rechazada sin duplicar (llave duplicada) | duplicate key value violates unique constraint "usuario_pkey" | ✔ |
| Prueba-1_1123194430 (id 1001) | impar | Iniciar sesión: buscar alias en el directorio | id 1001, activa | id 1001, activa | ✔ |
| Prueba-1_1123194430 (id 1001) | impar | Validar token de sesión | usuario 1001 | 1001 | ✔ |
| Prueba-1_1123194430 (id 1001) | impar | Registrar apuesta de $100 a 2.00 | 900.00 / 100.00, nueva | apuesta 7: 900.00 / 100.00, reenvío=False | ✔ |
| Prueba-1_1123194430 (id 1001) | impar | Reenviar con la misma clave de operación | misma apuesta, sin segundo cargo | apuesta 7: 900.00 / 100.00, reenvío=True | ✔ |
| Prueba-1_1123194430 (id 1001) | impar | Apuesta mayor al saldo | saldo_insuficiente | saldo_insuficiente | ✔ |
| Prueba-1_1123194430 (id 1001) | impar | Resolver como ganada | 1100.00 / 0.00 | 1100.00 / 0.00 | ✔ |
| Prueba-1_1123194430 (id 1001) | impar | Consultar historial (JSON de la API) | 1 apuesta y catálogo | 1 apuesta(s), 4 partidos, bankroll {'en_juego': '0.00', 'disponible': '1100.00'} | ✔ |
| Prueba-1_1123194430 (id 1001) | par | Consultar su saldo en el otro fragmento | usuario_inexistente | usuario_inexistente | ✔ |
| Prueba-2_1123194430 (id 1002) | par | Crear bankroll con saldo inicial $1,000 | 1000.00 / 0.00 | 1000.00 / 0.00 | ✔ |
| Prueba-2_1123194430 (id 1002) | par | Repetir la creación del bankroll | rechazada sin duplicar (llave duplicada) | duplicate key value violates unique constraint "usuario_pkey" | ✔ |
| Prueba-2_1123194430 (id 1002) | impar | Iniciar sesión: buscar alias en el directorio | id 1002, activa | id 1002, activa | ✔ |
| Prueba-2_1123194430 (id 1002) | impar | Validar token de sesión | usuario 1002 | 1002 | ✔ |
| Prueba-2_1123194430 (id 1002) | par | Registrar apuesta de $100 a 2.00 | 900.00 / 100.00, nueva | apuesta 4: 900.00 / 100.00, reenvío=False | ✔ |
| Prueba-2_1123194430 (id 1002) | par | Reenviar con la misma clave de operación | misma apuesta, sin segundo cargo | apuesta 4: 900.00 / 100.00, reenvío=True | ✔ |
| Prueba-2_1123194430 (id 1002) | par | Apuesta mayor al saldo | saldo_insuficiente | saldo_insuficiente | ✔ |
| Prueba-2_1123194430 (id 1002) | par | Consultar historial (JSON de la API) | 1 apuesta y catálogo | 1 apuesta(s), 4 partidos, bankroll {'en_juego': '100.00', 'disponible': '900.00'} | ✔ |
| Prueba-2_1123194430 (id 1002) | impar | Consultar su saldo en el otro fragmento | usuario_inexistente | usuario_inexistente | ✔ |
| Prueba-1_1123194430 | impar | Cerrar sesión y validar el token otra vez | token sin efecto (NULL) | cerrada=True, validar=None | ✔ |

## 5. Dónde quedó cada registro (comprobado como administrador)

| Cuenta | Instancia | Usuario/bankroll/apuestas/movimientos · saldo | Esperado |
| --- | --- | --- | --- |
| Prueba-1_1123194430 (id 1001) | `ensayo-nodo-a-primario-impar` | 1/1/1/3 · 1100.00 / 0.00 | 1/1/1/3 · 1100.00 / 0.00 |
| Prueba-1_1123194430 (id 1001) | `ensayo-nodo-b-replica-impar` | 1/1/1/3 · 1100.00 / 0.00 | 1/1/1/3 · 1100.00 / 0.00 |
| Prueba-1_1123194430 (id 1001) | `ensayo-nodo-b-primario-par` | 0/0/0/0 · — | 0/0/0/0 · — |
| Prueba-1_1123194430 (id 1001) | `ensayo-nodo-a-replica-par` | 0/0/0/0 · — | 0/0/0/0 · — |
| Prueba-2_1123194430 (id 1002) | `ensayo-nodo-a-primario-impar` | 0/0/0/0 · — | 0/0/0/0 · — |
| Prueba-2_1123194430 (id 1002) | `ensayo-nodo-b-replica-impar` | 0/0/0/0 · — | 0/0/0/0 · — |
| Prueba-2_1123194430 (id 1002) | `ensayo-nodo-b-primario-par` | 1/1/1/2 · 900.00 / 100.00 | 1/1/1/2 · 900.00 / 100.00 |
| Prueba-2_1123194430 (id 1002) | `ensayo-nodo-a-replica-par` | 1/1/1/2 · 900.00 / 100.00 | 1/1/1/2 · 900.00 / 100.00 |
