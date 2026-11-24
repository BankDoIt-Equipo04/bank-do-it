#!/bin/bash
# =====================================================================
# BANKDOIT · tls.sh  (#32)
# Envoltura del arranque: copia el certificado y la llave del nodo desde
# /certs-origen (montado de solo lectura, fuera del repositorio) a una
# carpeta propia con los permisos que exige PostgreSQL (llave 0600 del
# usuario postgres) y después ejecuta el comando original.
# TLS_NODO = nodo-a | nodo-b (qué certificado usa este contenedor).
# =====================================================================
set -euo pipefail
ORIGEN=/certs-origen
DESTINO=/var/lib/postgresql/tls

if [ ! -f "$ORIGEN/$TLS_NODO.crt" ] || [ ! -f "$ORIGEN/$TLS_NODO.key" ]; then
    echo "Faltan $ORIGEN/$TLS_NODO.crt y .key. Ejecuta .\\generar_certificados.ps1" >&2
    exit 1
fi
mkdir -p "$DESTINO"
cp "$ORIGEN/$TLS_NODO.crt" "$DESTINO/server.crt"
cp "$ORIGEN/$TLS_NODO.key" "$DESTINO/server.key"
cp "$ORIGEN/ca.crt" "$DESTINO/ca.crt"
chmod 600 "$DESTINO/server.key"
chmod 644 "$DESTINO/server.crt" "$DESTINO/ca.crt"
if [ "$(id -u)" = "0" ]; then
    chown -R postgres:postgres "$DESTINO"
fi
exec "$@"
