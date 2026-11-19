-- =====================================================================
-- BANKDOIT · 03_datos_prueba.sql
-- Datos sintéticos: el ejemplo de docs/distribucion-datos.md (#3).
--   usuario 3 (ana_gol, impar) -> $1,000
--   usuario 4 (beto_td, par)   -> $800
-- Todo se registra con las funciones, igual que lo haría la API.
-- Los hash son de ejemplo; nunca se guardan contraseñas reales.
-- =====================================================================

-- Catálogo común --------------------------------------------------------
INSERT INTO deporte (deporte_id, nombre) VALUES
    (1, 'Fútbol'),
    (2, 'Fútbol americano');

INSERT INTO equipo (equipo_id, deporte_id, nombre) VALUES
    (1, 1, 'América'),
    (2, 1, 'Chivas'),
    (3, 2, 'Chiefs'),
    (4, 2, 'Eagles');

-- Los mismos partido_id que usa la demo de la API (42, 101, 202).
INSERT INTO partido (partido_id, deporte_id, equipo_local_id, equipo_visitante_id, fecha_hora) VALUES
    (42,  1, 2, 1, '2026-11-22 19:00-06'),
    (101, 1, 1, 2, '2026-11-29 19:00-06'),
    (202, 2, 3, 4, '2026-11-30 18:20-06');

-- Las identidades continúan después de los ids fijos.
SELECT setval(pg_get_serial_sequence('deporte', 'deporte_id'), (SELECT max(deporte_id) FROM deporte));
SELECT setval(pg_get_serial_sequence('equipo',  'equipo_id'),  (SELECT max(equipo_id)  FROM equipo));
SELECT setval(pg_get_serial_sequence('partido', 'partido_id'), (SELECT max(partido_id) FROM partido));

-- Usuarios de prueba ----------------------------------------------------
SELECT crear_usuario('ana_gol', '$argon2id$v=19$m=65536,t=3,p=4$EJEMPLO$soloParaPruebas1', 1000.00, 500.00, 'usuario', 3);
SELECT crear_usuario('beto_td', '$argon2id$v=19$m=65536,t=3,p=4$EJEMPLO$soloParaPruebas2',  800.00, NULL,   'usuario', 4);
SELECT crear_usuario('admin',   '$argon2id$v=19$m=65536,t=3,p=4$EJEMPLO$soloParaPruebas0',    0.00, NULL,   'administrador', 1);
SELECT setval(pg_get_serial_sequence('usuario', 'usuario_id'), (SELECT max(usuario_id) FROM usuario));

-- Apuestas del ejemplo de #3 -------------------------------------------
-- A-1: ana_gol, América (101), $100 a 2.00 -> queda pendiente
SELECT * FROM registrar_apuesta(3, 'demo-ana-1', 101, 'América', 100.00, 2.00, 'App A');
-- A-2: ana_gol, Chiefs (202), $50 a 1.80 -> se resuelve ganada
SELECT * FROM registrar_apuesta(3, 'demo-ana-2', 202, 'Chiefs', 50.00, 1.80, 'App B');
SELECT * FROM resolver_apuesta(3, (SELECT apuesta_id FROM apuesta WHERE clave_operacion = 'demo-ana-2'), 'ganada');
-- B-1: beto_td, Chivas (101), $200 a 3.10 -> queda pendiente
SELECT * FROM registrar_apuesta(4, 'demo-beto-1', 101, 'Chivas', 200.00, 3.10);

-- Resultado esperado (ver docs/distribucion-datos.md, sección 4.4):
--   usuario 3: disponible 940.00, en juego 100.00, ganancia neta +40.00
--   usuario 4: disponible 600.00, en juego 200.00, ganancia neta   0.00
SELECT usuario_id, alias, saldo_disponible, monto_en_juego, ganancia_neta
  FROM v_bankroll_resumen ORDER BY usuario_id;
