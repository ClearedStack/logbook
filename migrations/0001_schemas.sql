-- Logbook migration 0001: the two schemas and the migration record.
--
-- core: working records. Nothing outside the owner may read or write it
--       until a later migration grants Muster its access.
-- pub:  sanitised public views of the working records, for Conn.

CREATE SCHEMA core;
CREATE SCHEMA pub;

-- Nobody gets into either schema by default.
REVOKE ALL ON SCHEMA core FROM PUBLIC;
REVOKE ALL ON SCHEMA pub FROM PUBLIC;

-- One row per applied migration file. bin/migrate writes it and refuses to
-- continue if a file that was already applied has since changed.
CREATE TABLE core.migration (
    filename   text        PRIMARY KEY CHECK (filename ~ '^[0-9]{4}_[a-z0-9_]+\.sql$'),
    sha256     text        NOT NULL CHECK (sha256 ~ '^[0-9a-f]{64}$'),
    applied_at timestamptz NOT NULL DEFAULT now()
);
