-- =====================================================================
-- BANKDOIT · pruebas_integridad.sql
-- Demuestra las reglas del Issue #16 sobre una base recién creada.
-- Todo corre dentro de una transacción que termina en ROLLBACK, así que
-- la base queda igual que antes. Con ON_ERROR_STOP, la primera prueba
-- que falle detiene la ejecución con el mensaje "FALLO: ...".
-- =====================================================================
\set ON_ERROR_STOP on
\pset footer off
SET client_min_messages = notice;
-- Los resultados de cada verificación son vacíos: se ocultan y solo se
-- muestran los avisos "OK ..." y la tabla de conciliación.
\o /dev/null

BEGIN;

-- Ayudantes ------------------------------------------------------------
CREATE FUNCTION pg_temp.verificar(p_condicion BOOLEAN, p_nombre TEXT)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    IF p_condicion IS NOT TRUE THEN
        RAISE EXCEPTION 'FALLO: %', p_nombre;
    END IF;
    RAISE NOTICE 'OK   %', p_nombre;
END $$;

-- Ejecuta p_sql y exige que falle con el mensaje o SQLSTATE esperado.
CREATE FUNCTION pg_temp.debe_fallar(p_sql TEXT, p_esperado TEXT, p_nombre TEXT)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    EXECUTE p_sql;
    RAISE EXCEPTION 'FALLO: % (se esperaba "%", pero no hubo error)', p_nombre, p_esperado;
EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'FALLO:%' THEN
        RAISE;
    ELSIF SQLERRM <> p_esperado AND SQLSTATE <> p_esperado THEN
        RAISE EXCEPTION 'FALLO: % (se esperaba "%", se obtuvo "%" / %)',
            p_nombre, p_esperado, SQLERRM, SQLSTATE;
    END IF;
    RAISE NOTICE 'OK   % -> %', p_nombre, p_esperado;
END $$;

CREATE FUNCTION pg_temp.saldo(p_usuario BIGINT) RETURNS TEXT
LANGUAGE sql AS $$
    SELECT saldo_disponible || '/' || monto_en_juego FROM bankroll WHERE usuario_id = p_usuario;
$$;

\echo
\echo '== 1. Datos de prueba (ejemplo de #3) =='
SELECT pg_temp.verificar(pg_temp.saldo(3) = '940.00/100.00', 'usuario 3: $940 disponibles y $100 en juego');
SELECT pg_temp.verificar(ganancia_neta(3) = 40.00,           'usuario 3: ganancia neta +$40');
SELECT pg_temp.verificar(pg_temp.saldo(4) = '600.00/200.00', 'usuario 4: $600 disponibles y $200 en juego');
SELECT pg_temp.verificar(ganancia_neta(4) = 0.00,            'usuario 4: ganancia neta $0');
SELECT pg_temp.verificar(
    (SELECT count(*) FROM apuesta WHERE partido_id = 101) = 2,
    'partido 101 tiene apuestas de los dos usuarios (mismo catálogo)');

\echo
\echo '== 2. Ejemplo del PDF y de docs/api-bankroll.md: $1,000, apuesta de $100 a 2.00 =='
DO $$
DECLARE
    r RECORD;
    v_usuario BIGINT;
    v_apuesta BIGINT;
    v_esperado CONSTANT JSONB := '{"ganada": "1100.00/0.00", "perdida": "900.00/0.00", "anulada": "1000.00/0.00"}';
    v_resultado TEXT;
BEGIN
    FOREACH v_resultado IN ARRAY ARRAY['ganada', 'perdida', 'anulada'] LOOP
        v_usuario := crear_usuario('prueba_' || v_resultado, repeat('x', 30), 1000.00);
        SELECT * INTO r FROM registrar_apuesta(v_usuario, 'k-' || v_resultado, 101, 'Local', 100.00, 2.00);
        v_apuesta := r.apuesta_id;
        PERFORM pg_temp.verificar(pg_temp.saldo(v_usuario) = '900.00/100.00',
            format('al registrar (%s): $900 disponibles y $100 en juego', v_resultado));
        PERFORM resolver_apuesta(v_usuario, v_apuesta, v_resultado);
        PERFORM pg_temp.verificar(pg_temp.saldo(v_usuario) = v_esperado ->> v_resultado,
            format('%s: queda %s', v_resultado, v_esperado ->> v_resultado));
    END LOOP;
END $$;

\echo
\echo '== 3. Idempotencia: reenviar el mismo borrador cobra una sola vez =='
DO $$
DECLARE
    v_usuario BIGINT := crear_usuario('reenvio', repeat('x', 30), 1000.00);
    r1 RECORD;
    r2 RECORD;
