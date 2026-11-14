\i fixtures/sample_record.sql
\set ECHO all
-- Rules for the Contract v1 working records and public health view added in
-- migration 0010: item sources, proposal reasons and file paths, held and
-- future-dated queue steps, worker results, lease outcomes, component health
-- and daily visitor submission counts.

-- 1. Item sources: the four known sources are accepted by Muster; broken ones
-- are E_PARSE and unfamiliar ones are E_NEEDS_SUBTOOL.
SET SESSION AUTHORIZATION muster;

INSERT INTO core.item (state, title, address, source) VALUES
    ('discovered', 'Sample intake item one',   'https://tools.example/src-1', 'sam-gov'),
    ('discovered', 'Sample intake item two',   'https://tools.example/src-2', 'github-issues'),
    ('discovered', 'Sample intake item three', 'https://tools.example/src-3', 'web-sweep'),
    ('discovered', 'Sample intake item four',  'https://tools.example/src-4', 'site-form')
RETURNING item_id, source;

INSERT INTO core.item (state, title, source) VALUES ('discovered', 'Sample', '');
INSERT INTO core.item (state, title, source) VALUES ('discovered', 'Sample', 'SAM GOV');
INSERT INTO core.item (state, title, source) VALUES ('discovered', 'Sample', 'made-up-source');

RESET SESSION AUTHORIZATION;

-- Keep ledger entries for the four new items so the record stays whole.
INSERT INTO core.ledger (item_id, actor, to_state, note, recorded_at) VALUES
    ('PA-0006', 'trawl', 'discovered', 'record', '2026-01-12 10:00+00'),
    ('PA-0007', 'trawl', 'discovered', 'record', '2026-01-12 10:01+00'),
    ('PA-0008', 'trawl', 'discovered', 'record', '2026-01-12 10:02+00'),
    ('PA-0009', 'conn',  'discovered', 'record', '2026-01-12 10:03+00');

-- 2. Edit proposals: reason and file_path are accepted on insert, cannot be
-- rewritten by Muster, and never appear in pub.edit_proposal.
SET SESSION AUTHORIZATION muster;

INSERT INTO core.edit_proposal (element_id, owner_repo, edit_class, payload, reason, file_path, status, submitted_at)
VALUES ('catalog.sample-calculator.description', 'clearedstack.com', 'DATA',
        'Sample change to the description.',
        'Sample private reason for the change.',
        'src/app/platform/[slug]/page.tsx',
        'pending_approval', '2026-01-12 11:00+00')
RETURNING proposal_id, file_path;

UPDATE core.edit_proposal SET reason = 'Rewritten.' WHERE proposal_id = 4;
UPDATE core.edit_proposal SET file_path = 'app.yaml' WHERE proposal_id = 4;

INSERT INTO core.edit_proposal (element_id, owner_repo, edit_class, payload, reason)
VALUES ('pipeline.trawl', 'trawl', 'ISSUE', 'Sample.', '   ');
INSERT INTO core.edit_proposal (element_id, owner_repo, edit_class, payload, file_path)
VALUES ('pipeline.trawl', 'trawl', 'ISSUE', 'Sample.', '/etc/passwd');
INSERT INTO core.edit_proposal (element_id, owner_repo, edit_class, payload, file_path)
VALUES ('pipeline.trawl', 'trawl', 'ISSUE', 'Sample.', '../app.yaml');
INSERT INTO core.edit_proposal (element_id, owner_repo, edit_class, payload, file_path)
VALUES ('pipeline.trawl', 'trawl', 'ISSUE', 'Sample.', 'src/../app.yaml');
INSERT INTO core.edit_proposal (element_id, owner_repo, edit_class, payload, file_path)
VALUES ('pipeline.trawl', 'trawl', 'ISSUE', 'Sample.', 'src//app.yaml');

INSERT INTO core.ledger (proposal_id, actor, to_state, recorded_at)
VALUES (4, 'muster', 'pending_approval', '2026-01-12 11:00+00');

-- Approve proposal 4 so its payload is public while reason and file_path stay private.
UPDATE core.edit_proposal SET status = 'approved', decided_at = '2026-01-12 11:05+00' WHERE proposal_id = 4;
INSERT INTO core.ledger (proposal_id, actor, from_state, to_state, recorded_at)
VALUES (4, 'countersign', 'pending_approval', 'approved', '2026-01-12 11:05+00');

