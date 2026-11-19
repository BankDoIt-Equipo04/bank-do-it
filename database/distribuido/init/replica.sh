#!/bin/bash
# =====================================================================
# BANKDOIT · replica.sh  (#17)
# Arranque de una RÉPLICA física. La primera vez copia el primario con
# pg_basebackup y la deja en modo standby (solo lectura); después solo
# arranca PostgreSQL y sigue recibiendo el WAL del primario.
# Variables: PRIMARIO_HOST, PRIMARIO_PUERTO, REPLICA_NOMBRE,
#            REPLICADOR_PASSWORD.
# =====================================================================
set -euo pipefail
PGDATA="${PGDATA:-/var/lib/postgresql/data}"

if [ ! -s "$PGDATA/PG_VERSION" ]; then
    echo "[$REPLICA_NOMBRE] Esperando al primario $PRIMARIO_HOST:$PRIMARIO_PUERTO..."
    # El primario debe haber terminado su inicialización (ranura creada).
    until PGPASSWORD="$REPLICADOR_PASSWORD" psql -h "$PRIMARIO_HOST" -p "$PRIMARIO_PUERTO" \
            -U replicador -d "${POSTGRES_DB:-bankdoit}" -tAc \
            "SELECT 1 FROM pg_replication_slots WHERE slot_name = '$REPLICA_NOMBRE'" 2>/dev/null \
          | grep -q 1; do
        sleep 2
    done

    echo "[$REPLICA_NOMBRE] Copiando el primario con pg_basebackup..."
    PGPASSWORD="$REPLICADOR_PASSWORD" pg_basebackup \
        -h "$PRIMARIO_HOST" -p "$PRIMARIO_PUERTO" -U replicador \
        -D "$PGDATA" -X stream -S "$REPLICA_NOMBRE" -c fast -P

    # Conexión al primario y ranura; standby.signal = arrancar como réplica.
    cat >> "$PGDATA/postgresql.auto.conf" <<EOF
primary_conninfo = 'host=$PRIMARIO_HOST port=$PRIMARIO_PUERTO user=replicador password=$REPLICADOR_PASSWORD application_name=$REPLICA_NOMBRE'
primary_slot_name = '$REPLICA_NOMBRE'
EOF
    touch "$PGDATA/standby.signal"
    chmod 700 "$PGDATA"
    echo "[$REPLICA_NOMBRE] Copia lista."
fi

# cluster_name también es el application_name con el que el primario
# reconoce a esta réplica como síncrona.
exec postgres -c hot_standby=on -c cluster_name="$REPLICA_NOMBRE" -c wal_receiver_timeout=10s
