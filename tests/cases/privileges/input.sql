-- What each role may do to each table and view. Any change to a grant changes
-- this output.

\echo == rights on every table and view
SELECT n.nspname || '.' || c.relname AS relation,
       CASE c.relkind WHEN 'r' THEN 'table' WHEN 'v' THEN 'view' ELSE c.relkind::text END AS kind,
       coalesce(string_agg(p.name, ' ' ORDER BY p.ord) FILTER (WHERE has_table_privilege('core_rw', c.oid, p.name)), '-') AS core_rw,
       coalesce(string_agg(p.name, ' ' ORDER BY p.ord) FILTER (WHERE has_table_privilege('pub_ro', c.oid, p.name)), '-') AS pub_ro,
       coalesce(string_agg(p.name, ' ' ORDER BY p.ord) FILTER (WHERE has_table_privilege('backup_ro', c.oid, p.name)), '-') AS backup_ro,
       coalesce(string_agg(p.name, ' ' ORDER BY p.ord) FILTER (WHERE has_table_privilege('public', c.oid, p.name)), '-') AS anyone
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
CROSS JOIN (VALUES (1, 'SELECT'), (2, 'INSERT'), (3, 'UPDATE'), (4, 'DELETE'),
                   (5, 'TRUNCATE'), (6, 'REFERENCES'), (7, 'TRIGGER')) AS p (ord, name)
WHERE n.nspname IN ('core', 'pub', 'public') AND c.relkind NOT IN ('i', 'S')
GROUP BY n.nspname, c.relname, c.relkind
ORDER BY n.nspname, c.relname;

\echo == rights on every schema
SELECT s.name AS schema,
       coalesce(string_agg(p.name, ' ' ORDER BY p.ord) FILTER (WHERE has_schema_privilege('core_rw', s.name, p.name)), '-') AS core_rw,
       coalesce(string_agg(p.name, ' ' ORDER BY p.ord) FILTER (WHERE has_schema_privilege('pub_ro', s.name, p.name)), '-') AS pub_ro,
       coalesce(string_agg(p.name, ' ' ORDER BY p.ord) FILTER (WHERE has_schema_privilege('backup_ro', s.name, p.name)), '-') AS backup_ro,
       coalesce(string_agg(p.name, ' ' ORDER BY p.ord) FILTER (WHERE has_schema_privilege('public', s.name, p.name)), '-') AS anyone
FROM (VALUES ('core'), ('pub'), ('public')) AS s (name)
CROSS JOIN (VALUES (1, 'USAGE'), (2, 'CREATE')) AS p (ord, name)
GROUP BY s.name
ORDER BY s.name;

\echo == rights on the database
SELECT r.name AS role,
       coalesce(string_agg(p.name, ' ' ORDER BY p.ord) FILTER (WHERE has_database_privilege(r.name, current_database(), p.name)), '-') AS may
FROM (VALUES (1, 'core_rw'), (2, 'pub_ro'), (3, 'backup_ro'), (4, 'public')) AS r (ord, name)
CROSS JOIN (VALUES (1, 'CONNECT'), (2, 'CREATE'), (3, 'TEMPORARY')) AS p (ord, name)
GROUP BY r.ord, r.name
ORDER BY r.ord;

\echo == who may call each function in core
SELECT p.proname AS function,
       has_function_privilege('core_rw', p.oid, 'EXECUTE') AS core_rw,
       has_function_privilege('pub_ro', p.oid, 'EXECUTE') AS pub_ro,
       has_function_privilege('backup_ro', p.oid, 'EXECUTE') AS backup_ro,
       has_function_privilege('public', p.oid, 'EXECUTE') AS anyone
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname IN ('core', 'pub')
ORDER BY p.proname;

\echo == the roles themselves
SELECT rolname AS role, rolcanlogin AS login, rolsuper AS superuser, rolcreatedb AS createdb,
       rolcreaterole AS createrole, rolreplication AS replication, rolbypassrls AS bypassrls,
       rolpassword IS NOT NULL AS has_password
FROM pg_authid
WHERE rolname IN ('core_rw', 'pub_ro', 'backup_ro')
ORDER BY rolname;

\echo == everything in pub is a view with a security barrier
SELECT c.relname AS relation, c.relkind = 'v' AS is_view,
       coalesce(c.reloptions @> ARRAY['security_barrier=true'], false) AS security_barrier
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'pub'
ORDER BY c.relname;
