\i fixtures/sample_record.sql
\set ECHO all
-- Rule: Conn reads Logbook as pub_ro, and pub_ro can read the public views and
-- nothing else. It cannot read a working table, write anywhere, or become
-- another role.

SET SESSION AUTHORIZATION pub_ro;
SELECT current_user;

-- It can read a public view.
SELECT count(*) AS items FROM pub.item;

-- It cannot read any working table.
SELECT count(*) FROM core.item;
SELECT count(*) FROM core.evaluation;
SELECT count(*) FROM core.decision;
SELECT count(*) FROM core.edit_proposal;
SELECT count(*) FROM core.queue;
SELECT count(*) FROM core.pause;
SELECT count(*) FROM core.ledger;
SELECT count(*) FROM core.restore_drill;
SELECT count(*) FROM core.migration;

-- Not one column of one, either.
SELECT lease_token FROM core.queue;
SELECT payload FROM core.edit_proposal;
SELECT address FROM core.item;

-- It cannot call a function in core or take a number from the item sequence.
SELECT core.item_states();
SELECT * FROM core.integrity_check();
SELECT nextval('core.item_number');

-- It cannot write through a public view.
INSERT INTO pub.item (item_id, state, title) VALUES ('PA-9000', 'live', 'Not allowed');
UPDATE pub.edit_proposal SET status = 'approved';
DELETE FROM pub.item_history;

-- It cannot make anything of its own, or become Muster.
CREATE TABLE pub.scratch (note text);
CREATE TEMPORARY TABLE scratch (note text);
CREATE SCHEMA scratch;
SET ROLE muster;

RESET SESSION AUTHORIZATION;

-- The same thing asked of the catalog, so that a table or function added
-- later is covered without anyone remembering to add it here.

-- Working tables of which pub_ro can read, write or reference even one column: none.
SELECT c.relname
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'core' AND c.relkind IN ('r', 'p', 'v', 'm')
  AND (has_any_column_privilege('pub_ro', c.oid, 'SELECT, INSERT, UPDATE, REFERENCES')
       OR has_table_privilege('pub_ro', c.oid, 'DELETE, TRUNCATE, TRIGGER'))
ORDER BY 1;

-- Functions in core that pub_ro can call: none.
SELECT p.oid::regprocedure
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'core' AND has_function_privilege('pub_ro', p.oid, 'EXECUTE')
ORDER BY 1;

-- Sequences pub_ro can use: none.
SELECT c.relname
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname IN ('core', 'pub', 'public')
  AND CASE WHEN c.relkind = 'S' THEN has_sequence_privilege('pub_ro', c.oid, 'USAGE, SELECT, UPDATE') END
ORDER BY 1;

-- Public views pub_ro cannot read: none. Public views it can write: none.
SELECT c.relname AS unreadable
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'pub' AND NOT has_table_privilege('pub_ro', c.oid, 'SELECT')
ORDER BY 1;
SELECT c.relname AS writable
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'pub'
  AND (has_any_column_privilege('pub_ro', c.oid, 'INSERT, UPDATE, REFERENCES')
       OR has_table_privilege('pub_ro', c.oid, 'DELETE, TRUNCATE, TRIGGER'))
ORDER BY 1;

-- Everything in pub is a view. There is no table there to hold a private row.
SELECT c.relkind, count(*) FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'pub' GROUP BY 1 ORDER BY 1;

-- What pub_ro holds on the schemas and on the database.
SELECT has_schema_privilege('pub_ro', 'pub', 'USAGE')     AS use_pub,
       has_schema_privilege('pub_ro', 'pub', 'CREATE')    AS create_in_pub,
       has_schema_privilege('pub_ro', 'core', 'USAGE')    AS use_core,
       has_schema_privilege('pub_ro', 'core', 'CREATE')   AS create_in_core,
       has_schema_privilege('pub_ro', 'public', 'USAGE')  AS use_public,
       has_schema_privilege('pub_ro', 'public', 'CREATE') AS create_in_public;
SELECT has_database_privilege('pub_ro', current_database(), 'CONNECT')   AS connect,
       has_database_privilege('pub_ro', current_database(), 'CREATE')    AS create_schema,
       has_database_privilege('pub_ro', current_database(), 'TEMPORARY') AS temporary_tables;

-- The role itself: no powers, no memberships, and no way to log in until the
-- deployment gives it a password.
SELECT rolname, rolcanlogin, rolsuper, rolcreatedb, rolcreaterole, rolinherit, rolreplication, rolbypassrls,
       rolpassword IS NULL AS no_password,
       (SELECT count(*) FROM pg_auth_members m WHERE m.member = a.oid) AS member_of
FROM pg_authid a
WHERE rolname IN ('muster', 'pub_ro')
ORDER BY 1;
