#!/bin/bash
# =====================================================================
# BANKDOIT · 10_fragmento.sh  (#17)
# Corre una sola vez al crear cada PRIMARIO, después de 01_esquema.sql y
# 02_funciones_triggers.sql. Convierte la base en el fragmento impar o
# par según la variable FRAGMENTO.
# =====================================================================
set -euo pipefail

case "$FRAGMENTO" in
    impar) RESTO=1; INICIO=1 ;;
    par)   RESTO=0; INICIO=2 ;;
    *) echo "FRAGMENTO debe ser impar o par (recibido: $FRAGMENTO)" >&2; exit 1 ;;
esac

psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
     -v fragmento="$FRAGMENTO" -v resto="$RESTO" -v inicio="$INICIO" \
     -v replica="$REPLICA_NOMBRE" -v clave_replicador="$REPLICADOR_PASSWORD" <<'SQL'

-- 1. Qué fragmento es esta base (lo consultan las pruebas y la API).
CREATE TABLE fragmento_local (
    nombre    VARCHAR(5) PRIMARY KEY CHECK (nombre IN ('impar', 'par')),
    resto     SMALLINT NOT NULL CHECK (resto IN (0, 1)),
    unica     BOOLEAN NOT NULL DEFAULT TRUE UNIQUE CHECK (unica)  -- una sola fila
);
INSERT INTO fragmento_local (nombre, resto) VALUES (:'fragmento', :resto);

-- 2. Shard key: este fragmento solo acepta usuarios de su paridad.
--    Bankroll, apuestas, movimientos y recuerdos referencian al usuario
--    (FK), así que tampoco pueden existir aquí datos de otra paridad.
ALTER TABLE usuario ADD CONSTRAINT ck_usuario_fragmento
    CHECK (usuario_id % 2 = :resto);

-- 3. Identificadores con la paridad del fragmento (impar: 1,3,5... /
--    par: 2,4,6...). Así los id nunca chocan entre fragmentos y se
--    pueden juntar para estadísticas globales.
ALTER TABLE usuario    ALTER COLUMN usuario_id    SET START WITH :inicio SET INCREMENT BY 2 RESTART;
ALTER TABLE apuesta    ALTER COLUMN apuesta_id    SET START WITH :inicio SET INCREMENT BY 2 RESTART;
ALTER TABLE movimiento ALTER COLUMN movimiento_id SET START WITH :inicio SET INCREMENT BY 2 RESTART;
ALTER TABLE recuerdo   ALTER COLUMN recuerdo_id   SET START WITH :inicio SET INCREMENT BY 2 RESTART;

-- 4. Usuario de replicación (física para su réplica y lógica para el
--    catálogo) y ranura para que el primario guarde el WAL que su réplica
--    aún no recibe.
CREATE ROLE replicador WITH REPLICATION LOGIN PASSWORD :'clave_replicador';
GRANT SELECT ON deporte, equipo, partido TO replicador;
SELECT pg_create_physical_replication_slot(:'replica');

-- 5. Replicación síncrona: un COMMIT no se confirma hasta que su réplica
--    lo aplicó (remote_apply). Se activa al terminar la inicialización.
ALTER SYSTEM SET synchronous_standby_names = :'replica';
ALTER SYSTEM SET synchronous_commit = 'remote_apply';
SQL

# Permitir conexiones de replicación con contraseña (SCRAM).
echo "host replication replicador all scram-sha-256" >> "$PGDATA/pg_hba.conf"

if [ "$FRAGMENTO" = "impar" ]; then
    # El primario impar es el dueño del catálogo común: lo publica.
    psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" <<'SQL'
CREATE PUBLICATION catalogo FOR TABLE deporte, equipo, partido;
SQL
else
    # En el fragmento par el catálogo es de solo lectura: solo cambia por
    # la replicación lógica (que no dispara estos triggers).
    psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" <<'SQL'
CREATE FUNCTION tg_catalogo_solo_lectura() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'catalogo_solo_lectura'
        USING DETAIL = 'El catálogo se edita en el primario impar y se replica aquí.';
END $$;

CREATE TRIGGER trg_deporte_solo_lectura BEFORE INSERT OR UPDATE OR DELETE ON deporte
    FOR EACH ROW EXECUTE FUNCTION tg_catalogo_solo_lectura();
CREATE TRIGGER trg_equipo_solo_lectura BEFORE INSERT OR UPDATE OR DELETE ON equipo
    FOR EACH ROW EXECUTE FUNCTION tg_catalogo_solo_lectura();
CREATE TRIGGER trg_partido_solo_lectura BEFORE INSERT OR UPDATE OR DELETE ON partido
    FOR EACH ROW EXECUTE FUNCTION tg_catalogo_solo_lectura();
SQL
fi

echo "Fragmento $FRAGMENTO listo (réplica síncrona esperada: $REPLICA_NOMBRE)."
