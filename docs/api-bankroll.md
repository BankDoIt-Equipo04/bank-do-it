# BANKDOIT | Registro de apuestas y control del saldo

## Registro e inicio de sesión para Flutter

| Operación | Solicitud JSON | Respuesta |
| --- | --- | --- |
| `POST /auth/registro` | `{"alias":"luis_demo","password":"ClaveDePrueba123","saldo_inicial":"1000.00"}` | 201 con `usuario_id` y `alias`. Un alias repetido devuelve 409. |
| `POST /auth/login` | `{"alias":"luis_demo","password":"ClaveDePrueba123"}` | 200 con `usuario_id`, `alias`, `access_token`, `token_type` y `expires_in` en segundos. |
| `POST /auth/login` | `{"alias":"luis_demo","password":"incorrecta"}` | 401 con `{"detail":"Alias o contraseña incorrectos."}`. |
| `POST /auth/logout` | Sin cuerpo, con la cabecera de sesión | 204. El token deja de funcionar. |

En Flutter usa el `usuario_id` devuelto al iniciar sesión y envía `Authorization: Bearer <access_token>` en cada consulta o cambio de saldo, apuestas, historial y fotos. Conserva también `Idempotency-Key` al registrar una apuesta. La sesión dura 24 horas. Un token inválido o vencido devuelve 401. Una ruta de otro usuario devuelve 404. Al cerrar sesión, descarta el token y carga los borradores correspondientes a la siguiente cuenta.

Para el registro, usa un alias de 3 a 40 letras ASCII, números, puntos, guiones o guiones bajos y una contraseña de 8 a 128 caracteres. El saldo inicial es simulado y puede ser cero.

## Consultar el saldo
GET /usuarios/{usuario_id}/bankroll devuelve el saldo disponible y el monto en juego.

## Contrato propuesto para la pantalla Bankroll (#36 y #37)

Flutter usa la misma sesión y el mismo usuario que en «Mis apuestas». Estas son las rutas propuestas para la integración con el #36. Los importes JSON se expresan como cadenas con dos decimales.

| Operación | Solicitud y resultado esperado |
| --- | --- |
| `GET /usuarios/{usuario_id}/bankroll/movimientos` | Devuelve `{"movimientos":[{"tipo":"retiro","fecha":"2026-11-24T12:00:00Z","cambio_disponible":"-30.00"}]}`, del más reciente al más antiguo. Una lista vacía indica que aún no hay movimientos. |
| `POST /usuarios/{usuario_id}/bankroll/movimientos` | Recibe `{"tipo":"aportacion","monto":"50.00"}` o `{"tipo":"retiro","monto":"30.00"}`. Usa `Idempotency-Key`. Si Flutter pierde la respuesta, reenvía el mismo importe con la misma clave. Un retiro sin fondos devuelve 409 con `{"detail":"saldo_insuficiente"}`. |
| `PUT /usuarios/{usuario_id}/presupuesto` | Recibe `{"limite":"250.00"}` y actualiza el presupuesto semanal de la cuenta. |

Después de una escritura confirmada (respuesta 2xx con objeto JSON o 204), Flutter vuelve a consultar el historial y los movimientos. Para reproducir la prueba de interfaz con respuestas simuladas, ejecuta `flutter test test/bankroll_test.dart` desde `mobile`. Al integrar el #36, repitan con la API real la aportación, el retiro rechazado, el retiro válido y el cambio de límite.

## Registrar una apuesta
POST /usuarios/{usuario_id}/apuestas

Ejemplo de datos enviados por Flutter:
{"partido_id": 42, "seleccion": "Iowa gana", "monto": "100.00", "cuota": "2.00"}

La API valida que el monto sea positivo, que la cuota sea mayor a 1 y que haya saldo suficiente. Al aceptar la apuesta, la marca como pendiente y reserva el monto en una sola operación.

Ejemplo: con $1,000 iniciales, una apuesta de $100 deja $900 disponibles y $100 en juego.

## Resolver una apuesta
PUT /usuarios/{usuario_id}/apuestas/{apuesta_id}/resultado

Ejemplo: {"resultado": "ganada"}

| Resultado | Saldo disponible final | Monto en juego |
| --- | ---: | ---: |
| Ganada a cuota 2.00 | $1,100 | $0 |
| Perdida | $900 | $0 |
| Anulada | $1,000 | $0 |

## Evitar un cargo duplicado
Flutter guarda una clave única con cada borrador y la envía en el encabezado Idempotency-Key. Si se pierde la conexión, reenvía la misma apuesta con la misma clave.

Prueba: enviar dos veces la apuesta de $100 con la misma clave. Ambos envíos deben devolver el mismo identificador de apuesta. Debe quedar una sola apuesta, un solo cargo, $900 disponibles y $100 en juego.

## Probar la API en la computadora

Desde PowerShell, dentro de `backend` y con el entorno virtual activo:

```powershell
python -m app.datos_demo
python -m uvicorn app.main:app --reload
```

Abrir http://127.0.0.1:8000/docs. La demo local utiliza SQLite y persiste al reiniciar. El primer arranque prepara los usuarios 3 ($1,000) y 4 ($800), y los partidos 42, 101 y 202. Volver a preparar la demo conserva las apuestas. La base distribuida de PostgreSQL se integrará al disponer del esquema del equipo.

En una segunda ventana de PowerShell, crea una cuenta de prueba e inicia sesión. Después registra una apuesta, reenvíala y resuélvela.

```powershell
$api = 'http://127.0.0.1:8000'
$alias = 'demo_' + [guid]::NewGuid().ToString('N')
$datosCuenta = @{alias=$alias; password='ClaveDePrueba123'; saldo_inicial='1000.00'}
Invoke-RestMethod "$api/auth/registro" -Method Post -ContentType 'application/json' -Body ($datosCuenta | ConvertTo-Json)
$ingreso = @{alias=$alias; password=$datosCuenta.password} | ConvertTo-Json
$sesion = Invoke-RestMethod "$api/auth/login" -Method Post -ContentType 'application/json' -Body $ingreso
$url = "$api/usuarios/$($sesion.usuario_id)"
$cabecera = @{Authorization="Bearer $($sesion.access_token)"; 'Idempotency-Key'=[guid]::NewGuid().ToString()}
$datos = '{"partido_id":101,"seleccion":"Local","monto":"100.00","cuota":"2.00"}'
$registro = Invoke-RestMethod "$url/apuestas" -Method Post -Headers $cabecera -ContentType 'application/json' -Body $datos
$registro.bankroll
$reenvio = Invoke-RestMethod "$url/apuestas" -Method Post -Headers $cabecera -ContentType 'application/json' -Body $datos
$reenvio.apuesta.id -eq $registro.apuesta.id
$resuelta = Invoke-RestMethod "$url/apuestas/$($registro.apuesta.id)/resultado" -Method Put -Headers $cabecera -ContentType 'application/json' -Body '{"resultado":"ganada"}'
$resuelta.bankroll
```

En la primera ejecución, el registro devuelve `{"disponible":"900.00","en_juego":"100.00"}`, el reenvío imprime `True` y la liquidación devuelve `{"disponible":"1100.00","en_juego":"0.00"}`. La respuesta de registro incluye el objeto `apuesta` (id, partido, selección, monto, cuota y estado) y el objeto `bankroll`. El primer envío devuelve 201 y repetirlo devuelve 200. Para comprobar las tres resoluciones con datos iniciales independientes, ejecutar `python -m pytest -q`.
