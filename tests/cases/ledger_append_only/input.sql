-- The ledger takes new entries and nothing else, whoever asks.
INSERT INTO core.item (item_id, state, title, source_url, source_hash)
VALUES ('PA-0001', 'recorded', 'Example rate calculator', 'https://example.test/tools/one', repeat('a', 64));
INSERT INTO core.edit_proposal (kind, target, payload, status)
VALUES ('DATA', 'catalog/example', 'Text.', 'pending_approval');
INSERT INTO core.ledger (item_id, from_state, to_state, worker, recorded_at)
VALUES ('PA-0001', NULL, 'recorded', 'trawl', '2026-01-05 09:00+00');
INSERT INTO core.ledger (proposal_id, from_state, to_state, recorded_at)
VALUES (1, NULL, 'pending_approval', '2026-01-07 09:00+00');

\echo == as core_rw: an entry can be added and read
SET ROLE core_rw;
INSERT INTO core.ledger (item_id, from_state, to_state, worker, recorded_at)
VALUES ('PA-0001', 'recorded', 'observed', 'sextant', '2026-01-05 09:30+00');
SELECT ledger_id, item_id, proposal_id, from_state, to_state FROM core.ledger ORDER BY ledger_id;

\echo == as core_rw: an entry cannot be changed, removed or emptied out
UPDATE core.ledger SET to_state = 'scored' WHERE ledger_id = 1;
DELETE FROM core.ledger WHERE ledger_id = 1;
TRUNCATE core.ledger;
RESET ROLE;

\echo == as the owner of the table: the same
UPDATE core.ledger SET to_state = 'scored' WHERE ledger_id = 1;
DELETE FROM core.ledger WHERE ledger_id = 1;
TRUNCATE core.ledger;
TRUNCATE core.ledger, core.item, core.edit_proposal, core.queue, core.evaluation, core.decision;

\echo == an attempt that would touch no entry is refused too
UPDATE core.ledger SET to_state = 'scored' WHERE ledger_id = 999;
DELETE FROM core.ledger WHERE false;

\echo == an item or a proposal the ledger mentions cannot be removed from under it
DELETE FROM core.item WHERE item_id = 'PA-0001';
DELETE FROM core.edit_proposal WHERE proposal_id = 1;
UPDATE core.item SET item_id = 'PA-0002' WHERE item_id = 'PA-0001';

\echo == the ledger is as it was
SELECT ledger_id, item_id, proposal_id, from_state, to_state, worker, recorded_at FROM core.ledger ORDER BY ledger_id;