RESET SESSION AUTHORIZATION;

-- Proposal numbering stops at 999999999 (EP-999999999).
BEGIN;
SELECT setval(pg_get_serial_sequence('core.edit_proposal', 'proposal_id'), 999999998);
INSERT INTO core.edit_proposal (element_id, owner_repo, edit_class, payload)
VALUES ('pipeline.trawl', 'trawl', 'ISSUE', 'Sample last proposal.')
RETURNING proposal_id;
SAVEPOINT at_limit;
INSERT INTO core.edit_proposal (element_id, owner_repo, edit_class, payload)
VALUES ('pipeline.trawl', 'trawl', 'ISSUE', 'Sample proposal too many.');
ROLLBACK TO SAVEPOINT at_limit;
ROLLBACK;
SELECT setval(pg_get_serial_sequence('core.edit_proposal', 'proposal_id'), 4);

-- 3. Queue depth: future-scheduled checks and stopped steps are not counted as
-- waiting or claimed.
SET SESSION AUTHORIZATION muster;

BEGIN;
INSERT INTO core.queue (worker, lane, item_id, queued_at)
VALUES ('waybill', 'normal', 'PA-0006', '2999-01-01 00:00+00');
INSERT INTO core.queue (worker, lane, item_id, queued_at, held)
VALUES ('moldloft', 'normal', 'PA-0007', '2026-01-12 10:00+00', true);
INSERT INTO core.queue (worker, lane, item_id, queued_at, lease_token, leased_until)
VALUES ('shakedown', 'normal', 'PA-0008', '2026-01-12 10:00+00',
        'ffffffff-ffff-ffff-ffff-ffffffffffff', 'infinity');
SAVEPOINT valid_queue_rows;
INSERT INTO core.queue (worker, lane, held, lease_token, leased_until)
VALUES ('sextant', 'normal', true, '00000000-0000-4000-8000-000000000010', '2999-01-01 00:00+00');
ROLLBACK TO SAVEPOINT valid_queue_rows;
RESET SESSION AUTHORIZATION;
SELECT worker, lane, waiting, claimed FROM pub.queue_depth
WHERE worker IN ('waybill', 'moldloft', 'shakedown')
ORDER BY worker;
ROLLBACK;

-- 4. Worker results: one JSON object up to 256 KiB per subject and worker.
SET SESSION AUTHORIZATION muster;

INSERT INTO core.result (item_id, worker, payload, recorded_at)
VALUES ('PA-0001', 'sextant', '{"job": "sample private observation"}', '2026-01-05 10:00+00')
RETURNING item_id, worker, payload;

UPDATE core.result SET payload = '{"job": "updated sample private observation"}', recorded_at = '2026-01-05 10:05+00'
WHERE item_id = 'PA-0001' AND worker = 'sextant'
RETURNING worker, payload;

INSERT INTO core.result (proposal_id, worker, payload, recorded_at)
VALUES (4, 'countersign', '{"note": "sample owner note"}', '2026-01-12 11:05+00')
RETURNING proposal_id, worker;

INSERT INTO core.result (item_id, worker, payload) VALUES ('PA-0001', 'sextant', '{"job": "duplicate"}');
DELETE FROM core.result WHERE worker = 'sextant';
UPDATE core.result SET worker = 'assay' WHERE worker = 'sextant';
INSERT INTO core.result (item_id, worker, payload) VALUES ('PA-0002', 'sextant', '[1, 2]');
INSERT INTO core.result (item_id, proposal_id, worker, payload) VALUES ('PA-0002', 4, 'sextant', '{}');
INSERT INTO core.result (worker, payload) VALUES ('sextant', '{}');
INSERT INTO core.result (item_id, worker, payload)
VALUES ('PA-0002', 'waybill', jsonb_build_object('spec', repeat('x', 262145)));

-- 5. Lease outcomes: remember how the last lease on each subject ended.
INSERT INTO core.lease_outcome (item_id, is_incident, lease, worker, call_name, call_arg, ack_state, ack_next, recorded_at)
VALUES ('PA-0001', false, 'PA-0001.1.1', 'sextant', 'complete', 'observed', 'observed', 'assay', '2026-01-05 10:00+00')
RETURNING lease, call_name, ack_state, ack_next;

