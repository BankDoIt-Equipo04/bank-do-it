# Evidencia: monitoreo de PostgreSQL distribuido (#59)

Generado por `database/distribuido/probar_monitoreo.ps1` el 2026-11-27 16:04 sobre la simulación de dos nodos (proyecto `bankdoit-ensayo`). Prometheus: sí.

## Antes de la partición (2026-11-27 16:03:52)

| Instancia | Fragmento | Rol | Réplica sync | Esperando réplica | Retraso réplica | Conexiones | WAL archivado | Mantenimiento |
| --- | --- | --- | --- | ---: | --- | --- | --- | --- |
| `ensayo-nodo-a-primario-impar` | impar | primario | 1/1 | 0 | — | 2/100 | ok (13) | 0 descuadres |
| `ensayo-nodo-b-replica-impar` | impar | réplica | — | 0 | 0 s | 3/100 | ok (0) | 0 descuadres |
| `ensayo-nodo-b-primario-par` | par | primario | 1/1 | 0 | — | 3/100 | ok (9) | 0 descuadres |
| `ensayo-nodo-a-replica-par` | par | réplica | — | 0 | 0 s | 2/100 | ok (0) | 0 descuadres |

| Primario | Réplica | Estado | Sincronía | Bytes pendientes |
| --- | --- | --- | --- | ---: |
| `ensayo-nodo-a-primario-impar` | catalogo | streaming | async | 0 |
| `ensayo-nodo-a-primario-impar` | replica_impar | streaming | sync | 0 |
| `ensayo-nodo-b-primario-par` | replica_par | streaming | sync | 0 |

Sin alertas.

## Durante la partición (2026-11-27 16:04:19)

| Instancia | Fragmento | Rol | Réplica sync | Esperando réplica | Retraso réplica | Conexiones | WAL archivado | Mantenimiento |
| --- | --- | --- | --- | ---: | --- | --- | --- | --- |
| `ensayo-nodo-a-primario-impar` | impar | primario | 0/1 | 1 | — | 3/100 | ok (14) | 0 descuadres |
| `ensayo-nodo-b-replica-impar` | impar | réplica | — | 0 | 0 s | 3/100 | ok (0) | 0 descuadres |
| `ensayo-nodo-b-primario-par` | par | primario | 0/1 | 0 | — | 3/100 | ok (9) | 0 descuadres |
| `ensayo-nodo-a-replica-par` | par | réplica | — | 0 | 0 s | 2/100 | ok (0) | 0 descuadres |

- **ALERTA** ensayo-nodo-a-primario-impar no tiene su réplica síncrona: las escrituras no se pueden confirmar
- **ALERTA** ensayo-nodo-a-primario-impar tiene 1 escritura(s) esperando a la réplica (SyncRep)
- **ALERTA** ensayo-nodo-b-primario-par no tiene su réplica síncrona: las escrituras no se pueden confirmar

## Después de restablecer la red (2026-11-27 16:04:39)

| Instancia | Fragmento | Rol | Réplica sync | Esperando réplica | Retraso réplica | Conexiones | WAL archivado | Mantenimiento |
| --- | --- | --- | --- | ---: | --- | --- | --- | --- |
| `ensayo-nodo-a-primario-impar` | impar | primario | 1/1 | 0 | — | 2/100 | ok (14) | 0 descuadres |
| `ensayo-nodo-b-replica-impar` | impar | réplica | — | 0 | 0 s | 3/100 | ok (0) | 0 descuadres |
| `ensayo-nodo-b-primario-par` | par | primario | 1/1 | 0 | — | 3/100 | ok (9) | 0 descuadres |
| `ensayo-nodo-a-replica-par` | par | réplica | — | 0 | 0 s | 2/100 | ok (0) | 0 descuadres |

| Primario | Réplica | Estado | Sincronía | Bytes pendientes |
| --- | --- | --- | --- | ---: |
| `ensayo-nodo-a-primario-impar` | catalogo | streaming | async | 0 |
| `ensayo-nodo-a-primario-impar` | replica_impar | streaming | sync | 0 |
| `ensayo-nodo-b-primario-par` | replica_par | streaming | sync | 0 |

Sin alertas.

## Comprobaciones

| Fase | Prueba | Obtenido | |
| --- | --- | --- | --- |
| Antes | monitorear.ps1 sin alertas | 0 alertas | ✔ |
| Antes | Dos réplicas síncronas | catalogo=async, replica_impar=sync, replica_par=sync | ✔ |
| Antes | Prometheus: pg_up de las 4 instancias | nodo-a-replica-par=1, nodo-a-primario-impar=1, nodo-b-replica-impar=1, nodo-b-primario-par=1 | ✔ |
| Antes | Prometheus: réplica síncrona por primario | nodo-a-primario-impar=1, nodo-b-primario-par=1 | ✔ |
| Durante | Alerta: primario impar sin réplica síncrona | ensayo-nodo-a-primario-impar no tiene su réplica síncrona: las escrituras no se pueden confirmar / ensayo-nodo-a-primario-impar tiene 1 escritura(s) esperando a la réplica (SyncRep) | ✔ |
| Durante | Alerta: primario par sin réplica síncrona | ensayo-nodo-b-primario-par no tiene su réplica síncrona: las escrituras no se pueden confirmar | ✔ |
| Durante | Alerta: escrituras esperando a la réplica | ensayo-nodo-a-primario-impar tiene 1 escritura(s) esperando a la réplica (SyncRep) | ✔ |
| Durante | Prometheus: escrituras esperando en el primario impar | 1 | ✔ |
| Durante | Prometheus: instancias del Nodo B inalcanzables (pg_up = 0) | nodo-b-replica-impar, nodo-b-primario-par | ✔ |
| Después | monitorear.ps1 vuelve a cero alertas | 0 alertas | ✔ |
| Después | Prometheus: 4 instancias arriba y 0 escrituras en espera | nodo-a-replica-par=1, nodo-a-primario-impar=1, nodo-b-replica-impar=1, nodo-b-primario-par=1 | ✔ |
