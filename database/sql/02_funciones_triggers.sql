-- =====================================================================
-- BANKDOIT · 02_funciones_triggers.sql
-- Reglas de negocio que viven en la base de datos. Issue #16.
--
-- Triggers (protegen la integridad aunque alguien use SQL directo):
--   T1 trg_movimiento_aplicar      movimiento -> actualiza el bankroll
--   T2 trg_bankroll_proteger       bloquea cambios directos al saldo
--   T3 trg_movimiento_inmutable    movimientos no se editan ni borran
--   T4 trg_apuesta_transicion      solo pendiente -> ganada/perdida/anulada
--   T5 trg_apuesta_no_borrar       las apuestas no se borran
--   T6 trg_apuesta_con_movimiento  (diferido) toda apuesta tiene su
--                                  reserva y toda resolución su liquidación
--
-- Funciones (las llama la API; cada una es una sola transacción):
--   F1 crear_usuario         usuario + bankroll + movimiento de saldo inicial
--   F2 registrar_aportacion  aportación simulada
--   F3 registrar_retiro      retiro simulado (valida fondos)
--   F4 registrar_apuesta     valida, reserva el monto, idempotente por clave
--   F5 resolver_apuesta      liquida ganada/perdida/anulada, idempotente
--   F6 apostado_semana       monto apostado en la semana (límite semanal)
--   F7 ganancia_neta         resultado deportivo, sin aportaciones/retiros
--   F8 conciliar_bankroll    compara bankroll vs. movimientos vs. apuestas
--
-- Errores de negocio: SQLSTATE P0001 y el mensaje es una clave estable
-- (saldo_insuficiente, clave_reutilizada, resultado_en_conflicto, ...)
-- que la API traduce a su respuesta HTTP.
-- =====================================================================


-- ---------------------------------------------------------------------
-- T1. Aplicar cada movimiento al bankroll (misma transacción).
--     Si el saldo quedara negativo, el CHECK de bankroll aborta todo.
-- ---------------------------------------------------------------------
CREATE FUNCTION tg_movimiento_aplicar() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    UPDATE bankroll
       SET saldo_disponible = saldo_disponible + NEW.cambio_disponible,
           monto_en_juego   = monto_en_juego   + NEW.cambio_en_juego,
           actualizado_en   = now()
     WHERE usuario_id = NEW.usuario_id;
    RETURN NULL;
END $$;

CREATE TRIGGER trg_movimiento_aplicar
AFTER INSERT ON movimiento
FOR EACH ROW EXECUTE FUNCTION tg_movimiento_aplicar();


-- ---------------------------------------------------------------------
-- T2. El saldo solo cambia a través de un movimiento (T1).
--     pg_trigger_depth() = 1 significa UPDATE directo, no desde T1.
-- ---------------------------------------------------------------------
CREATE FUNCTION tg_bankroll_proteger() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF NEW.saldo_disponible <> 0 OR NEW.monto_en_juego <> 0 THEN
            RAISE EXCEPTION 'saldo_solo_por_movimientos'
                USING DETAIL = 'El bankroll se crea en 0; el saldo inicial es un movimiento.';
        END IF;
    ELSIF pg_trigger_depth() < 2
          AND (NEW.saldo_disponible IS DISTINCT FROM OLD.saldo_disponible
               OR NEW.monto_en_juego IS DISTINCT FROM OLD.monto_en_juego) THEN
        RAISE EXCEPTION 'saldo_solo_por_movimientos'
            USING DETAIL = 'Registra un movimiento en lugar de modificar el bankroll.';
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER trg_bankroll_proteger
BEFORE INSERT OR UPDATE ON bankroll
FOR EACH ROW EXECUTE FUNCTION tg_bankroll_proteger();


-- ---------------------------------------------------------------------
-- T3. Historial auditable: los movimientos no se editan ni se borran.
-- ---------------------------------------------------------------------
CREATE FUNCTION tg_movimiento_inmutable() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'movimiento_inmutable'
        USING DETAIL = 'Para corregir un saldo registra un movimiento nuevo.';
