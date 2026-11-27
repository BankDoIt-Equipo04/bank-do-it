-- =====================================================================
-- BANKDOIT · 23_monitoreo.sql  (#59)
-- Funciones de monitoreo para cada PRIMARIO (llegan a su réplica por
-- replicación física) y rol de solo lectura para el exportador de
-- Prometheus. Idempotente; lo aplica 20_acceso_api.sh.
--
--   SELECT * FROM estado_replicacion();   -- en un primario: sus réplicas
--   SELECT * FROM estado_nodo();          -- en cualquier instancia
-- =====================================================================
\set ON_ERROR_STOP on
BEGIN;

-- Réplicas conectadas a este primario y su retraso.
CREATE OR REPLACE FUNCTION estado_replicacion()
RETURNS TABLE (replica TEXT, estado TEXT, sincronia TEXT, cliente INET,
               bytes_pendientes NUMERIC, retraso_escritura INTERVAL,
               retraso_aplicacion INTERVAL, ranura_activa BOOLEAN, wal_retenido_bytes NUMERIC)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
    SELECT r.application_name::TEXT, r.state::TEXT, r.sync_state::TEXT, r.client_addr,
           pg_wal_lsn_diff(pg_current_wal_lsn(), r.replay_lsn),
           r.write_lag, r.replay_lag,
           s.active,
           pg_wal_lsn_diff(pg_current_wal_lsn(), s.restart_lsn)
      FROM pg_stat_replication r
      LEFT JOIN pg_replication_slots s ON s.active_pid = r.pid
     WHERE NOT pg_is_in_recovery()
     ORDER BY r.application_name;
$$;

-- Una fila con la salud de la instancia (primario o réplica).
CREATE OR REPLACE FUNCTION estado_nodo()
RETURNS TABLE (fragmento TEXT, rol TEXT, replicas_esperadas INTEGER, replicas_sync INTEGER,
               esperando_replica INTEGER, esperando_bloqueo INTEGER, transacciones_largas INTEGER,
               conexiones INTEGER, conexiones_max INTEGER,
               retraso_replica_segundos NUMERIC, wal_recibido_sin_aplicar_bytes NUMERIC,
               archivados INTEGER, fallos_archivo INTEGER, ultimo_fallo_archivo TIMESTAMPTZ,
               archivo_al_dia BOOLEAN, descuadres_ultimo_mantenimiento INTEGER,
               ultimo_mantenimiento TIMESTAMPTZ, tamano_bytes BIGINT)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE
    v_rec BOOLEAN := pg_is_in_recovery();
BEGIN
    RETURN QUERY
    SELECT (SELECT f.nombre::TEXT FROM public.fragmento_local f),
           CASE WHEN v_rec THEN 'réplica' ELSE 'primario' END,
           CASE WHEN v_rec OR current_setting('synchronous_standby_names') = '' THEN 0 ELSE 1 END,
           (SELECT count(*)::INTEGER FROM pg_stat_replication WHERE sync_state = 'sync'),
           (SELECT count(*)::INTEGER FROM pg_stat_activity WHERE wait_event = 'SyncRep'),
           (SELECT count(*)::INTEGER FROM pg_stat_activity WHERE wait_event_type = 'Lock'),
           (SELECT count(*)::INTEGER FROM pg_stat_activity
             WHERE state <> 'idle' AND xact_start < now() - interval '1 minute' AND backend_type = 'client backend'),
           (SELECT count(*)::INTEGER FROM pg_stat_activity WHERE backend_type = 'client backend'),
           current_setting('max_connections')::INTEGER,
           CASE WHEN v_rec THEN
               CASE WHEN pg_last_wal_receive_lsn() = pg_last_wal_replay_lsn() THEN 0
                    ELSE round(extract(epoch FROM now() - pg_last_xact_replay_timestamp())::NUMERIC, 1) END
           END,
           CASE WHEN v_rec THEN pg_wal_lsn_diff(pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn()) END,
           a.archived_count::INTEGER, a.failed_count::INTEGER, a.last_failed_time,
           (a.last_failed_time IS NULL OR a.last_archived_time > a.last_failed_time),
           (SELECT b.bankrolls_descuadrados FROM public.bitacora_mantenimiento b ORDER BY b.ejecucion_id DESC LIMIT 1),
           (SELECT b.ejecutado_en FROM public.bitacora_mantenimiento b ORDER BY b.ejecucion_id DESC LIMIT 1),
           pg_database_size(current_database())
      FROM pg_stat_archiver a;
END $$;

REVOKE ALL ON FUNCTION estado_replicacion(), estado_nodo() FROM PUBLIC;

-- Rol del exportador de Prometheus (opcional: solo si hay contraseña).
SELECT format('CREATE ROLE bankdoit_monitor LOGIN PASSWORD %L', :'clave_monitor')
 WHERE :'clave_monitor' <> ''
   AND NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'bankdoit_monitor') \gexec
SELECT format('ALTER ROLE bankdoit_monitor WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION CONNECTION LIMIT 5 PASSWORD %L', :'clave_monitor')
 WHERE :'clave_monitor' <> '' \gexec
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'bankdoit_monitor') THEN
        GRANT pg_monitor TO bankdoit_monitor;            -- estadísticas del servidor
        EXECUTE format('GRANT CONNECT ON DATABASE %I TO bankdoit_monitor', current_database());
        GRANT USAGE ON SCHEMA public TO bankdoit_monitor;
        GRANT EXECUTE ON FUNCTION estado_replicacion(), estado_nodo() TO bankdoit_monitor;
        REVOKE ALL ON ALL TABLES IN SCHEMA public FROM bankdoit_monitor;
    END IF;
END $$;

COMMIT;
SELECT 'monitoreo listo en el fragmento ' || nombre AS resultado FROM fragmento_local;
