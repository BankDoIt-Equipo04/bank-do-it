#!/bin/bash
# =====================================================================
# BANKDOIT · respaldar.sh  (#57)
# Corre DENTRO del primario de un fragmento (lo llama respaldar.ps1):
#   bash /scripts/respaldar.sh <fecha>          respaldo completo
#   bash /scripts/respaldar.sh --retencion <carpeta> <fragmento>
#                                               solo aplica la retención
# Genera en /respaldos (carpeta del equipo, fuera del contenedor y del
# repositorio):
#   logico/<frag>/bankdoit_<frag>_<fecha>.dump   pg_dump formato custom
#   logico/<frag>/roles_<frag>_<fecha>.sql       roles SIN contraseñas
#   base/<frag>/<fecha>/                         pg_basebackup (tar.gz)
#   wal/<frag>/                                  WAL archivado (archive_command)
# Retención: 7 respaldos diarios + 1 por semana de las últimas 4 semanas
# (lógicos) y los 2 respaldos físicos más recientes; el WAL anterior al
# respaldo físico más viejo que se conserva se elimina.
# =====================================================================
set -euo pipefail
USUARIO="${POSTGRES_USER:-bankdoit}"
BASE="${POSTGRES_DB:-bankdoit}"
DIARIOS="${RESPALDO_DIARIOS:-7}"
SEMANALES="${RESPALDO_SEMANALES:-4}"
FISICOS="${RESPALDO_FISICOS:-2}"

# Conserva el más reciente de cada día (los últimos $DIARIOS días con
# respaldo) y el más reciente de cada semana ISO (las últimas $SEMANALES).
retener_logicos() {
    local carpeta="$1" frag="$2"
    [ -d "$carpeta" ] || return 0
    mapfile -t archivos < <(ls -1 "$carpeta" | grep -E "^bankdoit_${frag}_[0-9]{8}-[0-9]{6}\.dump$" | sort -r)
    declare -A dias=() semanas=() conservar=()
    for a in "${archivos[@]}"; do
        local fecha="${a#bankdoit_${frag}_}"; fecha="${fecha:0:8}"
        local semana; semana=$(date -d "$fecha" +%G-%V)
        if [ -z "${dias[$fecha]:-}" ] && [ "${#dias[@]}" -lt "$DIARIOS" ]; then
            dias[$fecha]=1; conservar[$a]=1
        fi
        if [ -z "${semanas[$semana]:-}" ] && [ "${#semanas[@]}" -lt "$SEMANALES" ]; then
            semanas[$semana]=1; conservar[$a]=1
        fi
    done
    local borrados=0
    for a in "${archivos[@]}"; do
        if [ -z "${conservar[$a]:-}" ]; then
            local roles="roles_${a#bankdoit_}"
            rm -f "$carpeta/$a" "$carpeta/${roles%.dump}.sql"
            borrados=$((borrados + 1))
        fi
    done
    echo "retencion_logicos=${#conservar[@]} conservados, $borrados eliminados"
}

if [ "${1:-}" = "--retencion" ]; then
    retener_logicos "$2" "$3"
    exit 0
fi

FECHA="${1:?Indica la fecha del respaldo (AAAAMMDD-HHMMSS)}"
if [ "$(psql -X -tAq -U "$USUARIO" -d "$BASE" -c 'SELECT pg_is_in_recovery()')" != "f" ]; then
    echo "Este contenedor no es primario; respalda desde el primario del fragmento." >&2
    exit 1
fi
FRAG=$(psql -X -tAq -U "$USUARIO" -d "$BASE" -c 'SELECT nombre FROM fragmento_local')
LOG="/respaldos/logico/$FRAG"; FIS="/respaldos/base/$FRAG"
mkdir -p "$LOG" "$FIS" "/respaldos/wal/$FRAG"
# El archivado de WAL lo hace el usuario postgres: la carpeta debe ser suya.
if [ ! -w "/respaldos/wal/$FRAG" ]; then
    echo "postgres no puede escribir en /respaldos/wal/$FRAG; ejecuta este script como postgres (docker exec -u postgres)." >&2
    exit 1
fi

# 1. Respaldo lógico (esquema + datos) y roles sin contraseñas.
pg_dump -U "$USUARIO" -d "$BASE" -Fc -Z 6 -f "$LOG/bankdoit_${FRAG}_${FECHA}.dump"
pg_dumpall -U "$USUARIO" --roles-only --no-role-passwords -f "$LOG/roles_${FRAG}_${FECHA}.sql"

# 2. Respaldo físico para recuperación a un punto en el tiempo.
pg_basebackup -U "$USUARIO" -D "$FIS/$FECHA" -Ft -z -X stream -c fast -l "bankdoit $FRAG $FECHA"

# 3. Asegura que el WAL actual quede archivado junto al respaldo.
psql -X -tAq -U "$USUARIO" -d "$BASE" -c 'SELECT pg_switch_wal()' > /dev/null

# 4. Retención.
retener_logicos "$LOG" "$FRAG"
mapfile -t fisicos < <(ls -1 "$FIS" | grep -E '^[0-9]{8}-[0-9]{6}$' | sort -r)
for viejo in "${fisicos[@]:$FISICOS}"; do rm -rf "${FIS:?}/$viejo"; done
mapfile -t fisicos < <(ls -1 "$FIS" | grep -E '^[0-9]{8}-[0-9]{6}$' | sort -r)
mas_viejo="${fisicos[-1]}"
marca=$(grep -l "LABEL: bankdoit $FRAG $mas_viejo" /respaldos/wal/"$FRAG"/*.backup 2>/dev/null | head -1 || true)
if [ -n "$marca" ]; then
    pg_archivecleanup "/respaldos/wal/$FRAG" "$(basename "$marca")"
fi
echo "retencion_fisicos=${#fisicos[@]} conservados (más antiguo $mas_viejo)"

# 5. Resumen para el manifiesto.
echo "fragmento=$FRAG"
echo "logico=logico/$FRAG/bankdoit_${FRAG}_${FECHA}.dump $(stat -c %s "$LOG/bankdoit_${FRAG}_${FECHA}.dump") $(sha256sum "$LOG/bankdoit_${FRAG}_${FECHA}.dump" | cut -c1-64)"
echo "fisico=base/$FRAG/$FECHA $(du -sb "$FIS/$FECHA" | cut -f1)"
echo "wal_archivados=$(ls -1 /respaldos/wal/"$FRAG" | grep -vc '\.backup$' || true)"
