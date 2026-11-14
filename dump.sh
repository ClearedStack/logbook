#!/bin/sh
# Takes a consistent, single-moment dump of one PostgreSQL 17 Logbook database.
#
#   sh dump.sh > logbook.dump.sql
#   sh dump.sh -o logbook.dump.sql
#   sh dump.sh -r age1... -o logbook.dump.sql.age
#
# Connect as the role that owns Logbook's schemas, using PGHOST, PGPORT,
# PGDATABASE and PGUSER. When -r (or LOGBOOK_AGE_RECIPIENT) is given, the dump
# is piped directly into age without writing plaintext SQL to disk. When -o is
# given, output is written to a temporary file in the same directory and moved
# into place only after the dump (and encryption, if requested) finishes without
# error.
#
# It refuses, and leaves no output file behind, when:
#   - the server does not answer, or is not PostgreSQL 17
#   - the database does not hold a migrated Logbook schema
#   - encryption is requested and the recipient is malformed or age is missing
#
# Needs sh, psql and pg_dump from PostgreSQL 17 (plus age when -r is used).

set -eu
LC_ALL=C
export LC_ALL
PGCONNECT_TIMEOUT=${PGCONNECT_TIMEOUT:-10}
export PGCONNECT_TIMEOUT

out_file=''
recipient=${LOGBOOK_AGE_RECIPIENT:-}

refuse() {
    printf '%s\n' "$1" >&2
    exit 1
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        -o)
            [ "$#" -ge 2 ] && [ -n "$2" ] ||
                refuse 'E_PARSE: usage: sh dump.sh [-o file] [-r age1...]'
            out_file=$2
            shift 2
            ;;
        -r)
            [ "$#" -ge 2 ] && [ -n "$2" ] ||
                refuse 'E_PARSE: usage: sh dump.sh [-o file] [-r age1...]'
            recipient=$2
            shift 2
            ;;
        *)
            refuse 'E_PARSE: usage: sh dump.sh [-o file] [-r age1...]'
            ;;
    esac
done

for tool in psql pg_dump; do
    command -v "$tool" >/dev/null 2>&1 ||
        refuse "E_NEEDS_SUBTOOL: $tool from PostgreSQL 17 is not on the PATH"
done

pg_dump --version 2>/dev/null | grep -Eq ' 17(\.[0-9]+)?([[:space:]]|$)' ||
    refuse 'E_NEEDS_SUBTOOL: pg_dump must be from PostgreSQL 17'

if [ -n "$recipient" ]; then
    printf '%s\n' "$recipient" | grep -Eq '^age1[0-9a-z]{10,}$' ||
        refuse 'E_PARSE: the age recipient is not well-formed'
    command -v age >/dev/null 2>&1 ||
        refuse 'E_NEEDS_SUBTOOL: age is not on the PATH'
fi

ask() {
    psql </dev/null -X -q -A -t -v ON_ERROR_STOP=1 -c "$1" 2>/dev/null
}

major=$(ask "SELECT current_setting('server_version_num')::integer / 10000") ||
    refuse 'E_TIMEOUT: the database did not answer'
[ "$major" = 17 ] ||
    refuse 'E_NEEDS_SUBTOOL: Logbook dumps require PostgreSQL 17 and the server is another version'

[ "$(ask "SELECT to_regclass('core.migration') IS NOT NULL")" = t ] ||
    refuse 'E_PARSE: the database does not hold a migrated Logbook schema'
[ "$(ask "SELECT count(*) > 0 FROM core.migration")" = t ] ||
    refuse 'E_PARSE: the database does not hold a migrated Logbook schema'

work=$(mktemp -d "${TMPDIR:-/tmp}/logbook-dump.XXXXXX")
tmp_out=''
cleanup() {
    if [ -n "$tmp_out" ] && [ -f "$tmp_out" ]; then
        rm -f "$tmp_out"
    fi
    rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 1' INT TERM

if [ -n "$out_file" ]; then
    out_dir=$(dirname "$out_file")
    [ -d "$out_dir" ] ||
        refuse 'E_PARSE: the output directory does not exist'
    tmp_out=$(umask 077 && mktemp "$out_dir/.logbook-dump.XXXXXX") ||
        refuse 'E_PARSE: the output file cannot be written'
fi

if [ -z "$recipient" ]; then
    if [ -n "$tmp_out" ]; then
        pg_dump --serializable-deferrable --encoding=UTF8 --no-password >"$tmp_out" 2>"$work/dump.err" ||
            refuse 'E_TIMEOUT: pg_dump did not finish cleanly'
    else
        pg_dump --serializable-deferrable --encoding=UTF8 --no-password 2>"$work/dump.err" ||
            refuse 'E_TIMEOUT: pg_dump did not finish cleanly'
    fi
else
    age_ok=yes
    if [ -n "$tmp_out" ]; then
        { pg_dump --serializable-deferrable --encoding=UTF8 --no-password 2>"$work/dump.err" ||
            printf 'failed\n' >"$work/dump.failed"; } |
            age -r "$recipient" >"$tmp_out" 2>"$work/age.err" || age_ok=no
    else
        { pg_dump --serializable-deferrable --encoding=UTF8 --no-password 2>"$work/dump.err" ||
            printf 'failed\n' >"$work/dump.failed"; } |
            age -r "$recipient" 2>"$work/age.err" || age_ok=no
    fi
    [ ! -f "$work/dump.failed" ] ||
        refuse 'E_TIMEOUT: pg_dump did not finish cleanly'
    [ "$age_ok" = yes ] ||
        refuse 'E_PARSE: age could not encrypt the dump'
fi

if [ -n "$tmp_out" ]; then
    mv -f "$tmp_out" "$out_file" ||
        refuse 'E_PARSE: the output file cannot be written'
    tmp_out=''
fi
