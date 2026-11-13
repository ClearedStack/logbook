-- The rules for a new entry in core.ledger, tried as Muster's role.
SET ROLE core_rw;
INSERT INTO core.item (item_id, state, title, source_url, source_hash)
VALUES ('PA-0001', 'recorded', 'Example rate calculator', 'https://example.test/tools/one', repeat('a', 64));
INSERT INTO core.edit_proposal (kind, target, payload, status)
VALUES ('DATA', 'catalog/example', 'Text.', 'pending_approval');

\echo == entries about an item and about a proposal are accepted
INSERT INTO core.ledger (item_id, from_state, to_state, worker, recorded_at) VALUES
  ('PA-0001', NULL, 'recorded', 'trawl', '2026-01-05 09:00+00'),
  ('PA-0001', 'recorded', 'observed', 'sextant', '2026-01-05 09:30+00'),
  ('PA-0001', 'observed', 'screened-out', 'assay', '2026-01-05 10:00+00'),
  ('PA-0001', 'screened-out', 'observed', NULL, '2026-01-06 09:00+00');
INSERT INTO core.ledger (proposal_id, from_state, to_state, worker, recorded_at) VALUES
  (1, NULL, 'pending_approval', NULL, '2026-01-07 09:00+00'),
  (1, 'pending_approval', 'declined', 'countersign', '2026-01-07 10:00+00');
SELECT ledger_id, item_id, proposal_id, from_state, to_state, worker, recorded_at FROM core.ledger ORDER BY ledger_id;

\echo == each required column
INSERT INTO core.ledger (item_id, to_state, recorded_at) VALUES ('PA-0001', NULL, '2026-01-08 09:00+00');
INSERT INTO core.ledger (item_id, to_state, recorded_at) VALUES ('PA-0001', 'scored', NULL);

\echo == exactly one item or proposal
INSERT INTO core.ledger (to_state) VALUES ('scored');
INSERT INTO core.ledger (item_id, proposal_id, to_state) VALUES ('PA-0001', 1, 'scored');

\echo == for an item, the states are item states
INSERT INTO core.ledger (item_id, from_state, to_state) VALUES ('PA-0001', 'observed', 'archived');
INSERT INTO core.ledger (item_id, from_state, to_state) VALUES ('PA-0001', 'archived', 'scored');
INSERT INTO core.ledger (item_id, from_state, to_state) VALUES ('PA-0001', 'observed', 'declined');

\echo == for a proposal, the states are proposal statuses
INSERT INTO core.ledger (proposal_id, from_state, to_state) VALUES (1, 'pending_approval', 'accepted');
INSERT INTO core.ledger (proposal_id, from_state, to_state) VALUES (1, 'proposed', 'approved');
INSERT INTO core.ledger (proposal_id, from_state, to_state) VALUES (1, 'pending_approval', 'scored');

\echo == a worker outside the ten is unfamiliar
INSERT INTO core.ledger (item_id, from_state, to_state, worker) VALUES ('PA-0001', 'observed', 'scored', 'lookout');

\echo == an entry about an item or a proposal that is not recorded
INSERT INTO core.ledger (item_id, to_state) VALUES ('PA-0009', 'recorded');
INSERT INTO core.ledger (proposal_id, to_state) VALUES (9, 'pending_approval');

\echo == what was kept
SELECT count(*) AS entries FROM core.ledger;