BEGIN
    SELECT * INTO r1 FROM registrar_apuesta(v_usuario, 'borrador-123', 101, 'Local', 100.00, 2.00);
    SELECT * INTO r2 FROM registrar_apuesta(v_usuario, 'borrador-123', 101, 'Local', 100.00, 2.00);
    PERFORM pg_temp.verificar(r1.apuesta_id = r2.apuesta_id, 'ambos envíos devuelven la misma apuesta');
    PERFORM pg_temp.verificar(NOT r1.es_reenvio AND r2.es_reenvio, 'el segundo envío se marca como reenvío');
    PERFORM pg_temp.verificar(
        (SELECT count(*) FROM apuesta WHERE usuario_id = v_usuario) = 1, 'existe una sola apuesta');
    PERFORM pg_temp.verificar(
        (SELECT count(*) FROM movimiento WHERE usuario_id = v_usuario AND tipo = 'reserva') = 1,
        'existe un solo cargo (movimiento de reserva)');
    PERFORM pg_temp.verificar(pg_temp.saldo(v_usuario) = '900.00/100.00', 'saldo final $900 / $100');

    PERFORM pg_temp.debe_fallar(
        format($q$SELECT registrar_apuesta(%s, 'borrador-123', 101, 'Local', 250.00, 2.00)$q$, v_usuario),
        'clave_reutilizada', 'misma clave con otro monto');
END $$;

\echo
\echo '== 4. Validaciones al registrar una apuesta =='
SELECT pg_temp.debe_fallar($$SELECT registrar_apuesta(4, 'k-sin-fondos', 101, 'Chivas', 600.01, 2.00)$$,
                           'saldo_insuficiente', 'apuesta mayor al saldo disponible');
SELECT pg_temp.verificar(pg_temp.saldo(4) = '600.00/200.00', 'el intento sin fondos no cambió el saldo');
SELECT pg_temp.debe_fallar($$SELECT registrar_apuesta(4, 'k-cuota', 101, 'Chivas', 10.00, 1.00)$$,
                           'cuota_invalida', 'cuota igual a 1');
SELECT pg_temp.debe_fallar($$SELECT registrar_apuesta(4, 'k-monto0', 101, 'Chivas', 0, 2.00)$$,
                           'monto_invalido', 'monto en cero');
SELECT pg_temp.debe_fallar($$SELECT registrar_apuesta(4, 'k-centavos', 101, 'Chivas', 10.005, 2.00)$$,
                           'monto_invalido', 'monto con fracciones de centavo');
SELECT pg_temp.debe_fallar($$SELECT registrar_apuesta(4, 'k-partido', 999, 'Nadie', 10.00, 2.00)$$,
                           'partido_inexistente', 'partido que no existe');
SELECT pg_temp.debe_fallar($$SELECT registrar_apuesta(999, 'k-usuario', 101, 'Local', 10.00, 2.00)$$,
                           'usuario_inexistente', 'usuario que no existe');
SELECT pg_temp.debe_fallar($$SELECT registrar_apuesta(4, 'clave con espacios', 101, 'Chivas', 10.00, 2.00)$$,
                           '23514', 'clave de idempotencia con caracteres no válidos');

\echo
\echo '== 5. Resolver apuestas =='
SELECT pg_temp.verificar(
    (SELECT es_reenvio FROM resolver_apuesta(3, (SELECT apuesta_id FROM apuesta WHERE clave_operacion = 'demo-ana-2'), 'ganada')),
    'repetir el mismo resultado es idempotente');
SELECT pg_temp.verificar(pg_temp.saldo(3) = '940.00/100.00', 'repetir el resultado no volvió a pagar');
SELECT pg_temp.debe_fallar(
    $$SELECT resolver_apuesta(3, (SELECT apuesta_id FROM apuesta WHERE clave_operacion = 'demo-ana-2'), 'perdida')$$,
    'resultado_en_conflicto', 'cambiar una apuesta ya resuelta');
SELECT pg_temp.debe_fallar(
    $$SELECT resolver_apuesta(3, (SELECT apuesta_id FROM apuesta WHERE clave_operacion = 'demo-beto-1'), 'ganada')$$,
    'apuesta_inexistente', 'usuario 3 intenta resolver una apuesta del usuario 4');
SELECT pg_temp.debe_fallar(
    $$SELECT resolver_apuesta(3, (SELECT apuesta_id FROM apuesta WHERE clave_operacion = 'demo-ana-1'), 'cancelada')$$,
    'resultado_invalido', 'resultado fuera del catálogo');

\echo
\echo '== 6. Un solo bankroll por usuario y catálogo consistente =='
SELECT pg_temp.debe_fallar($$INSERT INTO bankroll (usuario_id) VALUES (3)$$,
                           '23505', 'segundo bankroll para el mismo usuario');
SELECT pg_temp.debe_fallar($$SELECT crear_usuario('ana_gol', repeat('x', 30), 10)$$,
                           '23505', 'alias duplicado');
