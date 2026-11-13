-- What the public views show, and what they leave out.

INSERT INTO core.item (item_id, state, title, source_url, source_hash, created_at, updated_at) VALUES
  ('PA-0001', 'scored', 'Example rate calculator', 'https://example.test/tools/one', repeat('a', 64), '2026-01-05 09:00+00', '2026-01-05 10:00+00'),
  ('PA-0002', 'screened-out', 'Example suite', 'https://example.test/tools/two', repeat('b', 64), '2026-01-05 09:10+00', '2026-01-05 11:00+00');

INSERT INTO core.edit_proposal (kind, target, payload, status, submitted_at) VALUES
  ('DATA', 'catalog/example-tool/description', 'PENDING-PAYLOAD', 'pending_approval', '2026-01-07 09:00+00'),
  ('DATA', 'catalog/example-tool/title', 'APPROVED-PAYLOAD', 'approved', '2026-01-07 09:01+00'),
  ('CONFIG', 'assay/example-setting', 'BUILDING-PAYLOAD', 'building', '2026-01-07 09:02+00'),
  ('ISSUE', 'sextant/example-page', 'LIVE-PAYLOAD', 'live', '2026-01-07 09:03+00'),
  ('DATA', 'catalog/example-tool/summary', 'DECLINED-PAYLOAD', 'declined', '2026-01-07 09:04+00');

INSERT INTO core.ledger (item_id, proposal_id, from_state, to_state, worker, recorded_at) VALUES
  ('PA-0001', NULL, NULL, 'recorded', 'trawl', '2026-01-05 09:00+00'),
  ('PA-0001', NULL, 'recorded', 'observed', 'sextant', '2026-01-05 09:30+00'),
  (NULL, 1, NULL, 'pending_approval', NULL, '2026-01-07 09:00+00'),
  ('PA-0001', NULL, 'observed', 'scored', 'assay', '2026-01-05 10:00+00'),
  ('PA-0002', NULL, NULL, 'recorded', 'trawl', '2026-01-05 09:10+00');

INSERT INTO core.evaluation (item_id, gates_passed, reason, score, recommendation, evaluated_at) VALUES
  ('PA-0001', true, NULL, 82, 'build', '2026-01-05 10:00+00'),
  ('PA-0002', false, 'Does more than one job.', NULL, NULL, '2026-01-05 11:00+00');

INSERT INTO core.decision (item_id, outcome, reason, decided_at) VALUES
  ('PA-0001', 'park', 'Waiting for a final rule.', '2026-01-06 09:00+00'),
  ('PA-0002', 'override', 'The gate was applied to the wrong page.', '2026-01-06 09:05+00');

INSERT INTO core.queue (item_id, proposal_id, worker, lane, status, lease_token, lease_expires_at, heartbeat_at, error_code, enqueued_at) VALUES
  ('PA-0001', NULL, 'countersign', 'normal', 'waiting', NULL, NULL, NULL, NULL, '2026-01-05 10:00+00'),
  (NULL, 1, 'countersign', 'normal', 'waiting', NULL, NULL, NULL, NULL, '2026-01-07 09:00+00'),
  ('PA-0002', NULL, 'sextant', 'urgent', 'leased', 'SECRET-LEASE-TOKEN', '2026-01-06 09:10+00', '2026-01-06 09:06+00', NULL, '2026-01-06 09:05+00'),
  ('PA-0002', NULL, 'sextant', 'normal', 'needs_subtool', NULL, NULL, NULL, 'E_NEEDS_SUBTOOL', '2026-01-05 09:10+00');

INSERT INTO core.restore_drill (ran_at, decrypt_passed, database_passed, plainforge_passed, lazarette_passed) VALUES
  ('2026-01-01 03:00+00', true, true, true, true),
  ('2026-02-01 03:00+00', true, true, false, true);

SET ROLE pub_ro;

\echo == pub.item
SELECT * FROM pub.item ORDER BY item_id;

\echo == pub.item_history
SELECT * FROM pub.item_history ORDER BY ledger_id;

\echo == pub.evaluation
SELECT * FROM pub.evaluation ORDER BY evaluation_id;

\echo == pub.decision
SELECT * FROM pub.decision ORDER BY decision_id;

\echo == pub.queue_length
SELECT * FROM pub.queue_length ORDER BY worker, lane, status;

\echo == pub.edit_proposal
SELECT * FROM pub.edit_proposal ORDER BY proposal_id;

\echo == pub.restore_drill
SELECT * FROM pub.restore_drill ORDER BY drill_id;

\echo == a reader cannot filter on a payload that is not shown
SELECT proposal_id FROM pub.edit_proposal WHERE payload LIKE '%PAYLOAD%' ORDER BY proposal_id;
RESET ROLE;

\echo == the columns of every public view
SELECT table_name AS view, string_agg(column_name, ', ' ORDER BY ordinal_position) AS columns
FROM information_schema.columns
WHERE table_schema = 'pub'
GROUP BY table_name
ORDER BY table_name;

\echo == no public view shows a private value
SELECT count(*) AS leaks
FROM (
  SELECT to_jsonb(v)::text AS shown FROM pub.item v
  UNION ALL SELECT to_jsonb(v)::text FROM pub.item_history v
  UNION ALL SELECT to_jsonb(v)::text FROM pub.evaluation v
  UNION ALL SELECT to_jsonb(v)::text FROM pub.decision v
  UNION ALL SELECT to_jsonb(v)::text FROM pub.queue_length v
  UNION ALL SELECT to_jsonb(v)::text FROM pub.edit_proposal v
  UNION ALL SELECT to_jsonb(v)::text FROM pub.restore_drill v
) AS everything
WHERE shown LIKE '%SECRET-LEASE-TOKEN%'
   OR shown LIKE '%PENDING-PAYLOAD%'
   OR shown LIKE '%DECLINED-PAYLOAD%'
   OR shown LIKE '%example.test%'
   OR shown LIKE '%' || repeat('a', 64) || '%';
