-- Logbook migration 0004: the read-only role for Conn.
--
-- pub_ro may use the pub schema and SELECT from its views. It is given
-- nothing in core.
--
-- The role is created without LOGIN and without a password: credentials do
-- not belong in a migration. Whoever deploys Logbook decides how Conn
-- becomes pub_ro.
--
-- Roles belong to the whole PostgreSQL server, not to one database, so the
-- role may already exist when this runs against a second database.

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pub_ro') THEN
        CREATE ROLE pub_ro NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE
            NOINHERIT NOREPLICATION NOBYPASSRLS;
    END IF;
END
$$;

GRANT USAGE ON SCHEMA pub TO pub_ro;
GRANT SELECT ON ALL TABLES IN SCHEMA pub TO pub_ro;

-- Views added to pub by later migrations (run by the same owner) are
-- readable by pub_ro without a further grant.
ALTER DEFAULT PRIVILEGES IN SCHEMA pub GRANT SELECT ON TABLES TO pub_ro;
