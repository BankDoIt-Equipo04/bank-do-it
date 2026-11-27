# Evidencia: respaldo y restauración de PostgreSQL (#57)

Generado por `database/distribuido/probar_respaldos.ps1` el 2026-11-27 15:06 sobre la simulación de dos nodos (proyecto `bankdoit-ensayo`).

## Respaldo 20261127-150548

| Fragmento | Primario | Respaldo lógico | Respaldo físico | WAL archivado | Usuarios / apuestas / movimientos | Retención |
| --- | --- | --- | --- | ---: | --- | --- |
| impar | `ensayo-nodo-a-primario-impar` | `logico/impar/bankdoit_impar_20261127-150548.dump` (82,784 B, sha256 `c88c194b7548…`) | `base/impar/20261127-150548` (4,767,806 B) | 5 | 3 / 5 / 10 | 1 conservados, 1 eliminados; físicos: 2 conservados (más antiguo 20261127-145954) |
| par | `ensayo-nodo-b-primario-par` | `logico/par/bankdoit_par_20261127-150548.dump` (69,059 B, sha256 `7a8ad96cfae2…`) | `base/par/20261127-150548` (4,450,960 B) | 4 | 4 / 2 / 6 | 1 conservados, 1 eliminados; físicos: 2 conservados (más antiguo 20261127-145954) |

## Recuperación a un punto en el tiempo

1. Apuesta válida `pitr-buena-150608` (usuario 3).
2. `SELECT pg_create_restore_point('antes_del_error_150608')` con 3 cuentas activas.
3. Error simulado: `UPDATE cuenta SET estado = 'suspendida'` (quedaron 0 activas).
4. Recuperación en un contenedor aislado con `base/impar/20261127-150548` + `wal/impar` y `recovery_target_name = 'antes_del_error_150608'`.

## Comprobaciones

| Sección | Prueba | Esperado | Obtenido | |
| --- | --- | --- | --- | --- |
| Configuración | Archivado de WAL en ensayo-nodo-b-primario-par | archive_mode = on | archive_mode = on | ✔ |
| Configuración | Archivado de WAL en ensayo-nodo-a-primario-impar | archive_mode = on | archive_mode = on | ✔ |
| Respaldo | respaldar.ps1 en ambos fragmentos | respaldo generado | respaldo 20261127-150548 | ✔ |
| Restauración impar | Integridad del archivo (impar) | sha256 igual al manifiesto | c88c194b7548… | ✔ |
| Restauración impar | pg_restore del respaldo impar | sin errores | sin errores | ✔ |
| Restauración impar | Conteos restaurados (impar) | usuarios 3, bankrolls 3, apuestas 5, movimientos 10, partidos 4 | usuarios 3, bankrolls 3, apuestas 5, movimientos 10, partidos 4 | ✔ |
| Restauración impar | Saldos restaurados (impar) | disponible 2010.00 / en juego 130.00 | disponible 2010.00 / en juego 130.00 | ✔ |
| Restauración impar | Llaves, restricciones y triggers (impar) | 68 restricciones, 6 triggers | 68 restricciones, 6 triggers | ✔ |
| Restauración impar | Conciliación tras restaurar (impar) | todos los bankrolls cuadran | todos cuadran | ✔ |
| Restauración par | Integridad del archivo (par) | sha256 igual al manifiesto | 7a8ad96cfae2… | ✔ |
| Restauración par | pg_restore del respaldo par | sin errores | sin errores | ✔ |
| Restauración par | Conteos restaurados (par) | usuarios 4, bankrolls 4, apuestas 2, movimientos 6, partidos 4 | usuarios 4, bankrolls 4, apuestas 2, movimientos 6, partidos 4 | ✔ |
| Restauración par | Saldos restaurados (par) | disponible 2800.00 / en juego 300.00 | disponible 2800.00 / en juego 300.00 | ✔ |
| Restauración par | Llaves, restricciones y triggers (par) | 58 restricciones, 9 triggers | 58 restricciones, 9 triggers | ✔ |
| Restauración par | Conciliación tras restaurar (par) | todos los bankrolls cuadran | todos cuadran | ✔ |
| PITR | WAL con el error archivado | 000000010000000000000009 | 000000010000000000000009 archivado | ✔ |
| PITR | Recuperación del respaldo físico + WAL | promovida en el punto marcado | recuperación completa | ✔ |
| PITR | Se detuvo en el punto de restauración | antes_del_error_150608 | antes_del_error_150608 | ✔ |
| PITR | La apuesta válida (antes del punto) existe | 1 apuesta | 1 apuesta | ✔ |
| PITR | Las cuentas quedan como antes del error | 3 activas | 3 activas | ✔ |
| PITR | Conciliación en la base recuperada | todos cuadran | t | ✔ |
| PITR | Instalación de ensayo devuelta a su estado | 3 activas | 3 activas | ✔ |
| Retención | Conserva los 7 días más recientes | 7 días | 7 días | ✔ |
| Retención | Uno por día y semanales de 4 semanas | 7 a 11 respaldos, uno por día | 9 respaldos: 20261127, 20261126, 20261125, 20261124, 20261123, 20261122, 20261121, 20261115, 20261108 | ✔ |
| Retención | Los roles se borran junto con su respaldo | 0 archivos sueltos | 0 sueltos | ✔ |
