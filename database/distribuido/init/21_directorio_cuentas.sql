-- =====================================================================
-- BANKDOIT · 21_directorio_cuentas.sql  (#32, acordado con Luis)
-- Directorio único de cuentas y sesiones. Vive SOLO en el primario
-- impar (Nodo A), igual que el dueño del catálogo, y se respalda en su
-- réplica síncrona del Nodo B.
--
--   * Asigna el usuario_id al registrar (secuencia global 1001, 1002...);
--     la paridad del id decide el fragmento del bankroll y las apuestas.
--   * Garantiza alias único en todo BANKDOIT sin importar mayúsculas.
--   * Guarda sal y clave derivada (PBKDF2, calculadas por la API) y las
--     sesiones (huella SHA-256 del token, usuario_id, vencimiento).
--
-- Idempotente. Lo ejecuta 20_acceso_api.sh en el primario impar con:
--   psql -f 21_directorio_cuentas.sql
-- =====================================================================
\set ON_ERROR_STOP on
BEGIN;

CREATE TABLE IF NOT EXISTS cuenta (
    usuario_id      BIGINT GENERATED ALWAYS AS IDENTITY (START WITH 1001) PRIMARY KEY,
    alias           VARCHAR(40) NOT NULL,
    sal             BYTEA NOT NULL,
    clave_derivada  BYTEA NOT NULL,
    rol             VARCHAR(13) NOT NULL DEFAULT 'usuario',
    -- pendiente: registrada en el directorio, falta crear su bankroll en el fragmento.
    estado          VARCHAR(10) NOT NULL DEFAULT 'pendiente',
    creada_en       TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT ck_cuenta_alias  CHECK (alias ~ '^[A-Za-z0-9_.-]{3,40}$'),
    CONSTRAINT ck_cuenta_sal    CHECK (length(sal) >= 16),
    CONSTRAINT ck_cuenta_clave  CHECK (length(clave_derivada) >= 32),
    CONSTRAINT ck_cuenta_rol    CHECK (rol IN ('usuario', 'administrador')),
    CONSTRAINT ck_cuenta_estado CHECK (estado IN ('pendiente', 'activa', 'suspendida'))
);
-- Alias único sin importar mayúsculas: "Luis" y "luis" son el mismo.
CREATE UNIQUE INDEX IF NOT EXISTS uq_cuenta_alias ON cuenta (lower(alias));

CREATE TABLE IF NOT EXISTS sesion (
    huella      BYTEA PRIMARY KEY,                 -- SHA-256 del token; el token nunca se guarda
    usuario_id  BIGINT NOT NULL REFERENCES cuenta (usuario_id),
    vence       TIMESTAMPTZ NOT NULL,
    creada_en   TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT ck_sesion_huella CHECK (length(huella) = 32),
    CONSTRAINT ck_sesion_vence  CHECK (vence > creada_en)
);
CREATE INDEX IF NOT EXISTS ix_sesion_usuario ON sesion (usuario_id);
CREATE INDEX IF NOT EXISTS ix_sesion_vence ON sesion (vence);

-- ---------------------------------------------------------------------
-- Funciones para la API (SECURITY DEFINER: la API no toca las tablas).
-- Errores: SQLSTATE P0001 con mensaje estable.
-- ---------------------------------------------------------------------

-- POST /auth/registro, paso 1: reserva alias e id. Devuelve el id.
CREATE OR REPLACE FUNCTION registrar_cuenta(p_alias VARCHAR, p_sal BYTEA, p_clave BYTEA)
RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_id BIGINT;
BEGIN
    INSERT INTO cuenta (alias, sal, clave_derivada)
    VALUES (p_alias, p_sal, p_clave)
    RETURNING usuario_id INTO v_id;
    RETURN v_id;
EXCEPTION
    WHEN unique_violation THEN
        RAISE EXCEPTION 'alias_duplicado' USING DETAIL = 'El alias ya existe (sin distinguir mayúsculas).';
    WHEN check_violation THEN
        RAISE EXCEPTION 'cuenta_invalida' USING DETAIL = SQLERRM;
END $$;

-- POST /auth/registro, paso 3: la cuenta queda activa cuando su bankroll
-- ya existe en el fragmento. Repetirlo no tiene efecto.
CREATE OR REPLACE FUNCTION activar_cuenta(p_usuario_id BIGINT)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    UPDATE cuenta SET estado = 'activa'
     WHERE usuario_id = p_usuario_id AND estado = 'pendiente';
    IF NOT FOUND AND NOT EXISTS (SELECT 1 FROM cuenta WHERE usuario_id = p_usuario_id) THEN
        RAISE EXCEPTION 'cuenta_inexistente';
    END IF;
END $$;

-- POST /auth/login: la API recibe sal y clave derivada y compara en Python.
CREATE OR REPLACE FUNCTION buscar_cuenta(p_alias VARCHAR)
RETURNS TABLE (usuario_id BIGINT, alias VARCHAR, sal BYTEA, clave_derivada BYTEA,
               rol VARCHAR, estado VARCHAR)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
    SELECT c.usuario_id, c.alias, c.sal, c.clave_derivada, c.rol, c.estado
      FROM cuenta c WHERE lower(c.alias) = lower(p_alias);
$$;

CREATE OR REPLACE FUNCTION crear_sesion(p_huella BYTEA, p_usuario_id BIGINT, p_vence TIMESTAMPTZ)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM cuenta WHERE usuario_id = p_usuario_id AND estado = 'activa') THEN
        RAISE EXCEPTION 'cuenta_no_activa';
    END IF;
    DELETE FROM sesion WHERE vence <= now();          -- limpieza de vencidas
    INSERT INTO sesion (huella, usuario_id, vence) VALUES (p_huella, p_usuario_id, p_vence);
END $$;

-- Devuelve el usuario_id de una sesión vigente o NULL.
CREATE OR REPLACE FUNCTION validar_sesion(p_huella BYTEA)
RETURNS BIGINT
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
    SELECT s.usuario_id FROM sesion s JOIN cuenta c USING (usuario_id)
     WHERE s.huella = p_huella AND s.vence > now() AND c.estado = 'activa';
$$;

-- POST /auth/logout. Devuelve true si había una sesión.
CREATE OR REPLACE FUNCTION cerrar_sesion(p_huella BYTEA)
RETURNS BOOLEAN
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    DELETE FROM sesion WHERE huella = p_huella;
    RETURN FOUND;
END $$;

REVOKE ALL ON cuenta, sesion FROM PUBLIC, bankdoit_api;
REVOKE EXECUTE ON FUNCTION registrar_cuenta(VARCHAR, BYTEA, BYTEA), activar_cuenta(BIGINT),
    buscar_cuenta(VARCHAR), crear_sesion(BYTEA, BIGINT, TIMESTAMPTZ),
    validar_sesion(BYTEA), cerrar_sesion(BYTEA) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION registrar_cuenta(VARCHAR, BYTEA, BYTEA), activar_cuenta(BIGINT),
    buscar_cuenta(VARCHAR), crear_sesion(BYTEA, BIGINT, TIMESTAMPTZ),
    validar_sesion(BYTEA), cerrar_sesion(BYTEA) TO bankdoit_api;

COMMIT;
SELECT 'directorio de cuentas listo en el primario impar' AS resultado;
