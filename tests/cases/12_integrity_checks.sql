\i fixtures/sample_record.sql
\set ECHO all
-- Rule: core.integrity_check() gives the same fifteen checks in the same order
-- every time, each with the number of things that failed it. A restore drill
-- runs it on the restored copy. All zeros is a pass.

-- The sample record is sound.
SELECT * FROM core.integrity_check();

-- An empty Logbook is sound too.
BEGIN;
SET LOCAL session_replication_role = replica;
DELETE FROM core.ledger;
DELETE FROM core.queue;
DELETE FROM core.pause;
DELETE FROM core.decision;
DELETE FROM core.evaluation;
DELETE FROM core.edit_proposal;
DELETE FROM core.item;
DELETE FROM core.restore_drill;
SELECT count(*) AS checks, sum(failures) AS failures FROM core.integrity_check();
ROLLBACK;

-- Each kind of damage below is done the way a bad restore would do it: with
-- the checks on writing switched off. Each is undone before the next.

-- Rows that the checks on writing would have refused.
BEGIN;
SET LOCAL session_replication_role = replica;
INSERT INTO core.item (item_id, state, title) VALUES ('PA-77', 'recorded', 'Sample');
INSERT INTO core.item (item_id, state, title) VALUES ('PA-0077', 'archived', 'Sample');
UPDATE core.evaluation SET score = 90 WHERE evaluation_id = 1;
UPDATE core.decision SET reason = NULL WHERE decision_id = 2;
UPDATE core.edit_proposal SET edit_class = 'CODE' WHERE proposal_id = 1;
UPDATE core.queue SET leased_until = NULL WHERE queue_id = 3;
UPDATE core.pause SET paused_from = 'needs_subtool' WHERE pause_id = 1;
UPDATE core.ledger SET error_code = 'E_UNKNOWN' WHERE entry_id IN (4, 16, 19);
SELECT * FROM core.integrity_check() WHERE failures > 0;
ROLLBACK;

-- An item moved without a ledger entry, and an item with no ledger at all.
BEGIN;
SET LOCAL session_replication_role = replica;
UPDATE core.item SET state = 'approved' WHERE item_id = 'PA-0004';
INSERT INTO core.item (item_id, state, title) VALUES ('PA-0078', 'recorded', 'Sample item with no history');
SELECT * FROM core.integrity_check() WHERE failures > 0;
ROLLBACK;

-- A ledger entry lost from the middle of an item's trail, and one from the start.
BEGIN;
SET LOCAL session_replication_role = replica;
DELETE FROM core.ledger WHERE entry_id = 6;
DELETE FROM core.ledger WHERE entry_id = 10;
SELECT * FROM core.integrity_check() WHERE failures > 0;
ROLLBACK;

-- The last ledger entry of an item lost.
BEGIN;
SET LOCAL session_replication_role = replica;
DELETE FROM core.ledger WHERE entry_id = 26;
SELECT * FROM core.integrity_check() WHERE failures > 0;
ROLLBACK;

-- A proposal moved without a ledger entry, and an entry lost from a proposal's trail.
BEGIN;
SET LOCAL session_replication_role = replica;
UPDATE core.edit_proposal SET status = 'approved', decided_at = '2026-01-12 09:00+00' WHERE proposal_id = 1;
DELETE FROM core.ledger WHERE entry_id = 29;
SELECT * FROM core.integrity_check() WHERE failures > 0;
ROLLBACK;

-- A pause lost for an item that is waiting, and an open pause on one that is not.
BEGIN;
SET LOCAL session_replication_role = replica;
DELETE FROM core.pause WHERE pause_id = 2;
UPDATE core.pause SET replayed_at = NULL WHERE pause_id = 1;
SELECT * FROM core.integrity_check() WHERE failures > 0;
ROLLBACK;

-- A public view that came back hiding rows.
BEGIN;
CREATE OR REPLACE VIEW pub.item WITH (security_barrier) AS
SELECT i.item_id, i.state, i.title, i.recorded_at,
       (SELECT max(l.recorded_at) FROM core.ledger l WHERE l.item_id = i.item_id) AS changed_at
FROM core.item i
WHERE i.state = 'live';
SELECT * FROM core.integrity_check() WHERE failures > 0;
ROLLBACK;

-- A public view that came back showing the text of unapproved proposals.
BEGIN;
CREATE OR REPLACE VIEW pub.edit_proposal WITH (security_barrier) AS
SELECT p.proposal_id, p.element_id, p.owner_repo, p.edit_class, p.status, p.payload,
       p.submitted_at, p.decided_at
FROM core.edit_proposal p;
SELECT * FROM core.integrity_check() WHERE failures > 0;
ROLLBACK;

-- After all of that, the sample record is as it was.
SELECT sum(failures) AS failures FROM core.integrity_check();
