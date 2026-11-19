-- BANKDOIT · Datos del fragmento IMPAR (primario en el Nodo A) (#17).
-- La API enviaría aquí a todo usuario con usuario_id % 2 = 1.
SELECT crear_usuario('admin',   '$argon2id$v=19$m=65536,t=3,p=4$EJEMPLO$soloParaPruebas0',    0.00, NULL,  'administrador', 1);
SELECT crear_usuario('ana_gol', '$argon2id$v=19$m=65536,t=3,p=4$EJEMPLO$soloParaPruebas1', 1000.00, 500.00, 'usuario', 3);
SELECT setval(pg_get_serial_sequence('usuario', 'usuario_id'), 3);   -- el siguiente será 5

-- A-1: América (101), $100 a 2.00 -> pendiente
SELECT apuesta_id, saldo_disponible, monto_en_juego
  FROM registrar_apuesta(3, 'demo-ana-1', 101, 'América', 100.00, 2.00, 'App A');
-- A-2: Chiefs (202), $50 a 1.80 -> ganada
SELECT apuesta_id, saldo_disponible, monto_en_juego
  FROM registrar_apuesta(3, 'demo-ana-2', 202, 'Chiefs', 50.00, 1.80, 'App B');
SELECT apuesta_id, estado, saldo_disponible, monto_en_juego
  FROM resolver_apuesta(3, (SELECT apuesta_id FROM apuesta WHERE clave_operacion = 'demo-ana-2'), 'ganada');
