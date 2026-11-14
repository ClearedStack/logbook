#!/bin/sh
# Restores a Logbook dump (plain SQL or age-encrypted) and runs deterministic
# integrity and privilege checks on the restored database.
#
#   sh restore-drill.sh -f logbook.dump.sql
#   sh restore-drill.sh -f logbook.dump.sql.age -i age-key.txt
#   PGDATABASE=logbook sh restore-drill.sh --into-empty-db -f logbook.dump.sql
#
# By default it provisions an isolated PostgreSQL 17 server in a temporary
# directory, reachable only through a Unix socket in that directory, restores
# Logbook from scratch, locks down database-level privileges, verifies
# core.integrity_check() and role fences, and removes the temporary server on
# exit.
#
# With --into-empty-db it restores into the existing empty PostgreSQL 17
# database named by PGDATABASE (using PGHOST, PGPORT and PGUSER), refusing if
# that database already holds any schema or relation of Logbook's or any user
# table.

set -eu
LC_ALL=C
export LC_ALL
PGCONNECT_TIMEOUT=${PGCONNECT_TIMEOUT:-10}
export PGCONNECT_TIMEOUT

in_file=''
identity_file=${LOGBOOK_AGE_IDENTITY:-}
mode=scratch

refuse() {
    printf '%s\n' "$1" >&2
    exit 1
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        -f)
            [ "$#" -ge 2 ] && [ -n "$2" ] ||
                refuse 'E_PARSE: usage: sh restore-drill.sh [-f file] [-i identity-file] [--into-empty-db]'
            in_file=$2
            shift 2
            ;;
        -i)
            [ "$#" -ge 2 ] && [ -n "$2" ] ||
                refuse 'E_PARSE: usage: sh restore-drill.sh [-f file] [-i identity-file] [--into-empty-db]'
            identity_file=$2
            shift 2
            ;;
        --into-empty-db)
            mode=existing
            shift
            ;;
        *)
            refuse 'E_PARSE: usage: sh restore-drill.sh [-f file] [-i identity-file] [--into-empty-db]'
            ;;
    esac
done

if [ -n "$in_file" ]; then
    [ -f "$in_file" ] && [ -r "$in_file" ] ||
        refuse 'E_PARSE: the dump file cannot be read'
fi

if [ -n "$identity_file" ]; then
    [ -f "$identity_file" ] && [ -r "$identity_file" ] ||
        refuse 'E_PARSE: the age identity file cannot be read'
    command -v age >/dev/null 2>&1 ||
        refuse 'E_NEEDS_SUBTOOL: age is not on the PATH'
fi

if [ "$mode" = scratch ]; then
    for tool in initdb pg_ctl psql createdb; do
        command -v "$tool" >/dev/null 2>&1 ||
            refuse "E_NEEDS_SUBTOOL: $tool from PostgreSQL 17 is not on the PATH"
    done
    initdb --version 2>/dev/null | grep -Eq ' 17(\.[0-9]+)?([[:space:]]|$)' ||
        refuse 'E_NEEDS_SUBTOOL: restore-drill.sh requires PostgreSQL 17'
    [ "$(id -u)" != 0 ] ||
        refuse 'E_PARSE: scratch restore drill cannot run as root'
else
    command -v psql >/dev/null 2>&1 ||
        refuse 'E_NEEDS_SUBTOOL: psql from PostgreSQL 17 is not on the PATH'
    [ -n "${PGDATABASE:-}" ] ||
        refuse 'E_PARSE: PGDATABASE must name the empty database to restore into'
fi

