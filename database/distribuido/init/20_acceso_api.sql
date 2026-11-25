-- =====================================================================
-- BANKDOIT · 20_acceso_api.sql  (#32)
-- Cuenta con la que se conecta la API de Python a cada PRIMARIO.
-- Se ejecuta como administrador (POSTGRES_USER) con:
--   psql -v clave_api=... -v base=... -f 20_acceso_api.sql
-- Es idempotente: se puede correr de nuevo sobre una instalación
-- existente; no borra ni duplica datos (solo crea/ajusta funciones,
-- el rol y sus permisos).
--
-- Roles separados:
--   POSTGRES_USER (bankdoit) administración: dueño del esquema, superusuario.
--   replicador               replicación física y suscripción del catálogo.
--   bankdoit_api             la API: solo ejecuta funciones de negocio y lee
--                            el catálogo. No lee ni modifica tablas directo.
-- =====================================================================
\set ON_ERROR_STOP on

BEGIN;

-- ---------------------------------------------------------------------
-- 1. Consultas que la API necesita y aún no existían en PostgreSQL.
--    Devuelven lo mismo que hoy responde la API (docs/api-bankroll.md);
--    propuesta pendiente de confirmar con Luis.
-- ---------------------------------------------------------------------

-- GET /usuarios/{id}/bankroll
CREATE OR REPLACE FUNCTION consultar_bankroll(p_usuario_id BIGINT)
RETURNS TABLE (saldo_disponible NUMERIC, monto_en_juego NUMERIC,
               limite_semanal NUMERIC, apostado_semana NUMERIC)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
#variable_conflict use_column
BEGIN
    RETURN QUERY
        SELECT b.saldo_disponible, b.monto_en_juego, b.limite_semanal,
               public.apostado_semana(b.usuario_id)
          FROM bankroll b WHERE b.usuario_id = p_usuario_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'usuario_inexistente';
    END IF;
END $$;

-- GET /usuarios/{id}/historial  (mismo JSON que la API actual)
CREATE OR REPLACE FUNCTION consultar_historial(p_usuario_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_bankroll bankroll;
BEGIN
    SELECT * INTO v_bankroll FROM bankroll WHERE usuario_id = p_usuario_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'usuario_inexistente';
    END IF;
    RETURN jsonb_build_object(
        'bankroll', jsonb_build_object(
            'disponible', v_bankroll.saldo_disponible::TEXT,
            'en_juego',   v_bankroll.monto_en_juego::TEXT),
        'presupuesto', jsonb_build_object(
            'limite_centavos', (v_bankroll.limite_semanal * 100)::BIGINT,
            'usado_centavos',  (apostado_semana(p_usuario_id) * 100)::BIGINT),
        'apuestas', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                       'id', a.apuesta_id, 'partido_id', a.partido_id,
                       'seleccion', a.seleccion, 'monto', a.monto::TEXT,
                       'cuota', a.cuota::TEXT, 'estado', a.estado)
                   ORDER BY a.apuesta_id DESC)
              FROM apuesta a WHERE a.usuario_id = p_usuario_id), '[]'::JSONB),
        'partidos', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                       'id', p.partido_id, 'deporte', d.nombre,
                       'local', el.nombre, 'visitante', ev.nombre)
                   ORDER BY p.partido_id)
              FROM partido p
              JOIN deporte d ON d.deporte_id = p.deporte_id
              JOIN equipo el ON el.equipo_id = p.equipo_local_id
              JOIN equipo ev ON ev.equipo_id = p.equipo_visitante_id), '[]'::JSONB));
END $$;

-- Permite reanudar un registro interrumpido sin adoptar un bankroll ajeno.
CREATE OR REPLACE FUNCTION asegurar_usuario_api(p_id BIGINT, p_alias VARCHAR,
                                                 p_marca TEXT, p_saldo NUMERIC)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    PERFORM crear_usuario(p_alias, p_marca, p_saldo, NULL, 'usuario', p_id);
EXCEPTION WHEN unique_violation THEN
    IF NOT EXISTS (SELECT 1 FROM usuario WHERE usuario_id = p_id AND alias = p_alias
                   AND hash_contrasena = p_marca) THEN
        RAISE EXCEPTION 'alias_duplicado';
    END IF;
END $$;

-- Alias: mismas reglas que valida la API (letras ASCII, números, punto,
-- guion y guion bajo). Antes no se aceptaba el guion.
ALTER TABLE usuario DROP CONSTRAINT IF EXISTS ck_usuario_alias;
ALTER TABLE usuario ADD CONSTRAINT ck_usuario_alias CHECK (alias ~ '^[A-Za-z0-9_.-]{3,40}$');

