-- What exists: the tables in core, the views in pub and each view's columns.
-- Adding, removing or renaming any of them changes this output.
\echo == tables in core
SELECT table_name FROM information_schema.tables
WHERE table_schema = 'core' AND table_type = 'BASE TABLE' ORDER BY 1;

\echo == base tables in pub (there must be none)
SELECT table_name FROM information_schema.tables
WHERE table_schema = 'pub' AND table_type = 'BASE TABLE' ORDER BY 1;

\echo == views in pub and their columns
SELECT table_name, string_agg(column_name, ',' ORDER BY ordinal_position)
FROM information_schema.columns WHERE table_schema = 'pub'
GROUP BY table_name ORDER BY 1;

\echo == views in core (there must be none)
SELECT table_name FROM information_schema.views WHERE table_schema = 'core' ORDER BY 1;

\echo == pub views that are not security_barrier (there must be none)
SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'pub' AND c.relkind = 'v'
  AND NOT coalesce(c.reloptions @> ARRAY['security_barrier=true'], false)
ORDER BY 1;

\echo == migrations recorded
SELECT filename FROM core.migration ORDER BY 1;