INSERT INTO core.lease_outcome (item_id, is_incident, lease, worker, call_name, call_arg, ack_state, recorded_at)
VALUES ('PA-0001', true, 'incident:PA-0001.2.1', 'bellbuoy', 'complete', 'observed', 'observed', '2026-01-05 10:01+00')
RETURNING lease, is_incident;

INSERT INTO core.lease_outcome (item_id, is_incident, lease, worker, call_name, call_arg, ack_state, ack_held, recorded_at)
VALUES ('PA-0002', false, 'PA-0002.3.1', 'sextant', 'fail', 'E_PARSE', 'screened_out', true, '2026-01-06 12:05+00')
RETURNING lease, call_arg, ack_held;

INSERT INTO core.lease_outcome (item_id, is_incident, lease, worker, call_name, ack_state, recorded_at)
VALUES ('PA-0003', false, 'PA-0003.4.1', 'sextant', 'needs_subtool', 'needs_subtool', '2026-01-07 10:00+00')
RETURNING lease, call_name, ack_state;

INSERT INTO core.lease_outcome (proposal_id, lease, worker, call_name, call_arg, ack_state, ack_next, recorded_at)
VALUES (4, 'EP-0004.5.1', 'countersign', 'complete', 'approved', 'approved', 'bellbuoy', '2026-01-12 11:05+00')
RETURNING lease, ack_state, ack_next;

INSERT INTO core.lease_outcome (item_id, lease, worker, call_name, call_arg, ack_state)
VALUES ('PA-0004', 'PA-0001.1.1', 'sextant', 'complete', 'observed', 'observed');
INSERT INTO core.lease_outcome (item_id, lease, worker, call_name, call_arg, ack_state)
VALUES ('PA-0004', 'PA-0004.0.1', 'sextant', 'complete', 'observed', 'observed');
INSERT INTO core.lease_outcome (proposal_id, is_incident, lease, worker, call_name, call_arg, ack_state)
VALUES (1, true, 'incident:EP-0001.1.1', 'bellbuoy', 'complete', 'approved', 'approved');
INSERT INTO core.lease_outcome (item_id, lease, worker, call_name, call_arg, ack_state)
VALUES ('PA-0004', 'PA-0004.1.1', 'sextant', 'fail', 'E_NEEDS_SUBTOOL', 'scored');
INSERT INTO core.lease_outcome (item_id, lease, worker, call_name, call_arg, ack_state)
VALUES ('PA-0004', 'PA-0004.1.1', 'sextant', 'needs_subtool', 'needs_subtool', 'needs_subtool');
INSERT INTO core.lease_outcome (item_id, lease, worker, call_name, call_arg, ack_state, ack_next, ack_held)
VALUES ('PA-0004', 'PA-0004.1.1', 'sextant', 'fail', 'E_PARSE', 'scored', 'assay', true);
INSERT INTO core.lease_outcome (item_id, lease, worker, call_name, call_arg, ack_state)
VALUES ('PA-0004', 'PA-0004.1.1', 'sextant', 'abandon', 'scored', 'scored');

-- 6. Component health: four known states, optional public code and sha256 digest.
INSERT INTO core.component_health (component, state, error_code, digest, reported_at) VALUES
    ('sextant', 'healthy',  NULL,        'sha256:' || repeat('a', 64), '2026-01-12 12:00+00'),
    ('logbook', 'idle',     NULL,        NULL,                         '2026-01-12 12:00+00'),
    ('assay',   'degraded', 'E_TIMEOUT', 'sha256:' || repeat('b', 64), '2026-01-12 12:00+00'),
    ('trawl',   'paused',   NULL,        NULL,                         '2026-01-12 12:00+00')
RETURNING component, state, error_code;

UPDATE core.component_health
SET digest = 'sha256:' || repeat('c', 64), reported_at = '2026-01-12 12:05+00'
WHERE component = 'sextant'
RETURNING component, left(digest, 15) AS digest_prefix;

