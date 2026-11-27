#!/bin/bash
# =====================================================================
# BANKDOIT · 20_acceso_api.sh  (#32)
# Configura el acceso de la API en una instancia ya existente:
#   - En un PRIMARIO: crea/ajusta el rol bankdoit_api (20_acceso_api.sql).
#     Las réplicas lo reciben por replicación física.
#   - En TODAS las instancias: reescribe pg_hba.conf para exigir TLS a la
#     API y limitar los orígenes, y recarga la configuración.
# Se puede repetir sin efectos secundarios. Uso:
#   docker exec <contenedor> bash /scripts/20_acceso_api.sh
# Variables (del contenedor): POSTGRES_USER, POSTGRES_DB,
#   BANKDOIT_API_PASSWORD, API_ORIGEN_CIDR, RED_CIDR (listas separadas
#   por espacios).
# =====================================================================
set -euo pipefail
PGDATA="${PGDATA:-/var/lib/postgresql/data}"
USUARIO="${POSTGRES_USER:-bankdoit}"
BASE="${POSTGRES_DB:-bankdoit}"
API_ORIGEN_CIDR="${API_ORIGEN_CIDR:?Define API_ORIGEN_CIDR}"
RED_CIDR="${RED_CIDR:?Define RED_CIDR}"
psql_admin() { psql -X -q -v ON_ERROR_STOP=1 -U "$USUARIO" -d "$BASE" "$@"; }

en_recuperacion=$(psql_admin -tAc 'SELECT pg_is_in_recovery()')

# 1. Rol y permisos (solo donde se puede escribir).
if [ "$en_recuperacion" = "f" ]; then
    : "${BANKDOIT_API_PASSWORD:?Define BANKDOIT_API_PASSWORD en .env}"
    psql_admin -v clave_api="$BANKDOIT_API_PASSWORD" -v base="$BASE" -f /scripts/20_acceso_api.sql
    # El directorio de cuentas y las sesiones viven solo en el primario impar.
    if [ "$(psql_admin -tAc 'SELECT nombre FROM fragmento_local')" = "impar" ]; then
        psql_admin -f /scripts/21_directorio_cuentas.sql
    fi
    # Procedimiento de mantenimiento (#56) en cada primario.
    psql_admin -f /scripts/22_mantenimiento.sql
    # Funciones de monitoreo y rol del exportador (#59).
    psql_admin -v clave_monitor="${BANKDOIT_MONITOR_PASSWORD:-}" -f /scripts/23_monitoreo.sql
else
    echo "Réplica: el rol bankdoit_api llega desde su primario."
fi

# 2. pg_hba.conf gestionado. Se valida antes de recargar; si tiene un
#    error se restaura la versión anterior.
cp "$PGDATA/pg_hba.conf" "$PGDATA/pg_hba.conf.anterior"
{
    echo "# Gestionado por /scripts/20_acceso_api.sh (#32). No editar a mano."
    echo "# TIPO   BASE         USUARIO          ORIGEN            MÉTODO"
    echo "local    all          all                                trust          # docker exec (administración)"
    echo "local    replication  all                                trust          # pg_basebackup dentro del contenedor (#57)"
    echo "host     all          all              127.0.0.1/32      scram-sha-256"
    for cidr in $API_ORIGEN_CIDR; do
        echo "hostssl  $BASE     bankdoit_api     $cidr   scram-sha-256  # API: solo con TLS"
    done
    echo "host     all          bankdoit_api     all               reject         # API sin TLS u otro origen"
    for cidr in $RED_CIDR; do
        echo "host     replication  replicador       $cidr   scram-sha-256  # réplica física"
        echo "host     $BASE     replicador       $cidr   scram-sha-256  # suscripción del catálogo"
        echo "host     all          $USUARIO         $cidr   scram-sha-256  # administración remota"
        echo "hostssl  $BASE     bankdoit_monitor $cidr   scram-sha-256  # exportador de Prometheus (#59)"
    done
} > "$PGDATA/pg_hba.conf"

errores=$(psql_admin -tAc "SELECT count(*) FROM pg_hba_file_rules WHERE error IS NOT NULL")
if [ "$errores" != "0" ]; then
    psql_admin -c "SELECT line_number, error FROM pg_hba_file_rules WHERE error IS NOT NULL"
    cp "$PGDATA/pg_hba.conf.anterior" "$PGDATA/pg_hba.conf"
    echo "pg_hba.conf tenía errores; se restauró la versión anterior." >&2
    exit 1
fi
psql_admin -tAc "SELECT pg_reload_conf()" > /dev/null

ssl=$(psql_admin -tAc "SHOW ssl")
echo "Acceso de la API configurado (ssl=$ssl, API desde: $API_ORIGEN_CIDR)."
