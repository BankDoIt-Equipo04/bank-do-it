#!/bin/bash
# =====================================================================
# BANKDOIT · certs/generar.sh  (#32)
# Crea una CA de pruebas y un certificado de servidor por nodo. Corre
# dentro de un contenedor (lo llama generar_certificados.ps1). No
# sobrescribe archivos existentes. Los .key y .crt NO se suben al
# repositorio (ver .gitignore).
# NODO_A_SAN_EXTRA / NODO_B_SAN_EXTRA: nombres o IP adicionales del
# despliegue real, por ejemplo "IP:100.64.0.11,DNS:pc-luis".
# =====================================================================
set -euo pipefail
cd /certs
DIAS=365

if [ ! -f ca.key ]; then
    openssl req -x509 -new -nodes -newkey rsa:3072 -sha256 -days "$DIAS" \
        -keyout ca.key -out ca.crt -subj "/O=BANKDOIT/CN=BANKDOIT CA de pruebas" 2>/dev/null
    echo "CA creada: ca.crt"
fi

for nodo in nodo-a nodo-b; do
    [ -f "$nodo.crt" ] && { echo "$nodo.crt ya existe"; continue; }
    if [ "$nodo" = "nodo-a" ]; then
        san="DNS:nodo-a-primario-impar,DNS:nodo-a-replica-par"; extra="${NODO_A_SAN_EXTRA:-}"
    else
        san="DNS:nodo-b-primario-par,DNS:nodo-b-replica-impar,DNS:nodo-b-replica-par"; extra="${NODO_B_SAN_EXTRA:-}"
    fi
    san="$san,DNS:localhost,IP:127.0.0.1${extra:+,$extra}"
    openssl req -new -nodes -newkey rsa:2048 -sha256 -keyout "$nodo.key" -out "$nodo.csr" \
        -subj "/O=BANKDOIT/CN=$nodo.bankdoit" 2>/dev/null
    printf "subjectAltName=%s\nextendedKeyUsage=serverAuth\nkeyUsage=digitalSignature,keyEncipherment\n" "$san" > "$nodo.ext"
    openssl x509 -req -in "$nodo.csr" -CA ca.crt -CAkey ca.key -CAcreateserial -sha256 \
        -days "$DIAS" -out "$nodo.crt" -extfile "$nodo.ext" 2>/dev/null
    rm -f "$nodo.csr" "$nodo.ext"
    echo "$nodo.crt creado ($san)"
done

# Una CA ajena, solo para comprobar que el cliente rechaza un servidor
# que no fue firmado por la CA de BANKDOIT.
if [ ! -f ca_no_confiable.crt ]; then
    openssl req -x509 -new -nodes -newkey rsa:2048 -days 30 -keyout /tmp/ajena.key \
        -out ca_no_confiable.crt -subj "/CN=CA no confiable" 2>/dev/null
fi
# Legibles para el usuario postgres de las réplicas, que no corren como
# root. tls.sh copia la llave a una carpeta propia con permisos 0600; la
# carpeta certs/ debe quedarse fuera del repositorio y del alcance de otros.
chmod 644 ./*.crt ./nodo-*.key 2>/dev/null || true
chmod 600 ./ca.key 2>/dev/null || true
