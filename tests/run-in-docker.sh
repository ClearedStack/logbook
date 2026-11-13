#!/bin/sh
# Start a throwaway PostgreSQL 17 (the image named in component.json), with
# the 256 MiB memory budget, and run tests/run.sh inside it. The repository
# is mounted read-only. The server listens on a local socket only and is
# removed afterwards, so no password is involved.
#
#   tests/run-in-docker.sh [--record]
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
image=postgres:17-alpine
name="logbook-test-$$"
mount="$root:/logbook:ro"
[ "${1:-}" = --record ] && mount="$root:/logbook"

docker run -d --rm --name "$name" --memory 256m --network none \
    -e POSTGRES_HOST_AUTH_METHOD=trust -v "$mount" "$image" \
    -c listen_addresses= > /dev/null
trap 'docker stop "$name" > /dev/null' EXIT

# The image starts a temporary server first, then the real one: wait until
# the real one has been up for two checks in a row.
ready=0; tries=0
while [ "$ready" -lt 2 ]; do
    tries=$((tries + 1))
    [ "$tries" -le 120 ] || { echo "PostgreSQL did not start" >&2; exit 1; }
    if docker exec "$name" sh -c 'pg_isready -q -U postgres && [ "$(cat /proc/1/comm)" = postgres ]'; then
        ready=$((ready + 1))
    else
        ready=0
    fi
    sleep 0.5
done

docker exec -e PGUSER=postgres "$name" sh /logbook/tests/run.sh "$@"
