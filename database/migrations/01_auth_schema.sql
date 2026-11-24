-- ==============================================================================
-- SENA CADPH Garzón · Regional Huila · ADSO — Proyecto transversal
-- Sesión 06 · Migración 01: esquema de autenticación (database/migrations/01_auth_schema.sql)
-- ==============================================================================
-- Ejecución:  psql -U postgres -d adso_auth_db -f database/migrations/01_auth_schema.sql
-- ==============================================================================

-- -----------------------------------------------------------------------------
-- 0. HABILITAR EXTENSIONES CRIPTOGRÁFICAS
-- -----------------------------------------------------------------------------
-- gen_random_uuid() es nativa desde PostgreSQL 13; pgcrypto aporta digest() y
-- gen_random_bytes(), que usamos en la semilla para simular tokens.
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- Limpieza preventiva SOLO para el laboratorio local.
-- ¡NUNCA ejecutar estos DROP contra una base de datos de producción!
DROP TABLE IF EXISTS verification_tokens CASCADE;
DROP TABLE IF EXISTS users CASCADE;

-- -----------------------------------------------------------------------------
-- RETO 1: MODELADO DE LA TABLA DE USUARIOS (users)
-- -----------------------------------------------------------------------------
CREATE TABLE users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email VARCHAR(150) NOT NULL,
    password_hash VARCHAR(255) NOT NULL,
    role VARCHAR(20) NOT NULL DEFAULT 'user',
    is_verified BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    -- Restricciones de integridad y dominio
    CONSTRAINT uq_users_email UNIQUE (email),
    CONSTRAINT chk_users_email_lower CHECK (email = LOWER(email)),
    CONSTRAINT chk_users_role CHECK (role IN ('admin', 'user'))
);

COMMENT ON TABLE users IS 'Almacén de identidades de usuarios del sistema con roles y estado de activación';
COMMENT ON COLUMN users.id IS 'Identificador universal único UUID v4 (no enumerable)';
COMMENT ON COLUMN users.email IS 'Correo normalizado en minúsculas: Ana@Sena.edu.co y ana@sena.edu.co son la misma cuenta';
COMMENT ON COLUMN users.password_hash IS 'Hash bcrypt (60 caracteres). La contraseña en texto plano NUNCA se almacena';
COMMENT ON COLUMN users.is_verified IS 'Bandera de confirmación de email activada por el enlace enviado con Resend';

-- -----------------------------------------------------------------------------
-- RETO 1.1: updated_at AUTOMÁTICO CON TRIGGER
-- -----------------------------------------------------------------------------
-- DEFAULT NOW() solo actúa en el INSERT. Para que updated_at cambie en cada
-- UPDATE, el motor ejecuta esta función antes de guardar la fila modificada.
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_users_updated_at
    BEFORE UPDATE ON users
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();

-- -----------------------------------------------------------------------------
-- RETO 2: MODELADO DE LA TABLA DE TOKENS DE VERIFICACIÓN (verification_tokens)
-- -----------------------------------------------------------------------------
-- SEGURIDAD: guardamos el HASH SHA-256 del token, nunca el token original.
-- El token original solo viaja en el enlace del correo. Si alguien roba una copia
-- de la base de datos, no puede usar los hashes para activar cuentas ajenas.
CREATE TABLE verification_tokens (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL,
    token_hash CHAR(64) NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    -- Restricción foránea estricta con eliminación en cascada
    CONSTRAINT fk_tokens_user FOREIGN KEY (user_id)
        REFERENCES users(id)
        ON DELETE CASCADE,

    -- Unicidad del hash del token
    CONSTRAINT uq_tokens_token_hash UNIQUE (token_hash)
);

COMMENT ON TABLE verification_tokens IS 'Tokens temporales de un solo uso para activación de cuenta vía correo';
COMMENT ON COLUMN verification_tokens.token_hash IS 'SHA-256 en hexadecimal (64 caracteres) del token enviado por correo';

-- -----------------------------------------------------------------------------
-- RETO 3: ÍNDICES DE RENDIMIENTO (B-TREE)
-- -----------------------------------------------------------------------------
-- IMPORTANTE: PRIMARY KEY y UNIQUE ya crean automáticamente un índice B-Tree.
--   users_pkey, uq_users_email, verification_tokens_pkey, uq_tokens_token_hash
-- Crear otro índice sobre email o token_hash sería un DUPLICADO que solo hace
-- más lentas las escrituras.
--
-- Lo que PostgreSQL NO indexa por sí solo es la llave foránea (user_id).
-- Ese índice acelera los JOIN y el borrado en cascada:
CREATE INDEX IF NOT EXISTS idx_tokens_user_id ON verification_tokens(user_id);

-- Verificación en psql:  \di
-- Resultado esperado: 5 índices (2 PK + 2 UNIQUE + idx_tokens_user_id)
