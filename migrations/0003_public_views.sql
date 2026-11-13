-- Logbook migration 0003: the public views (the pub schema).
--
-- Each view names its columns one by one. A column added to a working table
-- later stays private until a migration adds it here. The views run with the
-- rights of their owner, so pub_ro reads them without any right on core.
-- security_barrier stops a reader's own filter from running against rows a
-- view leaves out.

BEGIN;

INSERT INTO core.migration (version, name) VALUES (3, 'public_views');

-- Items. Left out: source_url and source_hash.
CREATE VIEW pub.item WITH (security_barrier = true) AS
  SELECT item_id, title, state, created_at, updated_at
  FROM core.item;

-- Each item's history, from the ledger. Left out: entries about proposals.
CREATE VIEW pub.item_history WITH (security_barrier = true) AS
  SELECT ledger_id, item_id, from_state, to_state, worker, recorded_at
  FROM core.ledger
  WHERE item_id IS NOT NULL;

-- Evaluation outcomes.
CREATE VIEW pub.evaluation WITH (security_barrier = true) AS
  SELECT evaluation_id, item_id, gates_passed, reason, score, recommendation, evaluated_at
  FROM core.evaluation;

-- The decision log.
CREATE VIEW pub.decision WITH (security_barrier = true) AS
  SELECT decision_id, item_id, outcome, reason, decided_at
  FROM core.decision;

-- Queue lengths. Left out: every single entry, and with it every lease token.
CREATE VIEW pub.queue_length WITH (security_barrier = true) AS
  SELECT worker, lane, status, count(*) AS entries
  FROM core.queue
  GROUP BY worker, lane, status;

-- Edit proposals and their status. The payload is shown only once the owner
-- has approved it.
CREATE VIEW pub.edit_proposal WITH (security_barrier = true) AS
  SELECT proposal_id, kind, target, status,
         CASE WHEN status IN ('approved', 'building', 'live') THEN payload END AS payload,
         submitted_at
  FROM core.edit_proposal;

-- Restore drills.
CREATE VIEW pub.restore_drill WITH (security_barrier = true) AS
  SELECT drill_id, ran_at, decrypt_passed, database_passed, plainforge_passed,
         lazarette_passed, passed
  FROM core.restore_drill;

-- Conn reads the views and nothing else. The backup job reads them too,
-- because a dump covers the whole database.
GRANT SELECT ON
  pub.item, pub.item_history, pub.evaluation, pub.decision, pub.queue_length,
  pub.edit_proposal, pub.restore_drill
  TO pub_ro, backup_ro;

COMMIT;
