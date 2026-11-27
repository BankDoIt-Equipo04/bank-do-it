-- =====================================================================
-- BANKDOIT · 22_mantenimiento.sql  (#56)
-- Procedimiento almacenado de mantenimiento para cada PRIMARIO.
--
--   CALL mantenimiento_diario();          -- lotes de 1000
--   CALL mantenimiento_diario(500);       -- otro tamaño de lote
--
-- Qué hace:
--   1. Elimina las sesiones vencidas (solo existe la tabla sesion en el
--      primario impar, donde vive el directorio de cuentas), por lotes y
--      con COMMIT entre lotes para no bloquear el inicio de sesión.
--   2. Ejecuta conciliar_bankroll() y cuenta los bankrolls que no cuadran
--      con sus movimientos y apuestas pendientes.
--   3. Registra el resultado en bitacora_mantenimiento.
--
-- Por qué PROCEDURE y no FUNCTION: una función se ejecuta dentro de una
-- sola transacción y no puede hacer COMMIT; el procedimiento sí, así que
-- puede borrar por lotes confirmando cada uno, y se invoca con CALL como
-- tarea de administración (no devuelve datos a la API).
--
-- Solo lo ejecuta el administrador. Un procedimiento con COMMIT no puede
-- ser SECURITY DEFINER ni llevar SET search_path, así que corre con los
-- permisos de quien lo llama, usa nombres calificados con public. y
-- bankdoit_api no tiene EXECUTE sobre él.
-- Idempotente: lo aplica 20_acceso_api.sh en cada primario.
-- =====================================================================
\set ON_ERROR_STOP on
BEGIN;

CREATE TABLE IF NOT EXISTS bitacora_mantenimiento (
    ejecucion_id            BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ejecutado_en            TIMESTAMPTZ NOT NULL DEFAULT now(),
    fragmento               VARCHAR(5) NOT NULL,
    sesiones_eliminadas     INTEGER NOT NULL DEFAULT 0,
    lotes                   INTEGER NOT NULL DEFAULT 0,
    bankrolls_revisados     INTEGER NOT NULL,
    bankrolls_descuadrados  INTEGER NOT NULL,
    descuadres              JSONB NOT NULL DEFAULT '[]',
    duracion_ms             INTEGER NOT NULL,
    CONSTRAINT ck_bitacora_conteos CHECK (sesiones_eliminadas >= 0 AND lotes >= 0
                                          AND bankrolls_descuadrados BETWEEN 0 AND bankrolls_revisados)
);
CREATE INDEX IF NOT EXISTS ix_bitacora_fecha ON bitacora_mantenimiento (ejecutado_en DESC);

CREATE OR REPLACE PROCEDURE mantenimiento_diario(p_lote INTEGER DEFAULT 1000)
LANGUAGE plpgsql
AS $$
DECLARE
    v_inicio      TIMESTAMPTZ := clock_timestamp();
    v_fragmento   VARCHAR(5);
    v_borradas    INTEGER;
    v_total       INTEGER := 0;
    v_lotes       INTEGER := 0;
    v_revisados   INTEGER;
    v_descuadres  INTEGER;
    v_detalle     JSONB;
BEGIN
    IF p_lote IS NULL OR p_lote < 1 THEN
        RAISE EXCEPTION 'lote_invalido' USING DETAIL = 'El tamaño de lote debe ser mayor que cero.';
    END IF;
    IF pg_is_in_recovery() THEN
        RAISE EXCEPTION 'solo_en_primario' USING DETAIL = 'Las réplicas son de solo lectura.';
    END IF;
    SELECT nombre INTO v_fragmento FROM public.fragmento_local;

    -- 1. Sesiones vencidas, por lotes. EXECUTE porque la tabla solo existe
    --    en el primario impar.
    IF to_regclass('public.sesion') IS NOT NULL THEN
        LOOP
            EXECUTE 'DELETE FROM public.sesion WHERE huella IN (
                         SELECT huella FROM public.sesion WHERE vence <= now() LIMIT $1)'
              USING p_lote;
            GET DIAGNOSTICS v_borradas = ROW_COUNT;
            EXIT WHEN v_borradas = 0;
            v_total := v_total + v_borradas;
            v_lotes := v_lotes + 1;
            COMMIT;  -- cada lote se confirma (y se replica) por separado
        END LOOP;
    END IF;

    -- 2. Conciliación de todos los bankrolls del fragmento.
    SELECT count(*),
           count(*) FILTER (WHERE NOT cuadra),
           COALESCE(jsonb_agg(jsonb_build_object(
                        'usuario_id', usuario_id,
                        'saldo_bankroll', saldo_bankroll, 'saldo_movimientos', saldo_movimientos,
                        'en_juego_bankroll', en_juego_bankroll, 'en_juego_apuestas', en_juego_apuestas))
                    FILTER (WHERE NOT cuadra), '[]')
      INTO v_revisados, v_descuadres, v_detalle
      FROM public.conciliar_bankroll();

    -- 3. Bitácora.
    INSERT INTO public.bitacora_mantenimiento (fragmento, sesiones_eliminadas, lotes, bankrolls_revisados,
                                        bankrolls_descuadrados, descuadres, duracion_ms)
    VALUES (v_fragmento, v_total, v_lotes, v_revisados, v_descuadres, v_detalle,
            (extract(epoch FROM clock_timestamp() - v_inicio) * 1000)::INTEGER);
    COMMIT;

    RAISE NOTICE 'Mantenimiento %: % sesiones vencidas eliminadas en % lotes; % de % bankrolls no cuadran.',
        v_fragmento, v_total, v_lotes, v_descuadres, v_revisados;
    IF v_descuadres > 0 THEN
        RAISE WARNING 'Bankrolls descuadrados en el fragmento %: %', v_fragmento, v_detalle;
    END IF;
END $$;

-- Solo administración.
REVOKE ALL ON PROCEDURE mantenimiento_diario(INTEGER) FROM PUBLIC;
REVOKE ALL ON bitacora_mantenimiento FROM PUBLIC;
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'bankdoit_api') THEN
        EXECUTE 'REVOKE ALL ON PROCEDURE mantenimiento_diario(INTEGER) FROM bankdoit_api';
        EXECUTE 'REVOKE ALL ON bitacora_mantenimiento FROM bankdoit_api';
    END IF;
END $$;

COMMIT;
SELECT 'procedimiento mantenimiento_diario listo en el fragmento ' || nombre AS resultado FROM fragmento_local;
