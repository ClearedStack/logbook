-- Logbook migration 0003: the public views (pub schema).
--
-- Each view names its columns one by one, so a column added to a working
-- table later is never published by accident. Every view only shows rows
-- that belong to a published item (or, for drills, a finished drill).
--
-- The views run with their owner's rights, so a reader needs no access to
-- core.* at all. security_barrier stops a reader's own functions or
-- operators from being run against rows the view filters out.
--
-- There is deliberately no public view of core.queue_lease, core.ledger or
-- core.migration.

CREATE VIEW pub.item WITH (security_barrier = true) AS
SELECT i.item_id, i.title, i.summary, i.state, i.updated_at
FROM core.item AS i
WHERE i.published;

CREATE VIEW pub.evaluation WITH (security_barrier = true) AS
SELECT e.item_id, e.outcome, e.evaluated_at
FROM core.evaluation AS e
JOIN core.item AS i ON i.item_id = e.item_id
WHERE i.published;

CREATE VIEW pub.decision WITH (security_barrier = true) AS
SELECT d.item_id, d.decision, d.decided_at
FROM core.decision AS d
JOIN core.item AS i ON i.item_id = d.item_id
WHERE i.published;

-- Approved proposals only. Pending and rejected payloads stay in core.
CREATE VIEW pub.edit_proposal WITH (security_barrier = true) AS
SELECT p.item_id, p.payload, p.decided_at
FROM core.edit_proposal AS p
JOIN core.item AS i ON i.item_id = p.item_id
WHERE i.published
  AND p.status = 'approved';

-- One row per check of each finished restore drill.
CREATE VIEW pub.restore_drill WITH (security_barrier = true) AS
SELECT d.drill_id, d.finished_at, c.check_name, c.passed, c.checked_at
FROM core.restore_drill AS d
JOIN core.restore_drill_check AS c ON c.drill_id = d.drill_id
WHERE d.finished_at IS NOT NULL;
