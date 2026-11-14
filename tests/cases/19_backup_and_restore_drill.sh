# Rules for dump.sh and restore-drill.sh: a consistent dump (plain or age-
# encrypted) restores cleanly into an isolated scratch cluster or an empty
# database, locks down database-level CONNECT privileges, passes every integrity
# and privilege check, and refuses broken inputs without leaving partial files
# or scratch directories behind.
#
# Run by tests/run.sh in a new, empty database. LOGBOOK_ROOT is the repository
# and LOGBOOK_TEST_TMP is a directory this case may write in.

dump_script="$LOGBOOK_ROOT/dump.sh"
drill_script="$LOGBOOK_ROOT/restore-drill.sh"
work="$LOGBOOK_TEST_TMP/case19"
rm -rf "$work"
mkdir -p "$work/drill-tmp"

run() {
    printf '\n== %s\n' "$1"
    shift
    "$@"
    printf 'exit status %s\n' "$?"
}

ask() {
    psql -X -q -A -t -c "$1"
}

run 'An empty database with no Logbook schema: dump.sh refuses.' \
    sh "$dump_script" -o "$work/should-not-exist.sql"
printf 'output file exists: %s\n' "$([ -e "$work/should-not-exist.sql" ] && echo yes || echo no)"

sh "$LOGBOOK_ROOT/migrate.sh" >/dev/null
psql -X -q -f "$LOGBOOK_ROOT/tests/fixtures/sample_record.sql"
psql -X -q -v ON_ERROR_STOP=1 <<'SQL'
SET SESSION AUTHORIZATION muster;
INSERT INTO core.result (item_id, worker, payload)
VALUES ('PA-0001', 'waybill', '{"spec_version":1}'::jsonb);
INSERT INTO core.lease_outcome (item_id, lease, worker, call_name, call_arg, ack_state, ack_next)
VALUES ('PA-0001', 'PA-0001.1.1', 'chartroom', 'complete', 'live', 'live', NULL);
INSERT INTO core.component_health (component, state, digest)
VALUES ('muster', 'healthy', 'sha256:1111111111111111111111111111111111111111111111111111111111111111');
INSERT INTO core.submission_count (submission_day, visitor_key, submissions)
VALUES (DATE '2026-03-01', 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 2);
SQL

run 'A migrated database: dump.sh writes a consistent dump atomically.' \
    sh "$dump_script" -o "$work/logbook.dump.sql"
printf 'dump file non-empty: %s\n' "$([ -s "$work/logbook.dump.sql" ] && echo yes || echo no)"

run 'Scratch restore drill: starts an isolated PostgreSQL 17 server, verifies everything, and tears down.' \
    env TMPDIR="$work/drill-tmp" PGPORT=65431 sh "$drill_script" -f "$work/logbook.dump.sql"
leftover=$(ls -A "$work/drill-tmp" 2>/dev/null | wc -l | tr -d ' ')
printf 'scratch entries left behind: %s\n' "$leftover"

psql -X -q -c 'CREATE DATABASE logbook_test_19_restored'
run 'Restore into an empty database: locks down CONNECT and verifies integrity and role fences.' \
    env PGDATABASE=logbook_test_19_restored sh "$drill_script" --into-empty-db -f "$work/logbook.dump.sql"

printf '\n== Restored empty-db copy preserves Contract v1 state and fences.\n'
PGDATABASE=logbook_test_19_restored ask "
    SELECT 'anyone may connect: ' || has_database_privilege('public', current_database(), 'CONNECT')
"
PGDATABASE=logbook_test_19_restored ask "
    SELECT 'pub_ro may create temp tables: ' || has_database_privilege('pub_ro', current_database(), 'TEMPORARY')
"
PGDATABASE=logbook_test_19_restored ask "
    SELECT 'results ' || (SELECT count(*) FROM core.result)
        || ', outcomes ' || (SELECT count(*) FROM core.lease_outcome)
        || ', health ' || (SELECT count(*) FROM core.component_health)
        || ', submissions ' || (SELECT count(*) FROM core.submission_count)
"
PGDATABASE=logbook_test_19_restored psql -X -q -A -t \
    -c 'SET SESSION AUTHORIZATION muster' \
    -c "INSERT INTO core.item (state, title, source) VALUES ('recorded', 'Post-restore item', 'sam-gov') RETURNING item_id"

run 'Restore into a database that is already populated: refused without harming existing data.' \
    env PGDATABASE=logbook_test_19_restored sh "$drill_script" --into-empty-db -f "$work/logbook.dump.sql"
