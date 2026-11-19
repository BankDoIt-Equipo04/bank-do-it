# Evidencia de pruebas de falla (#18)

Generado por `database/distribuido/probar_fallas.ps1` el 2026-11-18 20:18 (simulación de los dos nodos en una sola PC con Docker).

PostgreSQL: 16.4 (Debian 16.4-1.pgdg120+2) · Replicación física síncrona (`synchronous_commit = remote_apply`) · Catálogo por replicación lógica.

### Escenario 1: partición de red entre el Nodo A y el Nodo B

**Antes de la partición** — saldo disponible / en juego (movimientos, apuestas)

| Instancia | Estado | Usuario 3 | Usuario 4 |
| --- | --- | --- | --- |
| nodo-a-primario-impar | primario | 920.00 / 120.00 (5 mov, 3 ap) | — |
| nodo-b-replica-impar | réplica | 920.00 / 120.00 (5 mov, 3 ap) | — |
| nodo-b-primario-par | primario | — | 600.00 / 200.00 (2 mov, 1 ap) |
| nodo-a-replica-par | réplica | — | 600.00 / 200.00 (2 mov, 1 ap) |

Se desconectan de la red los dos contenedores del Nodo B: ningún nodo puede comunicarse con el otro, pero los cuatro siguen encendidos.

**Durante la partición (ninguna escritura confirmada; saldos sin cambios)** — saldo disponible / en juego (movimientos, apuestas)

| Instancia | Estado | Usuario 3 | Usuario 4 |
| --- | --- | --- | --- |
| nodo-a-primario-impar | primario | 920.00 / 120.00 (5 mov, 3 ap) | — |
| nodo-b-replica-impar | réplica | 920.00 / 120.00 (5 mov, 3 ap) | — |
| nodo-b-primario-par | primario | — | 600.00 / 200.00 (2 mov, 1 ap) |
| nodo-a-replica-par | réplica | — | 600.00 / 200.00 (2 mov, 1 ap) |

Se reconecta el Nodo B. Las réplicas vuelven a conectarse solas y los COMMIT que estaban en espera se confirman.

**Después de restablecer la red** — saldo disponible / en juego (movimientos, apuestas)

| Instancia | Estado | Usuario 3 | Usuario 4 |
| --- | --- | --- | --- |
| nodo-a-primario-impar | primario | 890.00 / 150.00 (6 mov, 4 ap) | — |
| nodo-b-replica-impar | réplica | 890.00 / 150.00 (6 mov, 4 ap) | — |
| nodo-b-primario-par | primario | — | 560.00 / 240.00 (3 mov, 2 ap) |
| nodo-a-replica-par | réplica | — | 560.00 / 240.00 (3 mov, 2 ap) |


### Escenario 2: caída del primario par (Nodo B) y recuperación controlada

**Antes de la caída** — saldo disponible / en juego (movimientos, apuestas)

| Instancia | Estado | Usuario 3 | Usuario 4 |
| --- | --- | --- | --- |
| nodo-a-primario-impar | primario | 890.00 / 150.00 (6 mov, 4 ap) | — |
| nodo-b-replica-impar | réplica | 890.00 / 150.00 (6 mov, 4 ap) | — |
| nodo-b-primario-par | primario | — | 560.00 / 240.00 (3 mov, 2 ap) |
| nodo-a-replica-par | réplica | — | 560.00 / 240.00 (3 mov, 2 ap) |

Se apaga de golpe `nodo-b-primario-par` (docker kill), como si el equipo remoto perdiera la corriente. La réplica impar del Nodo B sigue encendida.

**Con el primario par caído** — saldo disponible / en juego (movimientos, apuestas)

| Instancia | Estado | Usuario 3 | Usuario 4 |
| --- | --- | --- | --- |
| nodo-a-primario-impar | primario | 875.00 / 165.00 (7 mov, 5 ap) | — |
| nodo-b-replica-impar | réplica | 875.00 / 165.00 (7 mov, 5 ap) | — |
| nodo-b-primario-par | **caído** | — | — |
| nodo-a-replica-par | réplica | — | 560.00 / 240.00 (3 mov, 2 ap) |

**Paso 1 · Aislar:** `nodo-b-primario-par` queda apagado, sin reinicio automático y desconectado de la red. Así no puede volver como segundo primario (*split-brain*); su disco ya no se usa.

**Paso 2 · Promover:** `SELECT pg_promote()` en `nodo-a-replica-par`. Ahora es el primario del fragmento par (en el Nodo A); el directorio de la API debe apuntar los usuarios pares a esta instancia.

**Paso 3 · Resincronizar:** el equipo del Nodo B se reconstruye como `nodo-b-replica-par` con `pg_basebackup` desde el nuevo primario (ranura `replica_par`). Solo cuando la copia síncrona está al día se confirman las escrituras que estaban en espera.

