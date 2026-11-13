-- 0001: the two schemas, the two roles and the record of applied migrations.
--
-- core holds the working records. pub holds the views meant for publication.
-- muster is the only role that may write core. pub_ro is the only role that
-- may read pub. Neither role can log in until whoever deploys Logbook gives it
-- a password; no password is ever written in this repository.

REVOKE ALL ON SCHEMA public FROM PUBLIC;

DO $$
BEGIN
    EXECUTE format('REVOKE ALL ON DATABASE %I FROM PUBLIC', current_database());
END
$$;

-- Functions are executable by everyone unless that is taken away. Take it away
-- for everything these migrations create from here on.
ALTER DEFAULT PRIVILEGES REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

-- Roles belong to the whole server, so they may already be there. A role that
-- exists with more power than Logbook gives it is refused, not adjusted.
DO $$
DECLARE
    wanted text;
BEGIN
    FOREACH wanted IN ARRAY ARRAY['muster', 'pub_ro'] LOOP
        IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = wanted) THEN
            EXECUTE format(
                'CREATE ROLE %I NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS',
                wanted);
        ELSIF EXISTS (
            SELECT FROM pg_catalog.pg_roles
            WHERE rolname = wanted
              AND (rolsuper OR rolcreatedb OR rolcreaterole OR rolreplication OR rolbypassrls)
        ) OR EXISTS (
            SELECT FROM pg_catalog.pg_auth_members m
            JOIN pg_catalog.pg_roles r ON r.oid = m.member
            WHERE r.rolname = wanted
        ) THEN
            RAISE EXCEPTION 'E_NEEDS_SUBTOOL: role % already exists with powers Logbook does not give it', wanted;
        END IF;
    END LOOP;
END
$$;

CREATE SCHEMA core;
COMMENT ON SCHEMA core IS 'Working records. Read and written by Muster only.';

CREATE SCHEMA pub;
COMMENT ON SCHEMA pub IS 'Views of the working records that are safe to publish. Read-only, for Conn.';

CREATE TABLE core.migration (
    version    text PRIMARY KEY CHECK (version ~ '^[0-9]{4}_[a-z0-9_]+$'),
    checksum   text NOT NULL CHECK (checksum ~ '^[0-9a-f]{64}$'),
    applied_at timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE core.migration IS 'One row for each migration applied, with the SHA-256 of the file as it was applied.';
