-- Logbook migration 0001: the three roles, the two schemas and the migration record.
--
-- Apply each migration once, in file-name order:
--   psql -X -v ON_ERROR_STOP=1 -f migrations/0001_roles_and_schemas.sql
-- A migration runs in one transaction. Applying it a second time is refused
-- and changes nothing.

BEGIN;

-- The roles carry privileges and nothing else: no login and no password.
-- Whoever deploys Logbook creates the login users and makes each one a member
-- of exactly one of these roles, so no credential is ever written here.
--
-- Roles belong to the whole server, not to one database, so a role may already
-- be there. A role that is there with more than this migration would give it
-- is unexpected, and the migration stops instead of guessing.
DO $$
DECLARE
  wanted text;
BEGIN
  FOREACH wanted IN ARRAY ARRAY['core_rw', 'pub_ro', 'backup_ro'] LOOP
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = wanted) THEN
      EXECUTE format('CREATE ROLE %I NOLOGIN', wanted);
    ELSIF EXISTS (
      SELECT FROM pg_catalog.pg_roles
      WHERE rolname = wanted
        AND (rolcanlogin OR rolsuper OR rolcreatedb OR rolcreaterole
             OR rolreplication OR rolbypassrls)
    ) THEN
      RAISE EXCEPTION 'role % already exists and can log in or has elevated attributes', wanted;
    ELSIF EXISTS (
      SELECT FROM pg_catalog.pg_auth_members m
      JOIN pg_catalog.pg_roles r ON r.oid = m.member
      WHERE r.rolname = wanted
    ) THEN
      RAISE EXCEPTION 'role % already exists and is a member of another role', wanted;
    END IF;
  END LOOP;
END
$$;

-- core holds the working records. pub holds the public views of them.
CREATE SCHEMA core;
CREATE SCHEMA pub;

GRANT USAGE ON SCHEMA core TO core_rw, backup_ro;
GRANT USAGE ON SCHEMA pub TO pub_ro, backup_ro;

-- Nobody connects, and nobody uses the default schema, unless a role above
-- lets them.
REVOKE ALL ON SCHEMA public FROM PUBLIC;

DO $$
BEGIN
  EXECUTE format('REVOKE ALL ON DATABASE %I FROM PUBLIC', current_database());
  EXECUTE format('GRANT CONNECT ON DATABASE %I TO core_rw, pub_ro, backup_ro', current_database());
END
$$;

-- The record of which migrations have been applied. Every migration adds its
-- own row first, so a second run fails on the primary key before it can change
-- anything.
CREATE TABLE core.migration (
  version    integer     PRIMARY KEY,
  name       text        NOT NULL,
  applied_at timestamptz NOT NULL DEFAULT transaction_timestamp()
);

INSERT INTO core.migration (version, name) VALUES (1, 'roles_and_schemas');

GRANT SELECT ON core.migration TO core_rw, backup_ro;

COMMIT;
