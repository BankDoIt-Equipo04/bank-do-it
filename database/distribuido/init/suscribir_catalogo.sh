#!/bin/bash
# =====================================================================
# BANKDOIT · suscribir_catalogo.sh  (#17)
# Se ejecuta en el PRIMARIO PAR, cuando el primario impar ya está arriba.
# Crea la suscripción que copia deporte, equipo y partido desde el
# primario impar (dueño del catálogo) y la mantiene al día.
#   docker exec nodo-b-primario-par bash /scripts/suscribir_catalogo.sh
# =====================================================================
set -euo pipefail

existe=$(psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc \
         "SELECT count(*) FROM pg_subscription WHERE subname = 'catalogo'")
if [ "$existe" != "0" ]; then
    echo "La suscripción catalogo ya existe."
    exit 0
fi

psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c \
"CREATE SUBSCRIPTION catalogo
   CONNECTION 'host=$CATALOGO_HOST port=$CATALOGO_PUERTO dbname=$POSTGRES_DB user=replicador password=$REPLICADOR_PASSWORD'
   PUBLICATION catalogo"

echo "Suscripción al catálogo creada (origen $CATALOGO_HOST:$CATALOGO_PUERTO)."