**Paso 4 · Avanzar la visibilidad:** `SELECT txid_current()` en el nuevo primario. La réplica recién copiada trataba la apuesta que estaba en espera durante la copia como una transacción futura (su límite de visibilidad era ese mismo id) y no la mostraba hasta que terminara otra transacción. `pg_log_standby_snapshot()` y `CHECKPOINT` no lo resolvieron; una transacción nueva sí.

**Después de recuperar el servicio** — saldo disponible / en juego (movimientos, apuestas)

| Instancia | Estado | Usuario 3 | Usuario 4 |
| --- | --- | --- | --- |
| nodo-a-primario-impar | primario | 875.00 / 165.00 (7 mov, 5 ap) | — |
| nodo-b-replica-impar | réplica | 875.00 / 165.00 (7 mov, 5 ap) | — |
| nodo-b-primario-par | **caído** | — | — |
| nodo-a-replica-par | primario | — | 530.00 / 270.00 (5 mov, 4 ap) |
| nodo-b-replica-par | réplica | — | 530.00 / 270.00 (5 mov, 4 ap) |


### Operaciones en cada escenario

| Escenario | Operación | Instancia | Resultado | Detalle |
| --- | --- | --- | --- | --- |
| Partición de red | Consultar saldo del usuario 3 | `nodo-a-primario-impar` | Confirmada (lectura) | disponible 920.00 |
| Partición de red | Consultar saldo del usuario 3 en su réplica | `nodo-b-replica-impar` | Confirmada (lectura) | disponible 920.00 (último dato confirmado) |
| Partición de red | Consultar saldo del usuario 4 en su réplica | `nodo-a-replica-par` | Confirmada (lectura) | disponible 600.00 (último dato confirmado) |
| Partición de red | Registrar apuesta del usuario 3 ($30) | `nodo-a-primario-impar` | En espera (no confirmada) | COMMIT esperando a la réplica del Nodo B; nadie más la ve |
| Partición de red | Dar de alta un partido (catálogo) | `nodo-a-primario-impar` | En espera (no confirmada) | el catálogo también requiere la copia síncrona |
| Partición de red | Registrar apuesta del usuario 4 ($40) | `nodo-b-primario-par` | En espera (no confirmada) | COMMIT esperando a la réplica del Nodo A |
| Partición de red | Registrar apuesta en una réplica | `nodo-b-replica-impar` | Rechazada | las réplicas son de solo lectura |
| Partición de red | Reenviar el borrador del usuario 3 tras reconectar | `nodo-a-primario-impar` | Confirmada (sin doble cargo) | es_reenvio = t, reservas = 1 |
| Caída del primario | Consultar saldo del usuario 4 en su réplica | `nodo-a-replica-par` | Confirmada (lectura) | disponible 560.00 |
| Caída del primario | Registrar apuesta del usuario 4 | `nodo-b-primario-par` | Rechazada | su primario no está disponible; la app guarda el borrador |
| Caída del primario | Registrar apuesta del usuario 4 en su réplica | `nodo-a-replica-par` | Rechazada | la réplica todavía es de solo lectura |
| Caída del primario | Registrar apuesta del usuario 3 ($15) | `nodo-a-primario-impar` | Confirmada | su réplica (Nodo B) sigue arriba |
| Caída del primario | Registrar apuesta del usuario 4 en el primario promovido ($25) | `nodo-a-replica-par` | En espera (no confirmada) | no hay réplica síncrona todavía: no se confirma sin copia |
| Caída del primario | Registrar apuesta del usuario 4 tras recuperar ($5) | `nodo-a-replica-par` | Confirmada | apuesta_id 70 (par), replicada en nodo-b-replica-par |

### Movimientos después de las pruebas

| Instancia | Usuario | Tipo | Cambio disponible | Cambio en juego | Apuesta |
| --- | --- | --- | ---: | ---: | --- |
| `nodo-a-primario-impar` | 3 | saldo_inicial | 1000.00 | 0.00 | — |
| `nodo-a-primario-impar` | 3 | reserva | -100.00 | 100.00 | demo-ana-1 |
| `nodo-a-primario-impar` | 3 | reserva | -50.00 | 50.00 | demo-ana-2 |
| `nodo-a-primario-impar` | 3 | liquidacion | 90.00 | -50.00 | demo-ana-2 |
| `nodo-a-primario-impar` | 3 | reserva | -20.00 | 20.00 | vivo-ana |
| `nodo-a-primario-impar` | 3 | reserva | -30.00 | 30.00 | particion-ana |
| `nodo-a-primario-impar` | 3 | reserva | -15.00 | 15.00 | caida-ana |
| `nodo-a-replica-par` | 4 | saldo_inicial | 800.00 | 0.00 | — |
| `nodo-a-replica-par` | 4 | reserva | -200.00 | 200.00 | demo-beto-1 |
| `nodo-a-replica-par` | 4 | reserva | -40.00 | 40.00 | particion-beto |
| `nodo-a-replica-par` | 4 | reserva | -25.00 | 25.00 | promovido-beto |
| `nodo-a-replica-par` | 4 | reserva | -5.00 | 5.00 | post-recuperacion |
