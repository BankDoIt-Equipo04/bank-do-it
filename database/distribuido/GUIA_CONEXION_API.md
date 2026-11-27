# Guía para conectar la API a PostgreSQL distribuido

Issue #32. Responsable: Osvaldo Yair Serna Salazar. Para: Luis Fernando Barragán Medina (#33).

Esta guía deja dos conexiones verificadas, una a cada primario, con la cuenta `bankdoit_api` y TLS. La evidencia de la última ejecución está en [evidencia/evidencia_conexion_api.md](evidencia/evidencia_conexion_api.md).

## 1. Qué hay en cada primario

| Conexión | Contenedor | Puerto local | Contiene |
| --- | --- | --- | --- |
| **impar** (Nodo A) | `nodo-a-primario-impar` | 5441 | Usuarios con `usuario_id` impar, catálogo (dueño) y **directorio de cuentas y sesiones** |
| **par** (Nodo B) | `nodo-b-primario-par` | 5451 | Usuarios con `usuario_id` par y copia del catálogo |

Las réplicas (`nodo-a-replica-par` :5442 y `nodo-b-replica-impar` :5452) son de solo lectura y no las usa la API en operación normal.

### Roles

| Rol | Uso | Quién lo usa |
| --- | --- | --- |
| `bankdoit` (`POSTGRES_USER`) | Administración, dueño del esquema | Osvaldo, mantenimiento |
| `replicador` | Replicación física y suscripción del catálogo | Los contenedores |
| `bankdoit_api` | **La API.** Solo ejecuta funciones y lee el catálogo; sin acceso a tablas ni privilegios de administración | Luis |

## 2. Levantar el entorno

Desde PowerShell, en `database\distribuido` (Docker Desktop abierto):

```powershell
Copy-Item .env.example .env        # solo la primera vez; pon contraseñas propias
.\generar_certificados.ps1         # CA de pruebas y certificados (carpeta certs\, no se sube)
.\levantar_y_probar.ps1            # nodos, réplicas, catálogo y datos de ejemplo
.\configurar_acceso_api.ps1        # rol bankdoit_api, directorio, TLS y verificación
```

Debe terminar con `>>> TODAS LAS COMPROBACIONES PASARON`. `configurar_acceso_api.ps1` se puede repetir sin borrar ni duplicar datos.

Para comprobar que ambos primarios están listos:

```powershell
docker exec nodo-a-primario-impar pg_isready
docker exec nodo-b-primario-par pg_isready
```

## 3. Credenciales y certificado (fuera del repositorio)

