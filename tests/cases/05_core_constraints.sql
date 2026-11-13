-- The working tables refuse malformed records.
-- 23514 check violation, 23503 foreign key violation, 23502 not null.
\echo == item ids must look like PA-0000
INSERT INTO core.item (item_id, title, state) VALUES ('PA-12', 'short id', 'new');
INSERT INTO core.item (item_id, title, state) VALUES ('pa-0009', 'lower case', 'new');
INSERT INTO core.item (item_id, title, state) VALUES ('PA-00009', 'long id', 'new');
\echo == a new item is not published unless someone says so
BEGIN;
INSERT INTO core.item (item_id, title, state) VALUES ('PA-0009', 'made-up', 'new') RETURNING published;
ROLLBACK;
\echo == records must belong to an item that exists
INSERT INTO core.evaluation (item_id, outcome) VALUES ('PA-9999', 'pass');
INSERT INTO core.decision (item_id, decision) VALUES ('PA-9999', 'accept');
INSERT INTO core.edit_proposal (item_id, payload) VALUES ('PA-9999', '{}');
\echo == a proposal status is pending, approved or rejected, and decided ones carry a time
INSERT INTO core.edit_proposal (item_id, payload, status) VALUES ('PA-0001', '{}', 'maybe');
INSERT INTO core.edit_proposal (item_id, payload, status) VALUES ('PA-0001', '{}', 'approved');
INSERT INTO core.edit_proposal (item_id, payload) VALUES ('PA-0001', NULL);
\echo == a lease has a token and an expiry, or neither
INSERT INTO core.queue_lease (item_id, step, status, lease_token)
VALUES ('PA-0001', 'build', 'leased', '00000000-0000-4000-8000-000000000002');
\echo == a drill cannot finish before it starts
INSERT INTO core.restore_drill (started_at, finished_at) VALUES ('2001-05-01 02:00+00', '2001-05-01 01:00+00');