-- ---------------------------------------------------------------------
-- 2. Las funciones de negocio se ejecutan con los permisos de su dueño
--    (SECURITY DEFINER) y con search_path fijo. Así la API no necesita
--    permisos sobre las tablas: solo puede cambiar datos a través de
--    estas funciones, que validan saldo, idempotencia y transiciones.
-- ---------------------------------------------------------------------
ALTER FUNCTION crear_usuario(VARCHAR, TEXT, NUMERIC, NUMERIC, VARCHAR, BIGINT)
    SECURITY DEFINER SET search_path = public, pg_temp;
ALTER FUNCTION registrar_aportacion(BIGINT, NUMERIC)
    SECURITY DEFINER SET search_path = public, pg_temp;
ALTER FUNCTION registrar_retiro(BIGINT, NUMERIC)
    SECURITY DEFINER SET search_path = public, pg_temp;
ALTER FUNCTION registrar_apuesta(BIGINT, VARCHAR, BIGINT, VARCHAR, NUMERIC, NUMERIC, VARCHAR)
    SECURITY DEFINER SET search_path = public, pg_temp;
ALTER FUNCTION resolver_apuesta(BIGINT, BIGINT, VARCHAR)
    SECURITY DEFINER SET search_path = public, pg_temp;
ALTER FUNCTION apostado_semana(BIGINT, TIMESTAMPTZ)
    SECURITY DEFINER SET search_path = public, pg_temp;
ALTER FUNCTION ganancia_neta(BIGINT)
    SECURITY DEFINER SET search_path = public, pg_temp;
-- El trigger diferido que exige la reserva de cada apuesta corre al hacer
-- COMMIT, ya fuera de registrar_apuesta, con el usuario de la sesión. Sin
-- esto, la API fallaría con "permission denied for table apuesta".
ALTER FUNCTION tg_apuesta_con_movimiento()
    SECURITY DEFINER SET search_path = public, pg_temp;

-- ---------------------------------------------------------------------
-- 3. Nadie ejecuta funciones ni se conecta por omisión (PUBLIC).
-- ---------------------------------------------------------------------
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC;
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
REVOKE CONNECT, TEMPORARY ON DATABASE :"base" FROM PUBLIC;
GRANT CONNECT ON DATABASE :"base" TO replicador;

-- ---------------------------------------------------------------------
-- 4. Rol de la API (se crea una vez; después solo se ajusta).
-- ---------------------------------------------------------------------
SELECT format('CREATE ROLE bankdoit_api LOGIN PASSWORD %L', :'clave_api')
 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'bankdoit_api') \gexec

ALTER ROLE bankdoit_api WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION
    NOBYPASSRLS NOINHERIT CONNECTION LIMIT 20 PASSWORD :'clave_api';
ALTER ROLE bankdoit_api SET search_path = public;
-- Libera transacciones olvidadas. No se usa statement_timeout: cancelar
-- un COMMIT que espera a la réplica síncrona lo dejaría confirmado en el
-- primario sin copia (ver #18).
ALTER ROLE bankdoit_api SET idle_in_transaction_session_timeout = '30s';

GRANT CONNECT ON DATABASE :"base" TO bankdoit_api;
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM bankdoit_api;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM bankdoit_api;
GRANT USAGE ON SCHEMA public TO bankdoit_api;

-- Lectura del catálogo y del fragmento al que está conectada.
GRANT SELECT ON deporte, equipo, partido, fragmento_local TO bankdoit_api;

-- Operaciones de negocio permitidas.
GRANT EXECUTE ON FUNCTION
    asegurar_usuario_api(BIGINT, VARCHAR, TEXT, NUMERIC),
    crear_usuario(VARCHAR, TEXT, NUMERIC, NUMERIC, VARCHAR, BIGINT),
    registrar_apuesta(BIGINT, VARCHAR, BIGINT, VARCHAR, NUMERIC, NUMERIC, VARCHAR),
    resolver_apuesta(BIGINT, BIGINT, VARCHAR),
    registrar_aportacion(BIGINT, NUMERIC),
    registrar_retiro(BIGINT, NUMERIC),
    consultar_bankroll(BIGINT),
    consultar_historial(BIGINT),
    apostado_semana(BIGINT, TIMESTAMPTZ),
    ganancia_neta(BIGINT)
  TO bankdoit_api;

COMMIT;

SELECT 'rol bankdoit_api listo en el fragmento ' || nombre AS resultado FROM fragmento_local;
