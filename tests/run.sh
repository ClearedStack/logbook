#!/bin/sh
# Run the Logbook tests against a PostgreSQL server.
#
# Connection comes from the usual PostgreSQL environment variables; the user
# must be allowed to create a database and a role. A scratch database is
# created, migrated, seeded with tests/fixtures/seed.sql, checked and dropped.
#
# Each tests/cases/NAME.sql is run and its output compared, byte for byte,
# with tests/expected/NAME.out. Errors are printed as SQLSTATE codes so the
# output is the same on every machine.
#
#   tests/run.sh            run and compare
#   tests/run.sh --record   run and overwrite tests/expected (review the diff)
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(dirname -- "$here")
record=no
[ "${1:-}" = --record ] && record=yes

db="logbook_test_$$"
out=$(mktemp -d)
export PGOPTIONS="-c timezone=UTC -c datestyle=ISO -c client_min_messages=warning"
export PGCLIENTENCODING=UTF8

psql -X -q -v ON_ERROR_STOP=1 -d postgres -c "CREATE DATABASE $db"
cleanup() {
    psql -X -q -d postgres -c "DROP DATABASE IF EXISTS $db" || true
    rm -rf "$out"
}
trap cleanup EXIT
export PGDATABASE="$db"

failed=0
check() { # name, actual-file
    if [ "$record" = yes ]; then
        cp "$2" "$here/expected/$1.out"; echo "recorded $1"
    elif diff -u "$here/expected/$1.out" "$2"; then
        echo "ok   $1"
    else
        echo "FAIL $1"; failed=$((failed + 1))
    fi
}

echo "server: $(psql -X -q -A -t -c 'SHOW server_version')"

# Migrating an empty database applies every file; migrating again applies none.
"$root/bin/migrate" > "$out/00_migrate_first.txt" 2>&1
check 00_migrate_first "$out/00_migrate_first.txt"
"$root/bin/migrate" > "$out/00_migrate_again.txt" 2>&1
check 00_migrate_again "$out/00_migrate_again.txt"

psql -X -q -v ON_ERROR_STOP=1 -f "$here/fixtures/seed.sql"

for case in "$here"/cases/*.sql; do
    name=$(basename -- "$case" .sql)
    # Each case runs in its own session and must leave the data as it found it.
    psql -X -q -A -F ' | ' -P footer=off -v VERBOSITY=sqlstate \
        -f "$case" > "$out/$name.txt" 2>&1 || true
    # psql prefixes errors with the script path; keep only the file name.
    sed "s#psql:$here/cases/#psql:#" "$out/$name.txt" > "$out/$name.clean"
    check "$name" "$out/$name.clean"
done

if [ "$failed" -ne 0 ]; then
    echo "$failed test(s) failed"; exit 1
fi
[ "$record" = yes ] && echo "expected output recorded" || echo "all tests passed"
