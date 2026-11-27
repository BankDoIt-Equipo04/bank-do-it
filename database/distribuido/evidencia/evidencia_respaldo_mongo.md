# Evidencia: respaldo y restauración de MongoDB (#58)

Generado por `analytics/probar_respaldo_mongo.ps1` el 2026-11-27 15:38 con un MongoDB de ensayo aislado (proyecto `bankdoit-analytics-ensayo`, puerto 27018).

Respaldo `mongo_20261127-153806.archive.gz` (16786 bytes, sha256 `b21d1e32ba81…`) de la base `bankdoit_analytics`:

| Resumen (sha256 del CSV) | Archivo | Hora de corte (UTC) | Filas leídas | Válidas | Apuestas | Monto (centavos) | Partidos |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: |
| `7cd3ab2c01b3…` | BANKDOIT_apuestas_100000.csv | 2026-11-27T21:37:58.855Z | 100000 | 99600 | 99600 | 1293797000 | 1200 |
| `915d79bba659…` | BANKDOIT_apuestas_50000.csv | 2026-11-27T21:38:03.525Z | 50000 | 49841 | 49841 | 645923700 | 1200 |

## Comprobaciones

| Prueba | Esperado | Obtenido | |
| --- | --- | --- | --- |
| MongoDB de ensayo listo | puerto 27018 | puerto 27018 | ✔ |
| Cortes publicados en el MongoDB de ensayo | 2 resúmenes | 2 resúmenes (BANKDOIT_apuestas_100000.csv: 99600 válidas; BANKDOIT_apuestas_50000.csv: 49841 válidas) | ✔ |
| mongodump de bankdoit_analytics | respaldo generado | mongo_20261127-153806.archive.gz | ✔ |
| Arranque del MongoDB limpio | listo | listo | ✔ |
| Integridad del archivo | sha256 igual al manifiesto | b21d1e32ba81… | ✔ |
| mongorestore | sin errores | sin errores | ✔ |
| Contenido restaurado igual al original | mismos documentos, cortes y cifras | 2 resúmenes idénticos | ✔ |
| Horas de corte conservadas | 2026-11-27T21:37:58.855Z, 2026-11-27T21:38:03.525Z | 2026-11-27T21:37:58.855Z, 2026-11-27T21:38:03.525Z | ✔ |
| Colección recuperada tras borrarla | mismos resúmenes y horas de corte | 2 resúmenes recuperados | ✔ |
| Reprocesar el CSV después de restaurar | conserva la hora de corte original | sin cambios | ✔ |
| Conserva los 7 días más recientes | 7 días | 7 días | ✔ |
| Uno por día y semanales de 4 semanas | 7 a 11, uno por día | 9: 20261127, 20261126, 20261125, 20261124, 20261123, 20261122, 20261121, 20261115, 20261108 | ✔ |
| Manifiestos borrados junto con su respaldo | 0 sueltos | 0 sueltos | ✔ |
