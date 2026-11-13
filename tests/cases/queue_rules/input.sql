-- The rules for core.queue, tried as Muster's role.
SET ROLE core_rw;
INSERT INTO core.item (item_id, state, title, source_url, source_hash)
VALUES ('PA-0001', 'recorded', 'Example rate calculator', 'https://example.test/tools/one', repeat('a', 64));
INSERT INTO core.edit_proposal (kind, target, payload, status)
VALUES ('DATA', 'catalog/example', 'Text.', 'pending_approval');

\echo == one entry of each status is accepted
INSERT INTO core.queue (item_id, worker, lane, status, enqueued_at)
VALUES ('PA-0001', 'sextant', 'normal', 'waiting', '2026-01-05 09:00+00');
INSERT INTO core.queue (item_id, worker, lane, status, lease_token, lease_expires_at, heartbeat_at, enqueued_at)
VALUES ('PA-0001', 'sextant', 'urgent', 'leased', 'example-lease-token', '2026-01-05 09:05+00', '2026-01-05 09:01+00', '2026-01-05 09:00+00');
INSERT INTO core.queue (item_id, worker, lane, status, enqueued_at)
VALUES ('PA-0001', 'trawl', 'backfill', 'completed', '2026-01-05 09:00+00');
INSERT INTO core.queue (item_id, worker, lane, status, error_code, enqueued_at)
VALUES ('PA-0001', 'sextant', 'normal', 'failed', 'E_TIMEOUT', '2026-01-05 09:00+00');
INSERT INTO core.queue (item_id, worker, lane, status, error_code, enqueued_at)
VALUES ('PA-0001', 'sextant', 'normal', 'failed', 'E_PARSE', '2026-01-05 09:00+00');
INSERT INTO core.queue (item_id, worker, lane, status, error_code, enqueued_at)
VALUES ('PA-0001', 'sextant', 'normal', 'needs_subtool', 'E_NEEDS_SUBTOOL', '2026-01-05 09:00+00');

\echo == an entry may be about a proposal, or about neither an item nor a proposal
INSERT INTO core.queue (proposal_id, worker, lane, status, enqueued_at)
VALUES (1, 'countersign', 'normal', 'waiting', '2026-01-05 09:00+00');
INSERT INTO core.queue (worker, lane, status, enqueued_at)
VALUES ('tidegauge', 'normal', 'waiting', '2026-01-05 09:00+00');
SELECT queue_id, item_id, proposal_id, worker, lane, status, lease_token, lease_expires_at, heartbeat_at, error_code, enqueued_at
FROM core.queue ORDER BY queue_id;

\echo == each required column
INSERT INTO core.queue (item_id, worker, lane, status, enqueued_at) VALUES ('PA-0001', NULL, 'normal', 'waiting', '2026-01-05 09:00+00');
INSERT INTO core.queue (item_id, worker, lane, status, enqueued_at) VALUES ('PA-0001', 'sextant', NULL, 'waiting', '2026-01-05 09:00+00');
INSERT INTO core.queue (item_id, worker, lane, status, enqueued_at) VALUES ('PA-0001', 'sextant', 'normal', NULL, '2026-01-05 09:00+00');
INSERT INTO core.queue (item_id, worker, lane, status, enqueued_at) VALUES ('PA-0001', 'sextant', 'normal', 'waiting', NULL);

\echo == a worker, a lane or a status outside the known ones is unfamiliar
INSERT INTO core.queue (item_id, worker, lane, status) VALUES ('PA-0001', 'lookout', 'normal', 'waiting');
INSERT INTO core.queue (item_id, worker, lane, status) VALUES ('PA-0001', 'sextant', 'express', 'waiting');
INSERT INTO core.queue (item_id, worker, lane, status) VALUES ('PA-0001', 'sextant', 'normal', 'snoozed');

\echo == not both an item and a proposal
INSERT INTO core.queue (item_id, proposal_id, worker, lane, status) VALUES ('PA-0001', 1, 'countersign', 'normal', 'waiting');

\echo == a lease has a token and an expiry, and only a lease has them
INSERT INTO core.queue (item_id, worker, lane, status) VALUES ('PA-0001', 'sextant', 'normal', 'leased');
INSERT INTO core.queue (item_id, worker, lane, status, lease_token) VALUES ('PA-0001', 'sextant', 'normal', 'leased', 'example-lease-token');
INSERT INTO core.queue (item_id, worker, lane, status, lease_expires_at) VALUES ('PA-0001', 'sextant', 'normal', 'leased', '2026-01-05 09:05+00');
INSERT INTO core.queue (item_id, worker, lane, status, lease_token, lease_expires_at) VALUES ('PA-0001', 'sextant', 'normal', 'leased', '', '2026-01-05 09:05+00');
INSERT INTO core.queue (item_id, worker, lane, status, lease_token) VALUES ('PA-0001', 'sextant', 'normal', 'waiting', 'example-lease-token');
INSERT INTO core.queue (item_id, worker, lane, status, lease_expires_at) VALUES ('PA-0001', 'sextant', 'normal', 'completed', '2026-01-05 09:05+00');

\echo == the error code goes with the status
INSERT INTO core.queue (item_id, worker, lane, status) VALUES ('PA-0001', 'sextant', 'normal', 'needs_subtool');
INSERT INTO core.queue (item_id, worker, lane, status, error_code) VALUES ('PA-0001', 'sextant', 'normal', 'needs_subtool', 'E_PARSE');
INSERT INTO core.queue (item_id, worker, lane, status) VALUES ('PA-0001', 'sextant', 'normal', 'failed');
INSERT INTO core.queue (item_id, worker, lane, status, error_code) VALUES ('PA-0001', 'sextant', 'normal', 'failed', 'E_NEEDS_SUBTOOL');
INSERT INTO core.queue (item_id, worker, lane, status, error_code) VALUES ('PA-0001', 'sextant', 'normal', 'failed', 'E_OTHER');
INSERT INTO core.queue (item_id, worker, lane, status, error_code) VALUES ('PA-0001', 'sextant', 'normal', 'waiting', 'E_TIMEOUT');

\echo == a lease is taken, kept alive and given back, and the rules apply at each step
UPDATE core.queue SET status = 'leased' WHERE queue_id = 1;
UPDATE core.queue SET status = 'leased', lease_token = 'example-lease-token-2', lease_expires_at = '2026-01-05 09:10+00' WHERE queue_id = 1;
UPDATE core.queue SET heartbeat_at = '2026-01-05 09:06+00', lease_expires_at = '2026-01-05 09:15+00' WHERE queue_id = 1;
UPDATE core.queue SET status = 'completed' WHERE queue_id = 1;
UPDATE core.queue SET status = 'completed', lease_token = NULL, lease_expires_at = NULL WHERE queue_id = 1;
SELECT queue_id, status, lease_token, lease_expires_at, heartbeat_at FROM core.queue WHERE queue_id = 1;

\echo == a finished entry may be removed
DELETE FROM core.queue WHERE queue_id = 3;
SELECT count(*) AS entries FROM core.queue;
