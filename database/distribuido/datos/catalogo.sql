-- BANKDOIT · Catálogo común de prueba (#17).
-- Se carga SOLO en el primario impar; llega al fragmento par por la
-- suscripción "catalogo" y a ambas réplicas por replicación física.
INSERT INTO deporte (deporte_id, nombre) VALUES
    (1, 'Fútbol'),
    (2, 'Fútbol americano');

INSERT INTO equipo (equipo_id, deporte_id, nombre) VALUES
    (1, 1, 'América'),
    (2, 1, 'Chivas'),
    (3, 2, 'Chiefs'),
    (4, 2, 'Eagles');

INSERT INTO partido (partido_id, deporte_id, equipo_local_id, equipo_visitante_id, fecha_hora) VALUES
    (42,  1, 2, 1, '2026-11-22 19:00-06'),
    (101, 1, 1, 2, '2026-11-29 19:00-06'),
    (202, 2, 3, 4, '2026-11-30 18:20-06');

SELECT setval(pg_get_serial_sequence('deporte', 'deporte_id'), (SELECT max(deporte_id) FROM deporte));
SELECT setval(pg_get_serial_sequence('equipo',  'equipo_id'),  (SELECT max(equipo_id)  FROM equipo));
SELECT setval(pg_get_serial_sequence('partido', 'partido_id'), (SELECT max(partido_id) FROM partido));
