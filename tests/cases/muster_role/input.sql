-- What Muster's role, core_rw, can and cannot do.
SET ROLE core_rw;

\echo == it does its work in the working tables
INSERT INTO core.item (item_id, state, title, source_url, source_hash, created_at, updated_at)
VALUES ('PA-0001', 'recorded', 'Example rate calculator', 'https://example.test/tools/one', repeat('a', 64), '2026-01-05 09:00+00', '2026-01-05 09:00+00');
INSERT INTO core.evaluation (item_id, gates_passed, score, recommendation, evaluated_at)
VALUES ('PA-0001', true, 82, 'build', '2026-01-05 10:00+00');
INSERT INTO core.decision (item_id, outcome, decided_at) VALUES ('PA-0001', 'build', '2026-01-06 09:00+00');
INSERT INTO core.edit_proposal (kind, target, payload, status, submitted_at)
VALUES ('DATA', 'catalog/example', 'Text.', 'pending_approval', '2026-01-07 09:00+00');
INSERT INTO core.queue (item_id, worker, lane, status, enqueued_at)
VALUES ('PA-0001', 'waybill', 'normal', 'waiting', '2026-01-06 09:00+00');
INSERT INTO core.ledger (item_id, to_state, worker, recorded_at) VALUES ('PA-0001', 'recorded', 'trawl', '2026-01-05 09:00+00');
INSERT INTO core.restore_drill (ran_at, decrypt_passed, database_passed, plainforge_passed, lazarette_passed)
VALUES ('2026-01-01 03:00+00', true, true, true, true);
UPDATE core.item SET state = 'approved', updated_at = '2026-01-06 09:00+00' WHERE item_id = 'PA-0001';
UPDATE core.edit_proposal SET status = 'approved' WHERE proposal_id = 1;
SELECT (SELECT count(*) FROM core.item) AS items,
       (SELECT count(*) FROM core.evaluation) AS evaluations,
       (SELECT count(*) FROM core.decision) AS decisions,
       (SELECT count(*) FROM core.edit_proposal) AS proposals,
       (SELECT count(*) FROM core.queue) AS queue_entries,
       (SELECT count(*) FROM core.ledger) AS ledger_entries,
       (SELECT count(*) FROM core.restore_drill) AS drills;

\echo == it reads the known sets and the migration record
SELECT (SELECT count(*) FROM core.item_state) AS item_states,
       (SELECT count(*) FROM core.lane) AS lanes,
       (SELECT count(*) FROM core.worker) AS workers,
       (SELECT count(*) FROM core.migration) AS migrations;

\echo == it cannot remove an item or a proposal
DELETE FROM core.item WHERE item_id = 'PA-0001';
DELETE FROM core.edit_proposal WHERE proposal_id = 1;

\echo == it cannot rewrite or remove an evaluation or a decision
UPDATE core.evaluation SET score = 100;
DELETE FROM core.evaluation;
UPDATE core.decision SET outcome = 'reject';
DELETE FROM core.decision;

\echo == it cannot change a known set or the migration record
INSERT INTO core.item_state (state) VALUES ('archived');
DELETE FROM core.lane;
UPDATE core.worker SET stage = 11 WHERE worker = 'trawl';
INSERT INTO core.outcome (outcome, recommendable) VALUES ('split', true);
DELETE FROM core.migration;

\echo == it cannot empty a table or change the schema
TRUNCATE core.queue;
ALTER TABLE core.item ADD COLUMN example text;
DROP TABLE core.queue;
ALTER TABLE core.ledger DISABLE TRIGGER ledger_append_only;
CREATE TABLE core.example (n integer);

\echo == it has no business in pub
SELECT * FROM pub.item;
RESET ROLE;

\echo == the backup role reads everything and writes nothing
SET ROLE backup_ro;
SELECT (SELECT count(*) FROM core.item) AS items,
       (SELECT count(*) FROM core.ledger) AS ledger_entries,
       (SELECT count(*) FROM core.item_state) AS item_states,
       (SELECT count(*) FROM pub.item) AS public_items;
INSERT INTO core.ledger (item_id, to_state) VALUES ('PA-0001', 'observed');
UPDATE core.item SET title = 'Example';
DELETE FROM core.queue;
RESET ROLE;