work=$(umask 077 && mktemp -d "${TMPDIR:-/tmp}/logbook-drill.XXXXXX")
scratch_started=no
cleanup() {
    if [ "$scratch_started" = yes ]; then
        pg_ctl -D "$work/data" -m immediate -w stop </dev/null >/dev/null 2>&1 || true
    fi
    rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 1' INT TERM

ask() {
    psql </dev/null -X -q -A -t -v ON_ERROR_STOP=1 -c "$1" 2>/dev/null
}

# Prepare or decrypt the SQL input before touching PostgreSQL so a damaged or
# undecryptable archive fails cleanly without modifying any target database.
sql_file=$in_file
temp_sql=''
if [ -n "$identity_file" ]; then
    temp_sql="$work/decrypted.sql"
    if [ -n "$in_file" ]; then
        age -d -i "$identity_file" <"$in_file" >"$temp_sql" 2>/dev/null ||
            refuse 'E_PARSE: age could not decrypt the dump with the given key'
    else
        age -d -i "$identity_file" >"$temp_sql" 2>/dev/null ||
            refuse 'E_PARSE: age could not decrypt the dump with the given key'
    fi
    [ -s "$temp_sql" ] ||
        refuse 'E_PARSE: the decrypted dump is empty'
    sql_file=$temp_sql
    printf 'decrypt ok\n'
elif [ -z "$in_file" ]; then
    temp_sql="$work/input.sql"
    cat >"$temp_sql"
    [ -s "$temp_sql" ] ||
        refuse 'E_PARSE: the dump input is empty'
    sql_file=$temp_sql
else
    [ -s "$in_file" ] ||
        refuse 'E_PARSE: the dump input is empty'
fi

if [ "$mode" = scratch ]; then
    unset PGPORT PGHOSTADDR PGPASSWORD PGPASSFILE PGSERVICE
    initdb -D "$work/data" -U postgres -A trust -E UTF8 --locale=C --wal-segsize=1 \
        </dev/null >"$work/initdb.log" 2>&1 ||
        refuse 'E_PARSE: initdb could not initialize the scratch cluster'
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
jit = off
CONF
    pg_ctl -D "$work/data" -l "$work/server.log" -w start </dev/null >/dev/null 2>&1 ||
        refuse 'E_TIMEOUT: the scratch PostgreSQL 17 server did not start'
    scratch_started=yes
    PGHOST=$work
    PGUSER=postgres
    PGDATABASE=logbook_drill
    PGTZ=UTC
    PGDATESTYLE='ISO, YMD'
    export PGHOST PGUSER PGDATABASE PGTZ PGDATESTYLE
    createdb </dev/null "$PGDATABASE" 2>/dev/null ||
        refuse 'E_PARSE: could not create scratch database'
else
    major=$(ask "SELECT current_setting('server_version_num')::integer / 10000") ||
        refuse 'E_TIMEOUT: the database did not answer'
    [ "$major" = 17 ] ||
        refuse 'E_NEEDS_SUBTOOL: Logbook restores require PostgreSQL 17 and the server is another version'
    occupied=$(ask "
        SELECT EXISTS (
            SELECT 1 FROM pg_catalog.pg_namespace WHERE nspname IN ('core', 'pub')
        ) OR EXISTS (
            SELECT 1 FROM pg_catalog.pg_class c
            JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
              AND n.nspname !~ '^pg_toast'
              AND c.relkind IN ('r', 'p', 'v', 'm', 'S', 'f')
        )
    ") || refuse 'E_TIMEOUT: the database did not answer'
    [ "$occupied" = f ] ||
        refuse 'E_PARSE: target database is not empty'
fi

# Roles belong to the whole cluster; create them if absent, and refuse if an
# existing role holds powers or memberships Logbook never grants.
if ! role_err=$(psql -X -q -v ON_ERROR_STOP=1 -v VERBOSITY=terse 2>&1 >/dev/null <<'SQL'
DO $$
DECLARE
    wanted text;
BEGIN
    FOREACH wanted IN ARRAY ARRAY['muster', 'pub_ro'] LOOP
        IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = wanted) THEN
            EXECUTE format(
                'CREATE ROLE %I NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS',
                wanted);
        ELSIF EXISTS (
            SELECT FROM pg_catalog.pg_roles
            WHERE rolname = wanted
              AND (rolsuper OR rolcreatedb OR rolcreaterole OR rolreplication OR rolbypassrls)
        ) OR EXISTS (
            SELECT FROM pg_catalog.pg_auth_members m
            JOIN pg_catalog.pg_roles r ON r.oid = m.member
            WHERE r.rolname = wanted
        ) THEN
            RAISE EXCEPTION 'E_NEEDS_SUBTOOL: role % already exists with powers Logbook does not give it', wanted;
        END IF;
    END LOOP;
END
$$;
SQL
); then
    reason=$(printf '%s\n' "$role_err" | sed -n 's/^.*ERROR:  *//p' | head -n 1)
    case "$reason" in
        E_NEEDS_SUBTOOL:*) refuse "$reason" ;;
        *) refuse 'E_PARSE: could not prepare Logbook roles before restore' ;;
    esac
fi

psql </dev/null -X -q -v ON_ERROR_STOP=1 -v VERBOSITY=terse -f "$sql_file" \
    >"$work/restore.out" 2>"$work/restore.err" ||
    refuse 'E_PARSE: the dump did not restore cleanly'

if [ -n "$temp_sql" ]; then
    rm -f "$temp_sql"
fi

