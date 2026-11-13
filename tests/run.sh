#!/bin/sh
# Runs every saved example against a throwaway PostgreSQL 17 server.
#
#   sh tests/run.sh
#
# It starts a private server in a temporary directory, reachable only through
# a socket in that directory, and removes it afterwards. For every directory
# under tests/cases it makes a new database, applies the migrations, feeds
# input.sql to psql and compares what comes out with expected.out, byte for
# byte. Then it runs a few checks that need more than one connection.
#
# Exit status: 0 when everything passed, 1 when a test failed, 2 when the run
# could not be made at all.
#
# Set PG_BINDIR if the PostgreSQL 17 programs are not on PATH.

set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo=$(dirname -- "$here")

stop() {
  printf 'run.sh: %s\n' "$1" >&2
  exit 2
}

[ "$(id -u)" -ne 0 ] || stop 'refusing to run as root; run as an ordinary user'

if [ -n "${PG_BINDIR:-}" ]; then
  PATH="$PG_BINDIR:$PATH"
fi
for tool in postgres initdb pg_ctl psql createdb dropdb pg_dump; do
  command -v "$tool" >/dev/null 2>&1 ||
    stop "$tool not found; set PG_BINDIR to the PostgreSQL 17 bin directory"
done
case "$(postgres --version)" in
  *' 17.'*) ;;
  *) stop 'PostgreSQL 17 is required' ;;
esac

work=$(mktemp -d "${TMPDIR:-/tmp}/logbook.XXXXXX")
cleanup() {
  pg_ctl -D "$work/data" -m immediate -w stop >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 2' INT TERM

unset PGPORT PGPASSWORD PGSERVICE PGOPTIONS PGAPPNAME PGCLIENTENCODING
export PGHOST="$work" PGUSER=postgres PGDATABASE=postgres PGTZ=UTC

initdb -D "$work/data" -U postgres --auth=trust --locale=C --encoding=UTF8 >/dev/null
pg_ctl -D "$work/data" -w -l "$work/server.log" \
  -o "-c listen_addresses='' -c unix_socket_directories='$work' -c fsync=off" \
  start >/dev/null ||
  stop 'the test server did not start'

failures=0

pass() {
  printf 'ok    %s\n' "$1"
}

fail() {
  printf 'FAIL  %s\n' "$1"
  failures=$((failures + 1))
}

# Makes a database and applies every migration to it, in order.
fresh_database() {
  createdb "$1"
  for migration in "$repo"/migrations/*.sql; do
    psql -X -q -v ON_ERROR_STOP=1 -d "$1" -f "$migration" >/dev/null ||
      stop "could not apply $(basename "$migration")"
  done
}

# --- The saved examples -----------------------------------------------------

for dir in "$here"/cases/*/; do
  name=$(basename "$dir")
  [ -f "$dir/input.sql" ] || stop "tests/cases/$name has no input.sql"
  [ -f "$dir/expected.out" ] || stop "tests/cases/$name has no expected.out"
  fresh_database "case_$name"
  psql -X -q -v SHOW_CONTEXT=never -d "case_$name" \
    <"$dir/input.sql" >"$work/$name.out" 2>&1 || true
  if diff -u "$dir/expected.out" "$work/$name.out"; then
    pass "case $name"
  else
    fail "case $name"
  fi
  dropdb "case_$name"
done

# --- Every rule has a saved example -----------------------------------------

# Each rule is one line in a migration. Its message must turn up, as an error,
# in the expected output of at least one case.
sed -n \
  -e "s/.*core\.refuse_parse('\([^']*\)').*/E_PARSE: \1/p" \
  -e "s/.*core\.refuse_unfamiliar('\([^']*\)').*/E_NEEDS_SUBTOOL: \1/p" \
  "$repo"/migrations/*.sql >"$work/rules"
[ -s "$work/rules" ] || stop 'found no rules in the migrations'
missing=0
while IFS= read -r rule; do
  if ! cat "$here"/cases/*/expected.out | grep -qxF "ERROR:  $rule"; then
    printf '      no saved example for: %s\n' "$rule"
    missing=$((missing + 1))
  fi
done <"$work/rules"
if [ "$missing" -eq 0 ]; then
  pass "every rule has a saved example ($(wc -l <"$work/rules" | tr -d ' ') rules)"
else
  fail 'every rule has a saved example'
fi

# --- A migration cannot be applied twice ------------------------------------

fresh_database check_twice
psql -X -q -At -d check_twice -c '\d core.*' -c '\d pub.*' >"$work/before" 2>&1
twice=0
for migration in "$repo"/migrations/*.sql; do
  if psql -X -q -v ON_ERROR_STOP=1 -d check_twice -f "$migration" >/dev/null 2>&1; then
    twice=1
  fi
done
psql -X -q -At -d check_twice -c '\d core.*' -c '\d pub.*' >"$work/after" 2>&1
applied=$(psql -X -q -At -d check_twice -c 'SELECT count(*) FROM core.migration')
count=$(ls "$repo"/migrations/*.sql | wc -l | tr -d ' ')
if [ "$twice" -eq 0 ] && [ "$applied" = "$count" ] && cmp -s "$work/before" "$work/after"; then
  pass 'a second run of each migration is refused and changes nothing'
else
  fail 'a second run of each migration is refused and changes nothing'
fi
dropdb check_twice

# --- An unexpected role stops the first migration ---------------------------

createdb check_role
psql -X -q -c 'ALTER ROLE pub_ro LOGIN'
if psql -X -q -v ON_ERROR_STOP=1 -d check_role \
  -f "$repo/migrations/0001_roles_and_schemas.sql" >"$work/role.out" 2>&1; then
  fail 'a role that can log in stops the first migration'
elif grep -q 'role pub_ro already exists and can log in or has elevated attributes' "$work/role.out" &&
  [ "$(psql -X -q -At -d check_role -c "SELECT count(*) FROM pg_namespace WHERE nspname IN ('core', 'pub')")" = 0 ]; then
  pass 'a role that can log in stops the first migration'
else
  fail 'a role that can log in stops the first migration'
fi
psql -X -q -c 'ALTER ROLE pub_ro NOLOGIN'
dropdb check_role

# --- The backup role can take a dump, the public role cannot ----------------

fresh_database check_dump
psql -X -q -c 'CREATE ROLE example_backup LOGIN IN ROLE backup_ro' \
  -c 'CREATE ROLE example_conn LOGIN IN ROLE pub_ro'
if pg_dump -U example_backup -d check_dump >"$work/dump.sql" 2>"$work/dump.err" &&
  grep -q 'CREATE TABLE core.ledger' "$work/dump.sql"; then
  pass 'a member of backup_ro can dump the database'
else
  fail 'a member of backup_ro can dump the database'
fi
if pg_dump -U example_conn -d check_dump >/dev/null 2>&1; then
  fail 'a member of pub_ro cannot dump the database'
else
  pass 'a member of pub_ro cannot dump the database'
fi
dropdb check_dump

# ---------------------------------------------------------------------------

if [ "$failures" -ne 0 ]; then
  printf '\n%s failed\n' "$failures"
  exit 1
fi
printf '\nall passed\n'
