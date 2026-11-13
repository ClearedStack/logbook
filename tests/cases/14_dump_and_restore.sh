# Rule: a consistent dump of Logbook, restored into a new database, passes the
# integrity checks and keeps the fence between the two roles. This is the
# database part of the monthly restore drill, without the encryption and the
# off-node storage, which are not Logbook's.
#
# Run by tests/run.sh in a new, empty database. LOGBOOK_ROOT is the repository
# and LOGBOOK_TEST_TMP is a directory this case may write in.

ask() {
    psql -X -q -A -t -c "$1"
}

sh "$LOGBOOK_ROOT/migrate.sh" >/dev/null
psql -X -q -f "$LOGBOOK_ROOT/tests/fixtures/sample_record.sql"

printf '== The dump is taken at a single moment, and loads into a new database without an error.\n'
pg_dump --serializable-deferrable >"$LOGBOOK_TEST_TMP/logbook.dump.sql"
printf 'pg_dump exit status %s\n' "$?"
psql -X -q -c 'CREATE DATABASE logbook_test_14_restored'
PGDATABASE=logbook_test_14_restored psql -X -q -v ON_ERROR_STOP=1 -f "$LOGBOOK_TEST_TMP/logbook.dump.sql" >/dev/null
printf 'restore exit status %s\n' "$?"

PGDATABASE=logbook_test_14_restored
export PGDATABASE

printf '\n== The restored copy passes every integrity check.\n'
ask "SELECT count(*) || ' checks, ' || sum(failures) || ' failures' FROM core.integrity_check()"

printf '\n== It holds the same rows as the original.\n'
ask "SELECT 'items ' || (SELECT count(*) FROM core.item)
         || ', evaluations ' || (SELECT count(*) FROM core.evaluation)
         || ', decisions ' || (SELECT count(*) FROM core.decision)
         || ', proposals ' || (SELECT count(*) FROM core.edit_proposal)
         || ', queued ' || (SELECT count(*) FROM core.queue)
         || ', pauses ' || (SELECT count(*) FROM core.pause)
         || ', ledger entries ' || (SELECT count(*) FROM core.ledger)
         || ', drills ' || (SELECT count(*) FROM core.restore_drill)
         || ', migrations ' || (SELECT count(*) FROM core.migration)"

printf '\n== The next item continues the numbering.\n'
ask "INSERT INTO core.item (state, title) VALUES ('discovered', 'Sample item after the restore') RETURNING item_id"

printf '\n== The default that gives out identifiers came back, with its sequence and its limit.\n'
ask "SELECT 'default: ' || pg_get_expr(d.adbin, d.adrelid)
     FROM pg_attrdef d JOIN pg_attribute a ON a.attrelid = d.adrelid AND a.attnum = d.adnum
     WHERE d.adrelid = 'core.item'::regclass AND a.attname = 'item_id'"
ask "SELECT 'numbers run to: ' || seqmax FROM pg_sequence WHERE seqrelid = 'core.item_number'::regclass"
ask "SELECT 'next number set after: ' || setval('core.item_number', 9999)"
psql -X -q -A -t -v VERBOSITY=terse \
    -c 'SET SESSION AUTHORIZATION muster' \
    -c "INSERT INTO core.item (state, title) VALUES ('discovered', 'Sample item past the old limit') RETURNING item_id" \
    -c "INSERT INTO core.item (item_id, state, title) VALUES ('PA-20000', 'discovered', 'Sample')" 2>&1

printf '\n== The checks on writing came back with it.\n'
psql -X -q -v VERBOSITY=terse -c "INSERT INTO core.item (state, title) VALUES ('archived', 'Sample')" 2>&1
psql -X -q -v VERBOSITY=terse -c "DELETE FROM core.ledger WHERE entry_id = 1" 2>&1

printf '\n== pub_ro still reads the public views and nothing else.\n'
psql -X -q -A -t -v VERBOSITY=terse \
    -c 'SET SESSION AUTHORIZATION pub_ro' \
    -c 'SELECT count(*) FROM pub.item' \
    -c 'SELECT count(*) FROM core.item' 2>&1
ask "SELECT 'working tables pub_ro can touch: ' || count(*)
     FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'core' AND c.relkind IN ('r', 'p', 'v', 'm')
       AND (has_any_column_privilege('pub_ro', c.oid, 'SELECT, INSERT, UPDATE, REFERENCES')
            OR has_table_privilege('pub_ro', c.oid, 'DELETE, TRUNCATE, TRIGGER'))"
ask "SELECT 'functions in core pub_ro can call: ' || count(*)
     FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'core' AND has_function_privilege('pub_ro', p.oid, 'EXECUTE')"
ask "SELECT 'public views pub_ro cannot read: ' || count(*)
     FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'pub' AND NOT has_table_privilege('pub_ro', c.oid, 'SELECT')"

printf '\n== Muster still cannot change the ledger or read the public views.\n'
psql -X -q -A -t -v VERBOSITY=terse \
    -c 'SET SESSION AUTHORIZATION muster' \
    -c "UPDATE core.ledger SET note = 'Rewritten.' WHERE entry_id = 1" \
    -c 'SELECT count(*) FROM pub.item' 2>&1

printf '\n== What a dump of one database does not carry: who may connect to it.\n'
printf '== Whoever restores Logbook for real must apply this again. The migrations do it for a new database.\n'
ask "SELECT 'anyone may connect to the restored copy: ' || has_database_privilege('public', current_database(), 'CONNECT')"
ask "SELECT 'pub_ro may create temporary tables in it: ' || has_database_privilege('pub_ro', current_database(), 'TEMPORARY')"

PGDATABASE=postgres psql -X -q -c 'DROP DATABASE logbook_test_14_restored'
