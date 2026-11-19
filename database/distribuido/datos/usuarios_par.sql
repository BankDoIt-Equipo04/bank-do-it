-- BANKDOIT · Datos del fragmento PAR (primario en el Nodo B) (#17).
-- La API enviaría aquí a todo usuario con usuario_id % 2 = 0.
SELECT crear_usuario('beto_td', '$argon2id$v=19$m=65536,t=3,p=4$EJEMPLO$soloParaPruebas2', 800.00, NULL, 'usuario', 4);
SELECT setval(pg_get_serial_sequence('usuario', 'usuario_id'), 4);   -- el siguiente será 6

-- B-1: Chivas (101), $200 a 3.10 -> pendiente. El partido 101 llegó
-- desde el primario impar por la suscripción del catálogo.
SELECT apuesta_id, saldo_disponible, monto_en_juego
  FROM registrar_apuesta(4, 'demo-beto-1', 101, 'Chivas', 200.00, 3.10);
