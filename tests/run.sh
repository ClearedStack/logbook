#!/bin/sh
# Runs every saved example in tests/cases and compares what it prints with the
# file of the same name in tests/expected. Any difference is a failure.
#
#   sh tests/run.sh            run every case
#   sh tests/run.sh --accept   run every case and save what it prints as expected
#
# It starts its own PostgreSQL 17 server in a temporary directory, reachable
# only through a socket in that directory, and removes it afterwards. It needs
# initdb, pg_ctl, psql, createdb and pg_dump from PostgreSQL 17 on the PATH, and has to
# be run as an ordinary user: PostgreSQL will not start as root. Apart from
# --accept, it writes only under the temporary directory.
#
# A case ending in .sql is run with psql in a new database that already has
# every migration applied. A case ending in .sh is run with sh in a new, empty
# database, and is told where things are through the environment.

set -eu
LC_ALL=C
export LC_ALL

accept=no
case "${1:-}" in
    '') ;;
    --accept) accept=yes ;;
    *) printf 'usage: sh tests/run.sh [--accept]\n' >&2; exit 2 ;;
esac

here=$(cd "$(dirname "$0")" && pwd)
root=$(dirname "$here")

for tool in initdb pg_ctl psql createdb dropdb pg_dump sha256sum; do
    command -v "$tool" >/dev/null 2>&1 || {
        printf 'tests cannot run: %s is not on the PATH\n' "$tool" >&2
        exit 2
    }
done
[ "$(id -u)" != 0 ] || {
    printf 'tests cannot run as root: PostgreSQL will not start as root\n' >&2
    exit 2
}

work=$(mktemp -d "${TMPDIR:-/tmp}/logbook-test.XXXXXX")
stop() {
    pg_ctl -D "$work/data" -m immediate -w stop >/dev/null 2>&1 || true
    rm -rf "$work"
}
trap stop EXIT
trap 'exit 1' INT TERM

initdb -D "$work/data" -U postgres -A trust -E UTF8 --locale=C --wal-segsize=1 >"$work/initdb.log" 2>&1 || {
    cat "$work/initdb.log" >&2
    exit 2
}
cat >>"$work/data/postgresql.conf" <<CONF
listen_addresses = ''
unix_socket_directories = '$work'
max_connections = 10
shared_buffers = 16MB
fsync = off
synchronous_commit = off
full_page_writes = off
min_wal_size = 4MB
max_wal_size = 32MB
CONF
pg_ctl -D "$work/data" -l "$work/server.log" -w start >/dev/null 2>&1 || {
    cat "$work/server.log" >&2
    exit 2
}

PGHOST=$work
PGUSER=postgres
PGTZ=UTC
PGDATESTYLE='ISO, YMD'
export PGHOST PGUSER PGTZ PGDATESTYLE
LOGBOOK_ROOT=$root
LOGBOOK_TEST_TMP=$work
export LOGBOOK_ROOT LOGBOOK_TEST_TMP

failed=0
ran=0
cd "$here"
for case_file in cases/*.sql cases/*.sh; do
    [ -f "$case_file" ] || continue
    name=$(basename "$case_file")
    name=${name%.*}
    PGDATABASE=logbook_test_$name
    export PGDATABASE
    createdb "$PGDATABASE"

    case "$case_file" in
        *.sql)
            if sh "$root/migrate.sh" >"$work/migrate.log" 2>&1; then
                psql -X -q -v VERBOSITY=terse -P pager=off <"$case_file" >"$work/actual" 2>&1 || true
            else
                cp "$work/migrate.log" "$work/actual"
            fi
            ;;
        *.sh)
            sh "$case_file" >"$work/actual" 2>&1 || true
            ;;
    esac
    dropdb "$PGDATABASE"

    ran=$((ran + 1))
    if [ "$accept" = yes ]; then
        cp "$work/actual" "expected/$name.out"
        printf 'saved   %s\n' "$name"
    elif [ -f "expected/$name.out" ] && diff -u "expected/$name.out" "$work/actual" >"$work/diff"; then
        printf 'ok      %s\n' "$name"
    else
        failed=$((failed + 1))
        printf 'FAILED  %s\n' "$name"
        if [ -f "expected/$name.out" ]; then
            cat "$work/diff"
        else
            printf 'there is no expected/%s.out\n' "$name"
        fi
    fi
done

for expected_file in expected/*.out; do
    [ -f "$expected_file" ] || continue
    name=$(basename "$expected_file" .out)
    if [ ! -f "cases/$name.sql" ] && [ ! -f "cases/$name.sh" ]; then
        failed=$((failed + 1))
        printf 'FAILED  %s\nexpected/%s.out has no case\n' "$name" "$name"
    fi
done

if [ "$ran" = 0 ]; then
    printf 'no cases were found\n' >&2
    exit 2
fi
if [ "$failed" -gt 0 ]; then
    printf '%s of %s cases failed\n' "$failed" "$ran"
    exit 1
fi
[ "$accept" = yes ] || printf 'all %s cases passed\n' "$ran"
