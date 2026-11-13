-- An item's change of state, its next queue step and its ledger entry are kept
-- together or not at all.
SET ROLE core_rw;
INSERT INTO core.item (item_id, state, title, source_url, source_hash, created_at, updated_at)
VALUES ('PA-0001', 'recorded', 'Example rate calculator', 'https://example.test/tools/one', repeat('a', 64), '2026-01-05 09:00+00', '2026-01-05 09:00+00');
INSERT INTO core.queue (item_id, worker, lane, status, lease_token, lease_expires_at, enqueued_at)
VALUES ('PA-0001', 'sextant', 'normal', 'leased', 'example-lease-token', '2026-01-05 09:35+00', '2026-01-05 09:00+00');

\echo == a hand-off whose last step is refused leaves nothing behind
BEGIN;
UPDATE core.item SET state = 'observed', updated_at = '2026-01-05 09:30+00' WHERE item_id = 'PA-0001';
UPDATE core.queue SET status = 'completed', lease_token = NULL, lease_expires_at = NULL WHERE queue_id = 1;
INSERT INTO core.queue (item_id, worker, lane, status, enqueued_at)
VALUES ('PA-0001', 'assay', 'normal', 'waiting', '2026-01-05 09:30+00');
INSERT INTO core.ledger (item_id, from_state, to_state, worker, recorded_at)
VALUES ('PA-0001', 'recorded', 'observd', 'sextant', '2026-01-05 09:30+00');
COMMIT;
SELECT item_id, state, updated_at FROM core.item;
SELECT queue_id, worker, status FROM core.queue ORDER BY queue_id;
SELECT count(*) AS ledger_entries FROM core.ledger;

\echo == the same hand-off, well formed, is kept whole
BEGIN;
UPDATE core.item SET state = 'observed', updated_at = '2026-01-05 09:30+00' WHERE item_id = 'PA-0001';
UPDATE core.queue SET status = 'completed', lease_token = NULL, lease_expires_at = NULL WHERE queue_id = 1;
INSERT INTO core.queue (item_id, worker, lane, status, enqueued_at)
VALUES ('PA-0001', 'assay', 'normal', 'waiting', '2026-01-05 09:30+00');
INSERT INTO core.ledger (item_id, from_state, to_state, worker, recorded_at)
VALUES ('PA-0001', 'recorded', 'observed', 'sextant', '2026-01-05 09:30+00');
COMMIT;
SELECT item_id, state, updated_at FROM core.item;
SELECT worker, status FROM core.queue ORDER BY queue_id;
SELECT item_id, from_state, to_state, worker, recorded_at FROM core.ledger ORDER BY ledger_id;

\echo == times that are not given are the time of the transaction, the same in every row
BEGIN;
INSERT INTO core.item (item_id, state, title, source_url, source_hash)
VALUES ('PA-0002', 'recorded', 'Example checklist', 'https://example.test/tools/two', repeat('b', 64));
INSERT INTO core.queue (item_id, worker, lane, status) VALUES ('PA-0002', 'sextant', 'backfill', 'waiting');
INSERT INTO core.ledger (item_id, to_state, worker) VALUES ('PA-0002', 'recorded', 'trawl');
COMMIT;
SELECT i.created_at = i.updated_at AND i.created_at = q.enqueued_at AND i.created_at = l.recorded_at AS same_time
FROM core.item i
JOIN core.queue q ON q.item_id = i.item_id
JOIN core.ledger l ON l.item_id = i.item_id
WHERE i.item_id = 'PA-0002';
