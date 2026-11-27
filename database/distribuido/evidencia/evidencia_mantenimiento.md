# Evidencia: procedimiento de mantenimiento (#56)

Generado por `database/distribuido/probar_mantenimiento.ps1` el 2026-11-27 14:43 sobre la simulación de dos nodos (proyecto `bankdoit-ensayo`).

```sql
CALL mantenimiento_diario(1000);   -- primario impar
CALL mantenimiento_diario();       -- primario par
```

Mensajes del procedimiento:

```
NOTICE:  Mantenimiento impar: 2500 sesiones vencidas eliminadas en 3 lotes; 0 de 3 bankrolls no cuadran.
NOTICE:  Mantenimiento par: 0 sesiones vencidas eliminadas en 0 lotes; 1 de 4 bankrolls no cuadran.
WARNING:  Bankrolls descuadrados en el fragmento par: [{"usuario_id": 4, "saldo_bankroll": 601.00, "en_juego_apuestas": 200.00, "en_juego_bankroll": 200.00, "saldo_movimientos": 600.00}]
```

## Comprobaciones

| Prueba | Esperado | Obtenido | |
| --- | --- | --- | --- |
| Instalar de nuevo en ensayo-nodo-a-primario-impar | sin errores | sin errores | ✔ |
| Instalar de nuevo en ensayo-nodo-b-primario-par | sin errores | sin errores | ✔ |
| La reinstalación conserva la bitácora de ensayo-nodo-a-primario-impar | 1 registros | 1 registros | ✔ |
| La reinstalación conserva la bitácora de ensayo-nodo-b-primario-par | 2 registros | 2 registros | ✔ |
| Es un procedimiento (pg_proc.prokind) | p | p | ✔ |
| CALL en ambos primarios | sin errores | sin errores | ✔ |
| Sesiones vencidas tras el CALL (impar) | 0 | 0 | ✔ |
| Sesiones vigentes conservadas (impar) | 9 | 9 | ✔ |
| Bitácora impar: sesiones y lotes de 1000 | 2500 sesiones en 3 lotes | 2500 sesiones en 3 lotes | ✔ |
| Bitácora impar: bankrolls descuadrados | 0 de 3 | 0 de 3 | ✔ |
| Bitácora par: sin tabla de sesiones | 0 sesiones, 0 lotes | 0 sesiones, 0 lotes | ✔ |
| Bitácora par: detecta el descuadre simulado | 1 descuadre (usuario 4) | 1 descuadre(s) (usuario 4) | ✔ |
| bankdoit_api intenta CALL mantenimiento_diario() | permiso denegado | ERROR:  permission denied for procedure mantenimiento_diario | ✔ |
| bankdoit_api intenta leer la bitácora | permiso denegado | ERROR:  permission denied for table bitacora_mantenimiento | ✔ |
| CALL en una réplica | solo_en_primario | ERROR:  solo_en_primario | ✔ |
| La bitácora impar está en su réplica (Nodo B) | mismos registros | 2 registros | ✔ |
| La limpieza de sesiones llegó a la réplica | 0 vencidas | 0 vencidas | ✔ |
| Tras corregir el saldo, el siguiente CALL | 0 descuadres | 0 descuadres | ✔ |

## Últimos registros de `bitacora_mantenimiento`

| Ejecución | Fecha (CDMX) | Fragmento | Sesiones eliminadas | Lotes | Bankrolls revisados | Descuadrados | Duración (ms) |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: |
| 2 | 2026-11-27 14:43:39 | impar | 2500 | 3 | 3 | 0 | 444 |
| 1 | 2026-11-27 14:42:45 | impar | 2500 | 3 | 3 | 0 | 77 |
| 4 | 2026-11-27 14:43:47 | par | 0 | 0 | 4 | 0 | 5 |
| 3 | 2026-11-27 14:43:40 | par | 0 | 0 | 4 | 1 | 7 |
| 2 | 2026-11-27 14:42:52 | par | 0 | 0 | 4 | 0 | 6 |
