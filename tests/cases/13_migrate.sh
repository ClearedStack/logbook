# Rules for migrate.sh: it applies each migration once, in order, and refuses
# to go on when what it finds is not what it expects.
#
# Run by tests/run.sh in a new, empty database. LOGBOOK_ROOT is the repository
# and LOGBOOK_TEST_TMP is a directory this case may write in.

migrate="$LOGBOOK_ROOT/migrate.sh"
copy="$LOGBOOK_TEST_TMP/migrations-copy"
rm -rf "$copy"
mkdir "$copy"
cp "$LOGBOOK_ROOT"/migrations/*.sql "$copy"/

run() {
    printf '\n== %s\n' "$1"
    shift
    "$@"
    printf 'exit status %s\n' "$?"
}

ask() {
    psql -X -q -A -t -c "$1"
}

run 'A new database: every migration is applied, in order.' \
    sh "$migrate"

run 'Run again: there is nothing to apply.' \
    sh "$migrate"

printf '\n== What the database remembers: each version, and that it holds a checksum.\n'
ask "SELECT version || '  ' || (checksum ~ '^[0-9a-f]{64}\$') FROM core.migration ORDER BY version"

printf '\n== The recorded checksum of the first migration is the SHA-256 of its file.\n'
recorded=$(ask "SELECT checksum FROM core.migration WHERE version = '0001_schemas_and_roles'")
actual=$(sha256sum "$LOGBOOK_ROOT/migrations/0001_schemas_and_roles.sql" | cut -d' ' -f1)
[ "$recorded" = "$actual" ] && printf 'same\n' || printf 'different\n'

export LOGBOOK_MIGRATIONS="$copy"

# A made-up later migration, to show one being added.
cat >"$copy/0900_sample_addition.sql" <<'SQL'
CREATE TABLE core.sample_addition (note text);
SQL
run 'A later migration is added: only that one is applied.' \
    sh "$migrate"

printf '\n' >>"$copy/0003_working_tables.sql"
run 'An applied migration has changed, if only by one blank line: refused.' \
    sh "$migrate"
cp "$LOGBOOK_ROOT/migrations/0003_working_tables.sql" "$copy/0003_working_tables.sql"

rm "$copy/0900_sample_addition.sql"
run 'An applied migration is missing from this copy: refused.' \
    sh "$migrate"
cat >"$copy/0900_sample_addition.sql" <<'SQL'
CREATE TABLE core.sample_addition (note text);
SQL

cat >"$copy/0800_sample_latecomer.sql" <<'SQL'
CREATE TABLE core.sample_latecomer (note text);
SQL
run 'A migration turns up that sorts before one already applied: refused.' \
    sh "$migrate"
rm "$copy/0800_sample_latecomer.sql"

cat >"$copy/notes.txt" <<'TXT'
Not a migration.
TXT
run 'A file that is not named like a migration: refused.' \
    sh "$migrate"
rm "$copy/notes.txt"

cat >"$copy/0901_Sample-Name.sql" <<'SQL'
SELECT 1;
SQL
run 'A migration with a badly formed name: refused.' \
    sh "$migrate"
rm "$copy/0901_Sample-Name.sql"

cat >"$copy/0901_sample_half_done.sql" <<'SQL'
CREATE TABLE core.sample_half_done (note text);
INSERT INTO core.sample_half_done VALUES ('kept only if the whole migration is');
SELECT 1 / 0;
SQL
run 'A migration that fails part-way: refused, and nothing from it is kept.' \
    sh "$migrate"
printf 'table from the failed migration exists: %s\n' "$(ask "SELECT to_regclass('core.sample_half_done') IS NOT NULL")"
printf 'failed migration is recorded: %s\n' "$(ask "SELECT count(*) > 0 FROM core.migration WHERE version = '0901_sample_half_done'")"
rm "$copy/0901_sample_half_done.sql"

run 'With the bad files gone, there is nothing to apply.' \
    sh "$migrate"

run 'An empty migrations directory: refused.' \
    env LOGBOOK_MIGRATIONS="$LOGBOOK_TEST_TMP/empty-directory" sh -c 'mkdir -p "$LOGBOOK_MIGRATIONS" && sh "$0"' "$migrate"

run 'A migrations directory that is not there: refused.' \
    env LOGBOOK_MIGRATIONS="$LOGBOOK_TEST_TMP/no-such-directory" sh "$migrate"

run 'The database does not answer: refused, without naming where it was looked for.' \
    env PGHOST="$LOGBOOK_TEST_TMP/no-such-directory" PGCONNECT_TIMEOUT=2 sh "$migrate"

# A stand-in for psql that reports another version of PostgreSQL.
mkdir -p "$LOGBOOK_TEST_TMP/other-version"
cat >"$LOGBOOK_TEST_TMP/other-version/psql" <<'SH'
#!/bin/sh
echo 16
SH
chmod +x "$LOGBOOK_TEST_TMP/other-version/psql"
run 'The server is not PostgreSQL 17: refused.' \
    env PATH="$LOGBOOK_TEST_TMP/other-version:$PATH" sh "$migrate"

# A role of Logbook's that already exists with more power than Logbook gives it.
unset LOGBOOK_MIGRATIONS
psql -X -q -c 'CREATE DATABASE logbook_test_13_second' -c 'ALTER ROLE pub_ro CREATEDB'
run 'pub_ro already exists and may create databases: refused, and nothing is applied.' \
    env PGDATABASE=logbook_test_13_second sh "$migrate"
printf 'schema core exists in that database: %s\n' \
    "$(PGDATABASE=logbook_test_13_second ask "SELECT to_regnamespace('core') IS NOT NULL")"
psql -X -q -c 'ALTER ROLE pub_ro NOCREATEDB' -c 'GRANT muster TO pub_ro'
run 'pub_ro already exists and has been made a member of muster: refused.' \
    env PGDATABASE=logbook_test_13_second sh "$migrate"
psql -X -q -c 'REVOKE muster FROM pub_ro'
run 'With pub_ro as Logbook expects it, the same database is migrated.' \
    env PGDATABASE=logbook_test_13_second sh "$migrate"
psql -X -q -c 'DROP DATABASE logbook_test_13_second'