DELETE FROM core.component_health WHERE component = 'trawl';
INSERT INTO core.component_health (component, state) VALUES ('muster', 'erroring');
INSERT INTO core.component_health (component, state, digest) VALUES ('muster', 'healthy', 'sha256:short');
INSERT INTO core.component_health (component, state, digest) VALUES ('muster', 'healthy', 'sha256:' || repeat('A', 64));

-- 7. Daily submission counts: 64-digit lower-case hex hash and positive count.
INSERT INTO core.submission_count (submission_day, visitor_key, submissions)
VALUES ('2026-01-12', repeat('d', 64), 1)
RETURNING submission_day, submissions;

UPDATE core.submission_count SET submissions = submissions + 1
WHERE submission_day = '2026-01-12' AND visitor_key = repeat('d', 64)
RETURNING submissions;

INSERT INTO core.submission_count (submission_day, visitor_key, submissions)
VALUES ('2026-01-12', '203.0.113.7', 1);
INSERT INTO core.submission_count (submission_day, visitor_key, submissions)
VALUES ('2026-01-12', repeat('D', 64), 1);
INSERT INTO core.submission_count (submission_day, visitor_key, submissions)
VALUES ('2026-01-12', repeat('e', 64), 0);

-- 8. Public surface: pub_ro sees pub.component_health without digests, and none
-- of the new internal values appears anywhere in pub.
SET SESSION AUTHORIZATION pub_ro;

SELECT component, state, error_code, reported_at FROM pub.component_health ORDER BY component;
SELECT count(*) FROM core.result;
SELECT count(*) FROM core.lease_outcome;
SELECT count(*) FROM core.component_health;
SELECT count(*) FROM core.submission_count;

RESET SESSION AUTHORIZATION;

CREATE TEMPORARY TABLE all_published AS
SELECT to_jsonb(v)::text AS line FROM pub.item v
UNION ALL SELECT to_jsonb(v)::text FROM pub.item_history v
UNION ALL SELECT to_jsonb(v)::text FROM pub.evaluation v
UNION ALL SELECT to_jsonb(v)::text FROM pub.evaluation_gate v
UNION ALL SELECT to_jsonb(v)::text FROM pub.evaluation_factor v
UNION ALL SELECT to_jsonb(v)::text FROM pub.decision v
UNION ALL SELECT to_jsonb(v)::text FROM pub.queue_depth v
UNION ALL SELECT to_jsonb(v)::text FROM pub.pause v
UNION ALL SELECT to_jsonb(v)::text FROM pub.edit_proposal v
UNION ALL SELECT to_jsonb(v)::text FROM pub.restore_drill v
UNION ALL SELECT to_jsonb(v)::text FROM pub.component_health v;

SELECT count(*) AS leaked_internal_values
FROM all_published p
JOIN (
    SELECT source AS val FROM core.item WHERE source IS NOT NULL
    UNION ALL SELECT reason FROM core.edit_proposal WHERE reason IS NOT NULL
    UNION ALL SELECT file_path FROM core.edit_proposal WHERE file_path IS NOT NULL
    UNION ALL SELECT payload::text FROM core.result
    UNION ALL SELECT lease FROM core.lease_outcome
    UNION ALL SELECT digest FROM core.component_health WHERE digest IS NOT NULL
    UNION ALL SELECT visitor_key FROM core.submission_count
) secret ON position(secret.val IN p.line) > 0;

-- 9. Integrity checks: zero failures now, and damage to each new table or view is caught.
SELECT sum(failures) AS failures FROM core.integrity_check();

BEGIN;
SET LOCAL session_replication_role = replica;
UPDATE core.result SET payload = '[1]' WHERE result_id = 1;
UPDATE core.lease_outcome SET lease = 'wrong' WHERE outcome_id = 1;
UPDATE core.component_health SET state = 'erroring' WHERE component = 'assay';
UPDATE core.submission_count SET visitor_key = '203.0.113.7' WHERE submissions = 2;
CREATE OR REPLACE VIEW pub.component_health WITH (security_barrier) AS
SELECT h.component, h.state, h.error_code, h.reported_at
FROM core.component_health h
WHERE h.state = 'healthy';
SELECT * FROM core.integrity_check() WHERE failures > 0;
ROLLBACK;

SELECT sum(failures) AS failures_after_rollback FROM core.integrity_check();
