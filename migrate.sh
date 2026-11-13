#!/bin/sh
# Applies Logbook's migrations, in order, to one PostgreSQL 17 database.
#
# The database is named the usual way, with PGHOST, PGPORT, PGDATABASE and
# PGUSER. Connect as the role that is to own Logbook's schemas. Each migration
# is applied in one transaction together with its entry in core.migration, so
# a migration is either wholly applied or not at all.
#
# It refuses, and changes nothing, when:
#   - the server is not PostgreSQL 17
#   - a file in the migrations directory is not named like 0001_some_name.sql
#   - a migration that was applied has since changed, or is no longer here
#   - a migration that was not applied sorts before one that was
#
# Needs only sh, psql and sha256sum. Writes nothing to disk.

set -eu
LC_ALL=C
export LC_ALL
PGCONNECT_TIMEOUT=${PGCONNECT_TIMEOUT:-10}
export PGCONNECT_TIMEOUT

dir=${LOGBOOK_MIGRATIONS:-$(cd "$(dirname "$0")" && pwd)/migrations}

refuse() {
    printf '%s\n' "$1" >&2
    exit 1
}

ask() {
    psql -X -q -A -t -v ON_ERROR_STOP=1 -c "$1" 2>/dev/null
}

# psql's own complaint about a failed connection can name a host or an address,
# so it is dropped and only the code is reported.
major=$(ask "SELECT current_setting('server_version_num')::integer / 10000") ||
    refuse 'E_TIMEOUT: the database did not answer'
[ "$major" = 17 ] ||
    refuse 'E_NEEDS_SUBTOOL: these migrations are written for PostgreSQL 17 and the server is another version'

files=$(ls "$dir" 2>/dev/null) || refuse 'E_PARSE: the migrations directory cannot be read'
[ -n "$files" ] || refuse 'E_PARSE: the migrations directory is empty'
for file in $files; do
    printf '%s\n' "$file" | grep -Eq '^[0-9]{4}_[a-z0-9_]+\.sql$' ||
        refuse 'E_PARSE: the migrations directory holds a file that is not named like 0001_some_name.sql'
done

applied=''
if [ "$(ask "SELECT to_regclass('core.migration') IS NOT NULL")" = t ]; then
    applied=$(ask "SELECT version || ' ' || checksum FROM core.migration ORDER BY version")
fi

# Every migration the database holds must still be here, unchanged.
while read -r version checksum; do
    [ -n "$version" ] || continue
    [ -f "$dir/$version.sql" ] ||
        refuse "E_NEEDS_SUBTOOL: the database holds migration $version, which this copy of Logbook does not have"
    [ "$(sha256sum "$dir/$version.sql" | cut -d' ' -f1)" = "$checksum" ] ||
        refuse "E_PARSE: migration $version has changed since it was applied"
done <<LIST
$applied
LIST

# The files are in order. Once one is found that was not applied, none after it
# may have been.
pending=''
for file in $files; do
    version=${file%.sql}
    if printf '%s\n' "$applied" | grep -q "^$version "; then
        [ -z "$pending" ] ||
            refuse "E_PARSE: migration $pending was not applied, and the later migration $version was"
    else
        pending=${pending:-$version}
    fi
done

count=0
for file in $files; do
    version=${file%.sql}
    if printf '%s\n' "$applied" | grep -q "^$version "; then
        continue
    fi
    checksum=$(sha256sum "$dir/$file" | cut -d' ' -f1)
    if ! output=$(
        cd "$dir" &&
        printf 'BEGIN;\n\\i %s\nINSERT INTO core.migration (version, checksum) VALUES ('\''%s'\'', '\''%s'\'');\nCOMMIT;\n' \
            "$file" "$version" "$checksum" |
        psql -X -q -v ON_ERROR_STOP=1 -v VERBOSITY=terse 2>&1 >/dev/null
    ); then
        # Keep the server's own words and drop the rest.
        reason=$(printf '%s\n' "$output" | sed -n 's/^.*ERROR:  *//p' | head -n 1)
        case "$reason" in
            E_PARSE:* | E_NEEDS_SUBTOOL:*) refuse "$reason" ;;
            '') refuse "E_TIMEOUT: the database stopped answering while migration $version was being applied; nothing from it was kept" ;;
            *) refuse "E_PARSE: migration $version was not applied, and nothing from it was kept: $reason" ;;
        esac
    fi
    printf 'applied %s\n' "$version"
    count=$((count + 1))
done

[ "$count" -gt 0 ] || printf 'nothing to apply\n'