END $$;

CREATE TRIGGER trg_movimiento_inmutable
BEFORE UPDATE OR DELETE ON movimiento
FOR EACH ROW EXECUTE FUNCTION tg_movimiento_inmutable();


-- ---------------------------------------------------------------------
-- T4. Transiciones válidas de una apuesta y datos inmutables.
-- ---------------------------------------------------------------------
CREATE FUNCTION tg_apuesta_transicion() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF (NEW.usuario_id, NEW.partido_id, NEW.clave_operacion, NEW.seleccion,
        NEW.monto, NEW.cuota, NEW.registrada_en)
       IS DISTINCT FROM
       (OLD.usuario_id, OLD.partido_id, OLD.clave_operacion, OLD.seleccion,
        OLD.monto, OLD.cuota, OLD.registrada_en) THEN
        RAISE EXCEPTION 'apuesta_inmutable'
            USING DETAIL = 'Solo se puede cambiar el estado (y la etiqueta de origen).';
    END IF;

    IF NEW.estado IS DISTINCT FROM OLD.estado THEN
        IF OLD.estado <> 'pendiente' THEN
            RAISE EXCEPTION 'resultado_en_conflicto'
                USING DETAIL = format('La apuesta %s ya está %s.', OLD.apuesta_id, OLD.estado);
        END IF;
        NEW.resuelta_en := now();
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER trg_apuesta_transicion
BEFORE UPDATE ON apuesta
FOR EACH ROW EXECUTE FUNCTION tg_apuesta_transicion();


-- ---------------------------------------------------------------------
-- T5. Las apuestas forman parte del historial: no se borran
--     (una apuesta cancelada se marca como anulada).
-- ---------------------------------------------------------------------
CREATE FUNCTION tg_apuesta_no_borrar() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'apuesta_no_borrable'
        USING DETAIL = 'Marca la apuesta como anulada para devolver el monto.';
END $$;

CREATE TRIGGER trg_apuesta_no_borrar
BEFORE DELETE ON apuesta
FOR EACH ROW EXECUTE FUNCTION tg_apuesta_no_borrar();


-- ---------------------------------------------------------------------
-- T6. Al hacer COMMIT, toda apuesta debe tener su reserva y, si ya se
--     resolvió, su liquidación. Evita apuestas insertadas "a mano" que
--     no descuentan saldo. Es diferido para permitir insertar la
--     apuesta y su movimiento dentro de la misma transacción.
-- ---------------------------------------------------------------------
CREATE FUNCTION tg_apuesta_con_movimiento() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_estado VARCHAR;
BEGIN
    SELECT estado INTO v_estado FROM apuesta WHERE apuesta_id = NEW.apuesta_id;

    IF NOT EXISTS (SELECT 1 FROM movimiento
                    WHERE apuesta_id = NEW.apuesta_id AND tipo = 'reserva') THEN
        RAISE EXCEPTION 'apuesta_sin_reserva'
            USING DETAIL = format('La apuesta %s no tiene movimiento de reserva.', NEW.apuesta_id);
    END IF;

    IF v_estado <> 'pendiente' AND NOT EXISTS (
           SELECT 1 FROM movimiento
            WHERE apuesta_id = NEW.apuesta_id AND tipo = 'liquidacion') THEN
        RAISE EXCEPTION 'apuesta_sin_liquidacion'
            USING DETAIL = format('La apuesta %s está %s sin liquidación.', NEW.apuesta_id, v_estado);
    END IF;
    RETURN NULL;
END $$;

CREATE CONSTRAINT TRIGGER trg_apuesta_con_movimiento
AFTER INSERT OR UPDATE OF estado ON apuesta
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION tg_apuesta_con_movimiento();


-- =====================================================================
-- Funciones de negocio
-- =====================================================================