# A single-database pg_dump omits database-level CONNECT privileges; restore
# the exact fence migrations 0001 and 0006 put on a fresh database.
if ! psql -X -q -v ON_ERROR_STOP=1 -v VERBOSITY=terse >/dev/null 2>&1 <<'SQL'
REVOKE ALL ON SCHEMA public FROM PUBLIC;
DO $$
BEGIN
    EXECUTE format('REVOKE ALL ON DATABASE %I FROM PUBLIC', current_database());
    EXECUTE format('GRANT CONNECT ON DATABASE %I TO muster, pub_ro', current_database());
END
$$;
SQL
then
    refuse 'E_PARSE: could not lock down database privileges after restore'
fi

printf 'restore ok\n'

[ "$(ask "SELECT to_regclass('core.migration') IS NOT NULL")" = t ] ||
    refuse 'E_PARSE: restored database is missing core.migration'
[ "$(ask "SELECT count(*) > 0 FROM core.migration")" = t ] ||
    refuse 'E_PARSE: restored database has no applied migrations'
[ "$(ask "SELECT to_regprocedure('core.integrity_check()') IS NOT NULL")" = t ] ||
    refuse 'E_PARSE: restored database is missing core.integrity_check()'

checks=$(ask 'SELECT count(*) FROM core.integrity_check()') ||
    refuse 'E_PARSE: core.integrity_check() could not run'
[ "$checks" -ge 15 ] ||
    refuse 'E_PARSE: core.integrity_check() returned fewer checks than expected'

bad_check=$(ask "SELECT check_name || ' (' || failures || ' failures)' FROM core.integrity_check() WHERE failures <> 0 LIMIT 1") ||
    refuse 'E_PARSE: core.integrity_check() could not run'
[ -z "$bad_check" ] ||
    refuse "E_PARSE: restored database failed integrity check $bad_check"

printf 'integrity ok: %s checks, 0 failures\n' "$checks"

[ "$(ask "SELECT has_database_privilege('public', current_database(), 'CONNECT')")" = f ] ||
    refuse 'E_PARSE: PUBLIC still holds CONNECT on the restored database'
[ "$(ask "SELECT has_database_privilege('pub_ro', current_database(), 'TEMPORARY')")" = f ] ||
    refuse 'E_PARSE: pub_ro holds TEMPORARY on the restored database'

[ "$(ask "
    SELECT count(*)
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'core' AND c.relkind IN ('r', 'p', 'v', 'm')
      AND (has_any_column_privilege('pub_ro', c.oid, 'SELECT, INSERT, UPDATE, REFERENCES')
           OR has_table_privilege('pub_ro', c.oid, 'DELETE, TRUNCATE, TRIGGER'))
")" = 0 ] || refuse 'E_PARSE: pub_ro can access an object in schema core'

[ "$(ask "
    SELECT count(*)
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'core' AND has_function_privilege('pub_ro', p.oid, 'EXECUTE')
")" = 0 ] || refuse 'E_PARSE: pub_ro can execute a function in schema core'

pub_views=$(ask "
    SELECT count(*)
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'pub' AND c.relkind = 'v'
")
[ "$pub_views" -ge 10 ] ||
    refuse 'E_PARSE: restored database is missing public views in schema pub'

[ "$(ask "
    SELECT count(*)
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'pub' AND c.relkind = 'v'
      AND NOT has_table_privilege('pub_ro', c.oid, 'SELECT')
")" = 0 ] || refuse 'E_PARSE: pub_ro cannot read every view in schema pub'

[ "$(ask "
    SELECT count(*)
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'pub' AND c.relkind = 'v'
      AND has_any_column_privilege('muster', c.oid, 'SELECT, INSERT, UPDATE, REFERENCES')
")" = 0 ] || refuse 'E_PARSE: muster can access schema pub'

[ "$(ask "SELECT has_table_privilege('muster', 'core.ledger'::regclass, 'UPDATE, DELETE, TRUNCATE')")" = f ] ||
    refuse 'E_PARSE: muster holds update or delete privilege on core.ledger'

# Read every public view as pub_ro to prove all view definitions resolve cleanly.
view_queries=$(ask "
    SELECT 'SELECT count(*) FROM pub.' || quote_ident(c.relname) || ';'
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'pub' AND c.relkind = 'v'
    ORDER BY c.relname
")
printf 'SET SESSION AUTHORIZATION pub_ro;\n%s\n' "$view_queries" |
    psql -X -q -v ON_ERROR_STOP=1 >/dev/null 2>&1 ||
    refuse 'E_PARSE: pub_ro could not query every view in schema pub'

printf 'privileges ok\n'