SELECT pg_temp.debe_fallar($$SELECT crear_usuario('a b', repeat('x', 30), 10)$$,
                           '23514', 'alias con caracteres no válidos');
SELECT pg_temp.debe_fallar(
    $$INSERT INTO partido (deporte_id, equipo_local_id, equipo_visitante_id, fecha_hora) VALUES (1, 1, 1, now())$$,
    '23514', 'partido de un equipo contra sí mismo');
SELECT pg_temp.debe_fallar(
    $$INSERT INTO partido (deporte_id, equipo_local_id, equipo_visitante_id, fecha_hora) VALUES (1, 1, 3, now())$$,
    '23503', 'partido entre equipos de deportes distintos');

\echo
\echo '== 7. Triggers: el historial no se puede alterar por fuera =='
SELECT pg_temp.debe_fallar($$UPDATE bankroll SET saldo_disponible = 99999 WHERE usuario_id = 3$$,
                           'saldo_solo_por_movimientos', 'modificar el saldo directamente');
SELECT pg_temp.debe_fallar($$UPDATE bankroll SET monto_en_juego = 0 WHERE usuario_id = 3$$,
                           'saldo_solo_por_movimientos', 'modificar el monto en juego directamente');
SELECT pg_temp.debe_fallar($$UPDATE movimiento SET cambio_disponible = 5000 WHERE usuario_id = 3$$,
                           'movimiento_inmutable', 'editar un movimiento');
SELECT pg_temp.debe_fallar($$DELETE FROM movimiento WHERE usuario_id = 3$$,
                           'movimiento_inmutable', 'borrar un movimiento');
SELECT pg_temp.debe_fallar($$DELETE FROM apuesta WHERE usuario_id = 3$$,
                           'apuesta_no_borrable', 'borrar una apuesta');
SELECT pg_temp.debe_fallar($$UPDATE apuesta SET monto = 1 WHERE clave_operacion = 'demo-ana-1'$$,
                           'apuesta_inmutable', 'cambiar el monto de una apuesta registrada');
SELECT pg_temp.debe_fallar(
    $$INSERT INTO movimiento (usuario_id, apuesta_id, tipo, cambio_disponible, cambio_en_juego)
      SELECT 3, apuesta_id, 'reserva', -100, 100 FROM apuesta WHERE clave_operacion = 'demo-ana-1'$$,
    '23505', 'segundo cargo para la misma apuesta');
SELECT pg_temp.debe_fallar(
    $$INSERT INTO movimiento (usuario_id, tipo, cambio_disponible, cambio_en_juego) VALUES (4, 'retiro', -5000, 0)$$,
    '23514', 'retiro que dejaría el saldo negativo (CHECK de bankroll)');

-- Apuesta insertada "a mano" sin su reserva: el trigger diferido la
-- rechaza al confirmar. Se fuerza la revisión inmediata para probarlo.
SET CONSTRAINTS trg_apuesta_con_movimiento IMMEDIATE;
SELECT pg_temp.debe_fallar(
    $$INSERT INTO apuesta (usuario_id, partido_id, clave_operacion, seleccion, monto, cuota)
      VALUES (3, 101, 'a-mano', 'América', 10, 2)$$,
    'apuesta_sin_reserva', 'apuesta insertada sin descontar el saldo');
SET CONSTRAINTS trg_apuesta_con_movimiento DEFERRED;

\echo
\echo '== 8. Aportaciones, retiros y límite semanal =='
DO $$
DECLARE
    v_ganancia NUMERIC := ganancia_neta(3);
BEGIN
    PERFORM registrar_aportacion(3, 500.00);
    PERFORM pg_temp.verificar(pg_temp.saldo(3) = '1440.00/100.00', 'aportación de $500 sube el disponible');
    PERFORM pg_temp.verificar(ganancia_neta(3) = v_ganancia, 'la aportación no cuenta como ganancia');
    PERFORM registrar_retiro(3, 440.00);
    PERFORM pg_temp.verificar(pg_temp.saldo(3) = '1000.00/100.00', 'retiro de $440 baja el disponible');
    PERFORM pg_temp.debe_fallar('SELECT registrar_retiro(3, 1000.01)', 'saldo_insuficiente',
                                'retiro mayor al disponible');
    PERFORM pg_temp.verificar(apostado_semana(3) = 150.00, 'usuario 3 lleva $150 apostados esta semana');
END $$;

\echo
\echo '== 9. Conciliación: bankroll = suma de movimientos = apuestas pendientes =='
\o
SELECT * FROM conciliar_bankroll();
\o /dev/null
SELECT pg_temp.verificar((SELECT bool_and(cuadra) FROM conciliar_bankroll()),
                         'todos los bankrolls cuadran con su historial');

\o
\echo
\echo '>>> TODAS LAS PRUEBAS PASARON'
ROLLBACK;