-- ---------------------------------------------------------------------
-- F1. Crear usuario con su bankroll y su saldo inicial.
--     p_usuario_id es opcional (para datos de prueba y para asignar la
--     paridad del fragmento en #17); si es NULL lo genera la identidad.
-- ---------------------------------------------------------------------
CREATE FUNCTION crear_usuario(
    p_alias            VARCHAR,
    p_hash_contrasena  TEXT,
    p_saldo_inicial    NUMERIC,
    p_limite_semanal   NUMERIC DEFAULT NULL,
    p_rol              VARCHAR DEFAULT 'usuario',
    p_usuario_id       BIGINT  DEFAULT NULL
) RETURNS BIGINT
LANGUAGE plpgsql AS $$
DECLARE
    v_id BIGINT;
BEGIN
    IF p_saldo_inicial IS NULL OR p_saldo_inicial < 0
       OR p_saldo_inicial <> round(p_saldo_inicial, 2) THEN
        RAISE EXCEPTION 'saldo_inicial_invalido';
    END IF;

    IF p_usuario_id IS NULL THEN
        INSERT INTO usuario (alias, hash_contrasena, rol)
        VALUES (p_alias, p_hash_contrasena, p_rol)
        RETURNING usuario_id INTO v_id;
    ELSE
        INSERT INTO usuario (usuario_id, alias, hash_contrasena, rol)
        VALUES (p_usuario_id, p_alias, p_hash_contrasena, p_rol)
        RETURNING usuario_id INTO v_id;
    END IF;

    INSERT INTO bankroll (usuario_id, limite_semanal) VALUES (v_id, p_limite_semanal);

    INSERT INTO movimiento (usuario_id, tipo, cambio_disponible, cambio_en_juego)
    VALUES (v_id, 'saldo_inicial', p_saldo_inicial, 0);

    RETURN v_id;
END $$;


-- Bloquea el bankroll del usuario (evita carreras entre operaciones
-- simultáneas del mismo usuario) y valida que la cuenta esté activa.
CREATE FUNCTION bloquear_bankroll(p_usuario_id BIGINT)
RETURNS bankroll
LANGUAGE plpgsql AS $$
DECLARE
    v_bankroll bankroll;
    v_estado   VARCHAR;
BEGIN
    SELECT b.* INTO v_bankroll FROM bankroll b WHERE b.usuario_id = p_usuario_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'usuario_inexistente'
            USING DETAIL = format('No existe bankroll para el usuario %s.', p_usuario_id);
    END IF;

    SELECT u.estado INTO v_estado FROM usuario u WHERE u.usuario_id = p_usuario_id;
    IF v_estado <> 'activo' THEN
        RAISE EXCEPTION 'usuario_suspendido';
    END IF;
    RETURN v_bankroll;
END $$;


-- ---------------------------------------------------------------------
-- F2 / F3. Aportaciones y retiros simulados. No cuentan como ganancia
--          deportiva (F7 solo mira apuestas resueltas).
-- ---------------------------------------------------------------------
CREATE FUNCTION registrar_aportacion(p_usuario_id BIGINT, p_importe NUMERIC)
RETURNS TABLE (saldo_disponible NUMERIC, monto_en_juego NUMERIC)
LANGUAGE plpgsql AS $$
#variable_conflict use_column
BEGIN
    IF p_importe IS NULL OR p_importe <= 0 OR p_importe <> round(p_importe, 2) THEN
        RAISE EXCEPTION 'importe_invalido';
    END IF;
    PERFORM bloquear_bankroll(p_usuario_id);

    INSERT INTO movimiento (usuario_id, tipo, cambio_disponible, cambio_en_juego)
    VALUES (p_usuario_id, 'aportacion', p_importe, 0);

    RETURN QUERY SELECT b.saldo_disponible, b.monto_en_juego
                   FROM bankroll b WHERE b.usuario_id = p_usuario_id;
END $$;

CREATE FUNCTION registrar_retiro(p_usuario_id BIGINT, p_importe NUMERIC)
RETURNS TABLE (saldo_disponible NUMERIC, monto_en_juego NUMERIC)
LANGUAGE plpgsql AS $$
#variable_conflict use_column
DECLARE
    v_bankroll bankroll;
BEGIN
    IF p_importe IS NULL OR p_importe <= 0 OR p_importe <> round(p_importe, 2) THEN
        RAISE EXCEPTION 'importe_invalido';
    END IF;
    v_bankroll := bloquear_bankroll(p_usuario_id);

    IF v_bankroll.saldo_disponible < p_importe THEN
        RAISE EXCEPTION 'saldo_insuficiente'
            USING DETAIL = format('Disponible %s, retiro %s.', v_bankroll.saldo_disponible, p_importe);
    END IF;

    INSERT INTO movimiento (usuario_id, tipo, cambio_disponible, cambio_en_juego)
    VALUES (p_usuario_id, 'retiro', -p_importe, 0);

    RETURN QUERY SELECT b.saldo_disponible, b.monto_en_juego
                   FROM bankroll b WHERE b.usuario_id = p_usuario_id;
END $$;


-- ---------------------------------------------------------------------
-- F4. Registrar una apuesta.
--     En una sola transacción: bloquea el bankroll, revisa la clave de
--     idempotencia, valida partido, monto, cuota y fondos, crea la
--     apuesta y su movimiento de reserva.
--     Reenvío con la misma clave y los mismos datos -> devuelve la
--     apuesta original (es_reenvio = true) sin volver a cobrar.
--     Misma clave con datos distintos -> clave_reutilizada.
-- ---------------------------------------------------------------------
CREATE FUNCTION registrar_apuesta(
    p_usuario_id  BIGINT,
    p_clave       VARCHAR,
    p_partido_id  BIGINT,
    p_seleccion   VARCHAR,
    p_monto       NUMERIC,
    p_cuota       NUMERIC,
    p_origen      VARCHAR DEFAULT NULL
) RETURNS TABLE (apuesta_id BIGINT, estado VARCHAR, saldo_disponible NUMERIC,
                 monto_en_juego NUMERIC, es_reenvio BOOLEAN)
LANGUAGE plpgsql AS $$
#variable_conflict use_column
DECLARE
    v_bankroll  bankroll;
    v_previa    apuesta;
    v_partido   VARCHAR;
    v_id        BIGINT;
    v_seleccion VARCHAR := btrim(p_seleccion);
BEGIN
    -- 1. Bloqueo primero: dos reenvíos simultáneos con la misma clave
    --    quedan en fila y el segundo ve la apuesta del primero.
    v_bankroll := bloquear_bankroll(p_usuario_id);

    -- 2. Idempotencia.
    SELECT a.* INTO v_previa FROM apuesta a
     WHERE a.usuario_id = p_usuario_id AND a.clave_operacion = p_clave;
    IF FOUND THEN
        IF (v_previa.partido_id, v_previa.seleccion, v_previa.monto, v_previa.cuota)
           IS DISTINCT FROM (p_partido_id, v_seleccion, p_monto, p_cuota) THEN
            RAISE EXCEPTION 'clave_reutilizada'
                USING DETAIL = 'La clave ya se usó con otros datos de apuesta.';
        END IF;
        RETURN QUERY
            SELECT v_previa.apuesta_id, v_previa.estado, b.saldo_disponible, b.monto_en_juego, TRUE
              FROM bankroll b WHERE b.usuario_id = p_usuario_id;
        RETURN;
    END IF;

    -- 3. Validaciones con mensajes claros (los CHECK de la tabla son la
    --    segunda línea de defensa).
    SELECT p.estado INTO v_partido FROM partido p WHERE p.partido_id = p_partido_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'partido_inexistente';
    ELSIF v_partido <> 'programado' THEN
        RAISE EXCEPTION 'partido_no_disponible'
            USING DETAIL = format('El partido %s está %s.', p_partido_id, v_partido);
    END IF;

    IF p_monto IS NULL OR p_monto <= 0 OR p_monto <> round(p_monto, 2) THEN
        RAISE EXCEPTION 'monto_invalido';
    END IF;
    IF p_cuota IS NULL OR p_cuota <= 1 OR p_cuota <> round(p_cuota, 2) THEN
        RAISE EXCEPTION 'cuota_invalida';
    END IF;

    -- 4. Fondos. El límite semanal NO bloquea aquí: la app avisa y el
    --    usuario decide (F6 da el dato).
    IF v_bankroll.saldo_disponible < p_monto THEN
        RAISE EXCEPTION 'saldo_insuficiente'
            USING DETAIL = format('Disponible %s, apuesta %s.', v_bankroll.saldo_disponible, p_monto);
    END IF;

    -- 5. Apuesta + reserva del monto.
    INSERT INTO apuesta (usuario_id, partido_id, clave_operacion, seleccion, monto, cuota, origen)
    VALUES (p_usuario_id, p_partido_id, p_clave, v_seleccion, p_monto, p_cuota, p_origen)
    RETURNING apuesta.apuesta_id INTO v_id;

    INSERT INTO movimiento (usuario_id, apuesta_id, tipo, cambio_disponible, cambio_en_juego)
    VALUES (p_usuario_id, v_id, 'reserva', -p_monto, p_monto);

    RETURN QUERY
        SELECT v_id, 'pendiente'::VARCHAR, b.saldo_disponible, b.monto_en_juego, FALSE
          FROM bankroll b WHERE b.usuario_id = p_usuario_id;
END $$;


-- ---------------------------------------------------------------------
-- F5. Resolver una apuesta pendiente.
--     ganada  -> regresa monto × cuota (redondeado a centavos)
--     perdida -> regresa 0
--     anulada -> regresa el monto
--     En los tres casos el monto sale de "en juego".
--     Repetir el mismo resultado es idempotente; uno distinto es conflicto.
-- ---------------------------------------------------------------------
CREATE FUNCTION resolver_apuesta(
    p_usuario_id  BIGINT,
    p_apuesta_id  BIGINT,
    p_resultado   VARCHAR
) RETURNS TABLE (apuesta_id BIGINT, estado VARCHAR, saldo_disponible NUMERIC,
                 monto_en_juego NUMERIC, es_reenvio BOOLEAN)
LANGUAGE plpgsql AS $$
#variable_conflict use_column
DECLARE
    v_apuesta  apuesta;
    v_retorno  NUMERIC(12,2);
BEGIN
    IF p_resultado IS NULL OR p_resultado NOT IN ('ganada', 'perdida', 'anulada') THEN
        RAISE EXCEPTION 'resultado_invalido';
    END IF;

    PERFORM bloquear_bankroll(p_usuario_id);

    SELECT a.* INTO v_apuesta FROM apuesta a
     WHERE a.apuesta_id = p_apuesta_id AND a.usuario_id = p_usuario_id
       FOR UPDATE;
    IF NOT FOUND THEN
        -- También cubre pedir la apuesta de otro usuario.
        RAISE EXCEPTION 'apuesta_inexistente';
    END IF;

    IF v_apuesta.estado = p_resultado THEN
        RETURN QUERY
            SELECT v_apuesta.apuesta_id, v_apuesta.estado, b.saldo_disponible, b.monto_en_juego, TRUE
              FROM bankroll b WHERE b.usuario_id = p_usuario_id;
        RETURN;
    ELSIF v_apuesta.estado <> 'pendiente' THEN
        RAISE EXCEPTION 'resultado_en_conflicto'
            USING DETAIL = format('La apuesta %s ya está %s.', p_apuesta_id, v_apuesta.estado);
    END IF;

    v_retorno := CASE p_resultado
                     WHEN 'ganada'  THEN round(v_apuesta.monto * v_apuesta.cuota, 2)
                     WHEN 'anulada' THEN v_apuesta.monto
                     ELSE 0
                 END;

    UPDATE apuesta a SET estado = p_resultado WHERE a.apuesta_id = p_apuesta_id;

    INSERT INTO movimiento (usuario_id, apuesta_id, tipo, cambio_disponible, cambio_en_juego)
    VALUES (p_usuario_id, p_apuesta_id, 'liquidacion', v_retorno, -v_apuesta.monto);

    RETURN QUERY
        SELECT p_apuesta_id, p_resultado, b.saldo_disponible, b.monto_en_juego, FALSE
          FROM bankroll b WHERE b.usuario_id = p_usuario_id;
END $$;


-- ---------------------------------------------------------------------
-- F6. Monto apostado en la semana (lunes a domingo, hora del centro de
--     México). Excluye anuladas porque ese dinero regresó al usuario.
--     La API lo compara con limite_semanal para mostrar la alerta.
-- ---------------------------------------------------------------------
CREATE FUNCTION apostado_semana(p_usuario_id BIGINT, p_momento TIMESTAMPTZ DEFAULT now())
RETURNS NUMERIC
LANGUAGE sql STABLE AS $$
    WITH semana AS (
        SELECT date_trunc('week', p_momento AT TIME ZONE 'America/Mexico_City')
                   AT TIME ZONE 'America/Mexico_City' AS inicio
    )
    SELECT COALESCE(SUM(a.monto), 0)::NUMERIC(12,2)
      FROM apuesta a, semana s
     WHERE a.usuario_id = p_usuario_id
       AND a.estado <> 'anulada'
       AND a.registrada_en >= s.inicio
       AND a.registrada_en <  s.inicio + INTERVAL '7 days';
$$;


-- ---------------------------------------------------------------------
-- F7. Ganancia neta deportiva: solo apuestas resueltas.
-- ---------------------------------------------------------------------
CREATE FUNCTION ganancia_neta(p_usuario_id BIGINT)
RETURNS NUMERIC
LANGUAGE sql STABLE AS $$
    SELECT COALESCE(SUM(CASE a.estado
                            WHEN 'ganada'  THEN round(a.monto * a.cuota, 2) - a.monto
                            WHEN 'perdida' THEN -a.monto
                            ELSE 0
                        END), 0)::NUMERIC(12,2)
      FROM apuesta a
     WHERE a.usuario_id = p_usuario_id;
$$;


-- ---------------------------------------------------------------------
-- F8. Conciliación: el bankroll guardado debe coincidir con la suma de
--     sus movimientos, y lo "en juego" con las apuestas pendientes.
--     Útil en pruebas y después de una recuperación de nodo (#18).
-- ---------------------------------------------------------------------
CREATE FUNCTION conciliar_bankroll()
RETURNS TABLE (usuario_id BIGINT, saldo_bankroll NUMERIC, saldo_movimientos NUMERIC,
               en_juego_bankroll NUMERIC, en_juego_movimientos NUMERIC,
               en_juego_apuestas NUMERIC, cuadra BOOLEAN)
LANGUAGE sql STABLE AS $$
    SELECT b.usuario_id,
           b.saldo_disponible,
           m.disponible,
           b.monto_en_juego,
           m.en_juego,
           p.pendiente,
           b.saldo_disponible = m.disponible
             AND b.monto_en_juego = m.en_juego
             AND b.monto_en_juego = p.pendiente
      FROM bankroll b
      CROSS JOIN LATERAL (
          SELECT COALESCE(SUM(cambio_disponible), 0) AS disponible,
                 COALESCE(SUM(cambio_en_juego), 0)   AS en_juego
            FROM movimiento WHERE movimiento.usuario_id = b.usuario_id) m
      CROSS JOIN LATERAL (
          SELECT COALESCE(SUM(monto), 0) AS pendiente
            FROM apuesta WHERE apuesta.usuario_id = b.usuario_id
                           AND apuesta.estado = 'pendiente') p
     ORDER BY b.usuario_id;
$$;


-- ---------------------------------------------------------------------
-- Vista de resumen para "Mis apuestas" / "Mis resultados".
-- ---------------------------------------------------------------------
CREATE VIEW v_bankroll_resumen AS
SELECT u.usuario_id,
       u.alias,
       b.saldo_disponible,
       b.monto_en_juego,
       ganancia_neta(u.usuario_id)   AS ganancia_neta,
       b.limite_semanal,
       apostado_semana(u.usuario_id) AS apostado_semana
  FROM usuario u
  JOIN bankroll b ON b.usuario_id = u.usuario_id;