- La contraseña de `bankdoit_api` está en `database\distribuido\.env` como `BANKDOIT_API_PASSWORD`. `.env` está en `.gitignore`. Osvaldo te la comparte por un medio privado, nunca en GitHub.
- El certificado de confianza es `database\distribuido\certs\ca.crt`. Solo necesitas ese archivo; **no copies los `.key`**. La carpeta `certs\` está ignorada por Git.

## 4. Variables para la API

| Variable | Valor |
| --- | --- |
| `BANKDOIT_PG_IMPAR_DSN` | Conexión al primario impar (también aloja el directorio) |
| `BANKDOIT_PG_PAR_DSN` | Conexión al primario par |
| `BANKDOIT_PG_DIRECTORIO_DSN` | Opcional; por omisión, el mismo que el impar |
| `BANKDOIT_PG_PASSWORD` | Contraseña de `bankdoit_api` |

Cadenas de ejemplo (sin secretos):

```
BANKDOIT_PG_IMPAR_DSN=host=localhost hostaddr=127.0.0.1 port=5441 dbname=bankdoit user=bankdoit_api sslmode=verify-full sslrootcert=C:/ruta/a/bank-do-it/database/distribuido/certs/ca.crt
BANKDOIT_PG_PAR_DSN=host=localhost hostaddr=127.0.0.1 port=5451 dbname=bankdoit user=bankdoit_api sslmode=verify-full sslrootcert=C:/ruta/a/bank-do-it/database/distribuido/certs/ca.crt
```

- `sslmode=verify-full` cifra la conexión y comprueba que el servidor tenga un certificado firmado por `ca.crt` **y** que su nombre coincida con `host`.
- `host` es el **nombre** que se valida contra el certificado y `hostaddr` la **IP** a la que se conecta. La `libpq` que trae `psycopg[binary]` 3.2 (libpq 14) no valida certificados contra una IP, por eso no basta con `host=127.0.0.1`.

## 5. Consulta de prueba con cada conexión

```powershell
cd database\distribuido
.\cliente\.venv\Scripts\python.exe -c "import os, psycopg; [print(psycopg.connect(os.environ[v], password=os.environ['BANKDOIT_PG_PASSWORD']).execute('SELECT current_user, (SELECT nombre FROM fragmento_local), (SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid())').fetchone()) for v in ('BANKDOIT_PG_IMPAR_DSN', 'BANKDOIT_PG_PAR_DSN')]"
```

Resultado esperado: `('bankdoit_api', 'impar', True)` y `('bankdoit_api', 'par', True)`.

El cliente completo, que además sirve de ejemplo de código, es [cliente/verificar_conexion_api.py](cliente/verificar_conexion_api.py).

## 6. Operaciones disponibles para la API

Todas son funciones; se llaman con `SELECT`. Los errores de negocio llegan como `SQLSTATE P0001` con un mensaje estable (`exc.diag.message_primary` en psycopg).

### En el fragmento del usuario (impar o par según `usuario_id % 2`)

| Ruta actual de la API | Función | Devuelve | Errores |
| --- | --- | --- | --- |
| `GET /usuarios/{id}/historial` | `consultar_historial(usuario_id)` | `jsonb` con la misma forma que hoy: `bankroll`, `presupuesto`, `apuestas`, `partidos` | `usuario_inexistente` |
| `GET /usuarios/{id}/bankroll` | `consultar_bankroll(usuario_id)` | `saldo_disponible, monto_en_juego, limite_semanal, apostado_semana` | `usuario_inexistente` |
| `POST /usuarios/{id}/apuestas` | `registrar_apuesta(usuario_id, clave, partido_id, seleccion, monto, cuota, origen)` | `apuesta_id, estado, saldo_disponible, monto_en_juego, es_reenvio` | `saldo_insuficiente`, `clave_reutilizada`, `partido_inexistente`, `partido_no_disponible`, `monto_invalido`, `cuota_invalida` |
| `PUT /usuarios/{id}/apuestas/{a}/resultado` | `resolver_apuesta(usuario_id, apuesta_id, resultado)` | igual que la anterior | `apuesta_inexistente`, `resultado_en_conflicto`, `resultado_invalido` |
| Registro (paso 2) | `crear_usuario(alias, 'cuenta-en-directorio', saldo_inicial, limite_semanal, 'usuario', usuario_id)` | `usuario_id` | `23505` si ya existe |
| #36 | `registrar_aportacion(usuario_id, importe)` / `registrar_retiro(usuario_id, importe)` | `saldo_disponible, monto_en_juego` | `importe_invalido`, `saldo_insuficiente` |

`es_reenvio = true` corresponde a tu HTTP 200 y `false` a HTTP 201.

### En el directorio (primario impar)

| Ruta actual | Función | Devuelve | Errores |
| --- | --- | --- | --- |
| `POST /auth/registro` (paso 1) | `registrar_cuenta(alias, sal, clave_derivada)` | `usuario_id` nuevo (1001, 1002, …) | `alias_duplicado` (sin distinguir mayúsculas), `cuenta_invalida` |
| `POST /auth/registro` (paso 3) | `activar_cuenta(usuario_id)` | — | `cuenta_inexistente` |
| `POST /auth/login` | `buscar_cuenta(alias)` | `usuario_id, alias, sal, clave_derivada, rol, estado` (comparas el PBKDF2 en Python) | sin filas si no existe |
| Login correcto | `crear_sesion(huella, usuario_id, vence)` | — | `cuenta_no_activa` |
| Cada petición con token | `validar_sesion(huella)` | `usuario_id` o `NULL` | — |
| `POST /auth/logout` | `cerrar_sesion(huella)` | `true` si existía | — |

`huella` = `sha256(token)` en bytes (32), igual que en tu `cuentas.py`. El token nunca se guarda.

## 7. Lo que implementas tú en Python

1. **Elegir la conexión por usuario:**

   ```python
   def fragmento_de(usuario_id: int) -> str:
       return "impar" if usuario_id % 2 else "par"
   ```

   Abre `BANKDOIT_PG_IMPAR_DSN` o `BANKDOIT_PG_PAR_DSN` según el resultado. Para registro, login y sesiones usa siempre el directorio (impar). Un usuario consultado en el fragmento equivocado devuelve `usuario_inexistente`.

2. **Registro en tres pasos (dos bases distintas):**
   1. `registrar_cuenta` en el directorio devuelve el `usuario_id`.
   2. `crear_usuario(..., usuario_id)` en su fragmento. Si responde llave duplicada (`23505`), el bankroll ya existía por un intento anterior: continúa.
   3. `activar_cuenta` en el directorio. Mientras no se active, `crear_sesion` responde `cuenta_no_activa`.

   Si el paso 2 falla por red, repite 2 y 3 con el mismo `usuario_id`; no vuelvas a llamar a `registrar_cuenta`.

3. **Conservar la clave de operación en los reintentos:** usa la `Idempotency-Key` que manda Flutter como `clave` de `registrar_apuesta`, y en un reintento envía **la misma clave con los mismos datos**. Si es la misma, la función devuelve la apuesta original sin cobrar otra vez; si cambian los datos, responde `clave_reutilizada`.

4. **No canceles una escritura que espera a la réplica.** Con replicación síncrona, si el otro nodo no responde, el `COMMIT` queda en espera. No uses `statement_timeout` ni canceles la consulta: PostgreSQL dejaría la operación confirmada en el primario sin copia. Responde "pendiente" y deja que Flutter reenvíe con la misma clave (#18).

5. **Autocommit:** cada función es una transacción completa. Usa `autocommit=True` o confirma justo después de cada llamada.

6. **Dependencia:** agrega `psycopg[binary]==3.2.3` a `backend/requirements.txt`.

## 8. Resultados de la verificación

Resultados del cliente con el rol `bankdoit_api` (ejecución del 23/11/2026 en el ensayo aislado; detalle completo en la evidencia):

| Usuario de prueba | Fragmento esperado | Operación | Resultado esperado | Resultado obtenido |
| --- | --- | --- | --- | --- |
| cuenta impar (id 1001) | impar · Nodo A | Crear bankroll con $1,000 | 1000.00 / 0.00 | 1000.00 / 0.00 ✔ |
| cuenta par (id 1002) | par · Nodo B | Crear bankroll con $1,000 | 1000.00 / 0.00 | 1000.00 / 0.00 ✔ |
| ambas | ambos | Partido 101 en los dos fragmentos | mismo id, equipos y fecha | América vs. Chivas en ambos ✔ |
| cuenta impar | impar | Apuesta de $100 a 2.00 | 900.00 / 100.00 | 900.00 / 100.00 ✔ |
| cuenta impar | impar | Reenvío con la misma clave | misma apuesta, sin segundo cargo | misma apuesta, `es_reenvio = true` ✔ |
| cuenta impar | impar | Resolver como ganada | 1100.00 / 0.00 | 1100.00 / 0.00 ✔ |
| cuenta par | par | Apuesta de $100 a 2.00 (queda pendiente) | 900.00 / 100.00 | 900.00 / 100.00 ✔ |
| cuenta par | impar | Consultar su saldo en el otro fragmento | `usuario_inexistente` | `usuario_inexistente` ✔ |
| directorio | impar | Alias repetido con otras mayúsculas | `alias_duplicado` | `alias_duplicado` ✔ |
| ambas | réplica del otro nodo | Datos en la réplica | igual que en su primario | igual ✔ |
| conexión | ambos | Sin TLS / CA ajena / nombre distinto | rechazada | rechazada ✔ |

La tabla completa (41 comprobaciones) y la ubicación de cada registro en las cuatro instancias están en la evidencia.

### Comprobado en SQL y pendiente de probar juntos desde Python

| Ya comprobado (cliente psycopg contra PostgreSQL) | Pendiente con la API real (#33) |
| --- | --- |
| Conexión TLS `verify-full` a ambos primarios con `bankdoit_api` | Rutas de FastAPI llamando a estas funciones |
| Permisos mínimos del rol | Mapeo de errores a HTTP (201/200, 404, 409, 422) |
| Registro en tres pasos, alias único, sesiones | Login completo con PBKDF2 y token Bearer |
| Apuesta, reenvío sin doble cargo, resolución, historial | La prueba del #12 desde Flutter con un usuario par y uno impar |
| Datos en el fragmento y la réplica correctos | Reintentos ante caída de un nodo |

## 9. Diferencias con la API actual que hay que acordar

- **Presupuesto semanal:** la API actual suma todas las apuestas de los últimos días desde el lunes; `apostado_semana` suma de lunes a domingo (hora del centro de México) y **excluye las anuladas**. El rechazo por exceso del límite (`exceso_aceptado`) sigue en la API.
- **Fotos:** la API guarda la imagen dentro de la base; el esquema guarda solo la ruta privada (`recuerdo.ruta_objeto`). Falta decidir dónde se guardan los archivos.
- **`hash_contrasena` del fragmento:** la credencial real vive en el directorio, así que al crear el bankroll se pasa el marcador `cuenta-en-directorio`.

## 10. Falta probar entre los dos equipos físicos

Todo lo anterior se probó con los cuatro contenedores en una sola PC. En el despliegue real falta:

1. Conectividad entre la PC de escritorio de Luis (Nodo A) y su laptop (Nodo B): la misma red local o, si están en lugares distintos, una VPN; y la IP de cada uno.
2. Generar los certificados con el nombre de cada equipo, por ejemplo `$env:NODO_B_SAN_EXTRA='DNS:nodo-b.bankdoit,IP:100.64.0.12'`, y conectarse con `host=nodo-b.bankdoit hostaddr=100.64.0.12`.
3. Ajustar en `.env` `API_ORIGEN_CIDR` y `RED_CIDR` a la subred real por la que llegan la API y la replicación, y volver a correr `configurar_acceso_api.ps1`.
4. Repetir la verificación y medir la latencia de la replicación síncrona entre casas.
