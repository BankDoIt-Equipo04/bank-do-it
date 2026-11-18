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
