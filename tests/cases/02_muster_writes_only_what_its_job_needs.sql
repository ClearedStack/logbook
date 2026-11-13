\i fixtures/sample_record.sql
\set ECHO all
-- Rule: Muster reads every working table and writes each one only in the way
-- its job needs. It cannot read the public views, delete an item, change an
-- identifier, rewrite a proposal, or change a row of a trail.

SET SESSION AUTHORIZATION muster;

-- One piece of work, start to finish, in one transaction: claim it, record the
-- decision, move the item, write the ledger entry, take the work off the queue.
BEGIN;
UPDATE core.queue
SET lease_token = '00000000-0000-4000-8000-000000000003', leased_until = '2999-01-01 00:00+00', attempt = attempt + 1
WHERE queue_id = 1;
INSERT INTO core.decision (evaluation_id, outcome, reason, decided_at)
VALUES (3, 'reject', 'Too close to the sample planner.', '2026-01-12 09:00+00');
UPDATE core.item SET state = 'rejected' WHERE item_id = 'PA-0004';
INSERT INTO core.ledger (item_id, actor, from_state, to_state, note, recorded_at)
VALUES ('PA-0004', 'owner', 'scored', 'rejected', 'Too close to the sample planner.', '2026-01-12 09:00+00');
DELETE FROM core.queue WHERE queue_id = 1;
COMMIT;
SELECT item_id, state FROM core.item WHERE item_id = 'PA-0004';
SELECT count(*) AS queued_for_countersign FROM core.queue WHERE worker = 'countersign';

-- A new item is given the next identifier.
INSERT INTO core.item (state, title, recorded_at)
VALUES ('discovered', 'Sample date counter', '2026-01-12 10:00+00')
RETURNING item_id;

-- It can replay a pause and move a proposal on.
UPDATE core.pause SET replayed_at = '2026-01-12 11:00+00' WHERE pause_id = 2 RETURNING item_id, replayed_at;
UPDATE core.edit_proposal SET status = 'approved', decided_at = '2026-01-12 12:00+00'
WHERE proposal_id = 1 RETURNING proposal_id, status;

-- It cannot delete an item or change its identifier.
DELETE FROM core.item WHERE item_id = 'PA-0005';
UPDATE core.item SET item_id = 'PA-0099' WHERE item_id = 'PA-0005';

-- It cannot rewrite a proposal, or remove one.
UPDATE core.edit_proposal SET payload = 'Something else.' WHERE proposal_id = 1;
DELETE FROM core.edit_proposal WHERE proposal_id = 3;

-- It cannot change or remove a row of a trail.
UPDATE core.ledger SET note = 'Rewritten.' WHERE entry_id = 1;
DELETE FROM core.ledger WHERE entry_id = 1;
TRUNCATE core.ledger;
UPDATE core.evaluation SET score = 100 WHERE evaluation_id = 1;
DELETE FROM core.evaluation WHERE evaluation_id = 2;
UPDATE core.decision SET outcome = 'build' WHERE decision_id = 2;
DELETE FROM core.decision WHERE decision_id = 2;
UPDATE core.restore_drill SET logbook_passed = true WHERE drill_id = 2;
DELETE FROM core.restore_drill WHERE drill_id = 2;
DELETE FROM core.pause WHERE pause_id = 1;

-- It cannot move queued work to another worker or lane.
UPDATE core.queue SET lane = 'urgent' WHERE queue_id = 5;
UPDATE core.queue SET worker = 'sextant' WHERE queue_id = 5;

-- It cannot touch the record of migrations, the public views or the checks
-- that read them, and it cannot change the schema.
INSERT INTO core.migration (version, checksum) VALUES ('9999_made_up', repeat('0', 64));
SELECT count(*) FROM pub.item;
SELECT * FROM core.integrity_check();
CREATE TABLE core.scratch (note text);
ALTER TABLE core.ledger DISABLE TRIGGER append_only;
DROP TABLE core.queue;
SET ROLE pub_ro;

RESET SESSION AUTHORIZATION;

-- Every privilege Muster holds on a whole table or view, anywhere.
SELECT n.nspname AS schema, c.relname AS name, string_agg(p.privilege, ', ' ORDER BY p.position) AS whole_table
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
CROSS JOIN (VALUES (1, 'SELECT'), (2, 'INSERT'), (3, 'UPDATE'), (4, 'DELETE'),
                   (5, 'TRUNCATE'), (6, 'REFERENCES'), (7, 'TRIGGER')) AS p (position, privilege)
WHERE n.nspname IN ('core', 'pub', 'public') AND c.relkind IN ('r', 'p', 'v', 'm')
  AND has_table_privilege('muster', c.oid, p.privilege)
GROUP BY 1, 2
ORDER BY 1, 2;

-- Every column Muster may update without holding UPDATE on the whole table.
SELECT c.relname AS name, string_agg(a.attname, ', ' ORDER BY a.attnum) AS columns_it_may_update
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
WHERE n.nspname IN ('core', 'pub', 'public') AND c.relkind IN ('r', 'p', 'v', 'm')
  AND NOT has_table_privilege('muster', c.oid, 'UPDATE')
  AND has_column_privilege('muster', c.oid, a.attnum, 'UPDATE')
GROUP BY 1
ORDER BY 1;

-- Columns Muster may insert, read or reference without holding that on the whole table: none.
SELECT c.relname, a.attname
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
WHERE n.nspname IN ('core', 'pub', 'public') AND c.relkind IN ('r', 'p', 'v', 'm')
  AND ((has_column_privilege('muster', c.oid, a.attnum, 'SELECT') AND NOT has_table_privilege('muster', c.oid, 'SELECT'))
    OR (has_column_privilege('muster', c.oid, a.attnum, 'INSERT') AND NOT has_table_privilege('muster', c.oid, 'INSERT'))
    OR (has_column_privilege('muster', c.oid, a.attnum, 'REFERENCES') AND NOT has_table_privilege('muster', c.oid, 'REFERENCES')))
ORDER BY 1, 2;

-- Functions in core that Muster cannot call: the integrity check and its two helpers.
SELECT p.oid::regprocedure AS not_callable
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'core' AND NOT has_function_privilege('muster', p.oid, 'EXECUTE')
ORDER BY 1;

SELECT has_schema_privilege('muster', 'core', 'USAGE')    AS use_core,
       has_schema_privilege('muster', 'core', 'CREATE')   AS create_in_core,
       has_schema_privilege('muster', 'pub', 'USAGE')     AS use_pub,
       has_schema_privilege('muster', 'public', 'USAGE')  AS use_public,
       has_database_privilege('muster', current_database(), 'CONNECT')   AS connect,
       has_database_privilege('muster', current_database(), 'CREATE')    AS create_schema,
       has_database_privilege('muster', current_database(), 'TEMPORARY') AS temporary_tables;

-- Nobody else is given anything: no grant to PUBLIC on the database, a schema,
-- a table, a view or a function of Logbook's.
SELECT has_database_privilege('public', current_database(), 'CONNECT') AS anyone_may_connect;
SELECT count(*) AS grants_to_everyone
FROM (
    SELECT (aclexplode(c.relacl)).grantee FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname IN ('core', 'pub', 'public')
    UNION ALL
    SELECT (aclexplode(p.proacl)).grantee FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname IN ('core', 'pub', 'public')
    UNION ALL
    SELECT (aclexplode(n.nspacl)).grantee FROM pg_namespace n WHERE n.nspname IN ('core', 'pub', 'public')
) granted
WHERE grantee = 0;
SELECT count(*) AS functions_open_by_default
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname IN ('core', 'pub') AND p.proacl IS NULL;
