# BANKDOIT | Registro de apuestas y control del saldo

## Consultar el saldo
GET /usuarios/{usuario_id}/bankroll devuelve el saldo disponible y el monto en juego.

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

En una segunda ventana de PowerShell, registrar una apuesta y resolverla:

```powershell
$url = 'http://127.0.0.1:8000/usuarios/3'
$cabecera = @{'Idempotency-Key' = [guid]::NewGuid().ToString()}
$datos = '{"partido_id":101,"seleccion":"Local","monto":"100.00","cuota":"2.00"}'
$registro = Invoke-RestMethod "$url/apuestas" -Method Post -Headers $cabecera -ContentType 'application/json' -Body $datos
$registro.bankroll
$reenvio = Invoke-RestMethod "$url/apuestas" -Method Post -Headers $cabecera -ContentType 'application/json' -Body $datos
$reenvio.apuesta.id -eq $registro.apuesta.id
$resuelta = Invoke-RestMethod "$url/apuestas/$($registro.apuesta.id)/resultado" -Method Put -ContentType 'application/json' -Body '{"resultado":"ganada"}'
$resuelta.bankroll
```

En la primera ejecución, el registro devuelve `{"disponible":"900.00","en_juego":"100.00"}`, el reenvío imprime `True` y la liquidación devuelve `{"disponible":"1100.00","en_juego":"0.00"}`. La respuesta de registro incluye el objeto `apuesta` (id, partido, selección, monto, cuota y estado) y el objeto `bankroll`. El primer envío devuelve 201 y repetirlo devuelve 200. Para comprobar las tres resoluciones con datos iniciales independientes, ejecutar `python -m pytest -q`.
