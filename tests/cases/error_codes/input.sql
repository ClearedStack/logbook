-- The codes an error carries. Logbook raises two of the three public codes
-- itself. It never raises E_TIMEOUT: it waits on nothing outside itself.
SET ROLE core_rw;
INSERT INTO core.item (item_id, state, title, source_url, source_hash)
VALUES ('PA-0001', 'recorded', 'Example rate calculator', 'https://example.test/tools/one', repeat('a', 64));
INSERT INTO core.ledger (item_id, to_state) VALUES ('PA-0001', 'recorded');

\echo == broken data: E_PARSE, with SQLSTATE 22000
INSERT INTO core.item (item_id, state, title, source_url, source_hash)
VALUES ('PA-2', 'recorded', 'Example', 'https://example.test/tools/two', repeat('b', 64));
\echo :SQLSTATE

\echo == valid and unfamiliar data: E_NEEDS_SUBTOOL, with SQLSTATE 0A000
INSERT INTO core.item (item_id, state, title, source_url, source_hash)
VALUES ('PA-0002', 'archived', 'Example', 'https://example.test/tools/two', repeat('b', 64));
\echo :SQLSTATE

\echo == a write the role has no right to make: permission denied, with SQLSTATE 42501
UPDATE core.ledger SET to_state = 'observed';
\echo :SQLSTATE
RESET ROLE;
UPDATE core.ledger SET to_state = 'observed';
\echo :SQLSTATE
SET ROLE pub_ro;
SELECT * FROM core.item;
\echo :SQLSTATE
RESET ROLE;

\echo == an error message never repeats a value from the row
SET ROLE core_rw;
INSERT INTO core.queue (item_id, worker, lane, status, lease_token)
VALUES ('PA-0001', 'sextant', 'normal', 'waiting', 'SECRET-LEASE-TOKEN');
INSERT INTO core.queue (item_id, worker, lane, status, lease_token, lease_expires_at)
VALUES ('PA-0001', NULL, 'normal', 'leased', 'SECRET-LEASE-TOKEN', '2026-01-05 09:05+00');
INSERT INTO core.item (item_id, state, title, source_url, source_hash)
VALUES ('PA-0002', 'recorded', NULL, 'https://example.test/private/address', repeat('b', 64));