PGDATABASE=logbook_test_19_restored ask "SELECT 'items still there: ' || count(*) FROM core.item"
psql -X -q -c 'DROP DATABASE logbook_test_19_restored'

# Build a PATH without age so this check behaves the same whether or not the
# host has age installed.
mkdir -p "$work/no-age-bin"
for cmd in sh psql pg_dump grep sed head cut cat mktemp dirname mv rm id; do
    loc=$(command -v "$cmd" 2>/dev/null || true)
    case "$loc" in
        /*) ln -sf "$loc" "$work/no-age-bin/$cmd" ;;
        *)
            for d in /usr/local/bin /usr/bin /bin; do
                if [ -x "$d/$cmd" ]; then
                    ln -sf "$d/$cmd" "$work/no-age-bin/$cmd"
                    break
                fi
            done
            ;;
    esac
done

run 'Malformed age recipient: refused without repeating the bad value or leaving a file.' \
    env PATH="$work/no-age-bin" sh "$dump_script" -r NOT_A_VALID_AGE_KEY -o "$work/bad-recipient.age"
printf 'output file exists: %s\n' "$([ -e "$work/bad-recipient.age" ] && echo yes || echo no)"

sample_recipient='age1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq9d7j3k'

run 'Encryption requested when age is not on the PATH: refused with E_NEEDS_SUBTOOL.' \
    env PATH="$work/no-age-bin" sh "$dump_script" -r "$sample_recipient" -o "$work/no-age.age"
printf 'output file exists: %s\n' "$([ -e "$work/no-age.age" ] && echo yes || echo no)"

# Stand-in for age so encrypted round-trip and wrong-key refusal run inside
# stock postgres:17-alpine with no network.
mkdir -p "$work/fake-age"
cat >"$work/fake-age/age" <<'SH'
#!/bin/sh
set -eu
if [ "${1:-}" = "-r" ] && [ -n "${2:-}" ]; then
    printf 'AGE-STANDIN:%s\n' "$2"
    cat
    exit 0
fi
if [ "${1:-}" = "-d" ] && [ "${2:-}" = "-i" ] && [ -n "${3:-}" ]; then
    want=$(cat "$3")
    IFS= read -r header || exit 1
    [ "$header" = "AGE-STANDIN:$want" ] || {
        printf 'no identity matched any of the recipients\n' >&2
        exit 1
    }
    cat
    exit 0
fi
exit 2
SH
chmod +x "$work/fake-age/age"
printf '%s\n' "$sample_recipient" >"$work/good-key.txt"
printf 'age1zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz000000\n' >"$work/wrong-key.txt"

run 'Encrypted dump with age: writes no plaintext header and restores cleanly with the matching key.' \
    env PATH="$work/fake-age:$PATH" sh "$dump_script" -r "$sample_recipient" -o "$work/logbook.dump.sql.age"
printf 'starts with age header: %s\n' "$(head -n 1 "$work/logbook.dump.sql.age" | grep -q '^AGE-STANDIN:' && echo yes || echo no)"

run 'Scratch restore drill on encrypted dump with matching key: decrypts and passes.' \
    env PATH="$work/fake-age:$PATH" TMPDIR="$work/drill-tmp" sh "$drill_script" -f "$work/logbook.dump.sql.age" -i "$work/good-key.txt"

run 'Restore drill on encrypted dump with wrong key: refused before touching any database.' \
    env PATH="$work/fake-age:$PATH" TMPDIR="$work/drill-tmp" sh "$drill_script" -f "$work/logbook.dump.sql.age" -i "$work/wrong-key.txt"

# Corrupt the state of PA-0001 in a copy of the dump so COPY succeeds and
# core.integrity_check() catches the mismatch against core.ledger.
sed 's/^PA-0001	live	/PA-0001	building	/' "$work/logbook.dump.sql" >"$work/tampered.dump.sql"
run 'Tampered dump whose item state disagrees with core.ledger: caught by core.integrity_check().' \
    env TMPDIR="$work/drill-tmp" sh "$drill_script" -f "$work/tampered.dump.sql"

run 'The database does not answer when dumping: refused without naming where it was looked for.' \
    env PGHOST="$work/no-such-socket" PGCONNECT_TIMEOUT=2 sh "$dump_script" -o "$work/unreachable.sql"
printf 'output file exists: %s\n' "$([ -e "$work/unreachable.sql" ] && echo yes || echo no)"
