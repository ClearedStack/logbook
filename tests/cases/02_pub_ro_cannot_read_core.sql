-- The read-only role cannot read any working table.
-- 42501 is PostgreSQL's "insufficient privilege".
\echo == the role, and that it is not a superuser and cannot log in
SELECT rolname, rolsuper, rolcanlogin, rolcreaterole, rolcreatedb, rolbypassrls
FROM pg_roles WHERE rolname = 'pub_ro';

\echo == roles pub_ro is a member of (there must be none)
SELECT r.rolname FROM pg_auth_members m JOIN pg_roles r ON r.oid = m.roleid
WHERE m.member = 'pub_ro'::regrole ORDER BY 1;

\echo == pub_ro on schema core: usage, create
SELECT has_schema_privilege('pub_ro', 'core', 'USAGE'),
       has_schema_privilege('pub_ro', 'core', 'CREATE');

\echo == core tables on which pub_ro holds any privilege at all (there must be none)
SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'core' AND c.relkind IN ('r', 'p', 'v', 'm', 'S', 'f')
  AND (has_table_privilege('pub_ro', c.oid, 'SELECT')
    OR has_table_privilege('pub_ro', c.oid, 'INSERT')
    OR has_table_privilege('pub_ro', c.oid, 'UPDATE')
    OR has_table_privilege('pub_ro', c.oid, 'DELETE')
    OR has_table_privilege('pub_ro', c.oid, 'TRUNCATE')
    OR has_table_privilege('pub_ro', c.oid, 'REFERENCES')
    OR has_table_privilege('pub_ro', c.oid, 'TRIGGER')
    OR has_any_column_privilege('pub_ro', c.oid, 'SELECT'))
ORDER BY 1;

\echo == acting as pub_ro: every read of a working table is refused
SET ROLE pub_ro;
SELECT current_user;
SELECT * FROM core.item;
SELECT * FROM core.evaluation;
SELECT * FROM core.decision;
SELECT * FROM core.queue_lease;
SELECT * FROM core.edit_proposal;
SELECT * FROM core.ledger;
SELECT * FROM core.restore_drill;
SELECT * FROM core.restore_drill_check;
SELECT * FROM core.migration;
SELECT count(*) FROM core.item;
SELECT lease_token FROM core.queue_lease;
TABLE core.item;
COPY core.item TO STDOUT;
