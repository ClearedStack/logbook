-- The rules for core.edit_proposal, tried as Muster's role.
SET ROLE core_rw;

\echo == each kind of edit is accepted
INSERT INTO core.edit_proposal (kind, target, payload, status, submitted_at) VALUES
  ('DATA', 'catalog/example-tool/description', 'Say "rate" instead of "price".', 'pending_approval', '2026-01-07 09:00+00'),
  ('CONFIG', 'assay/example-setting', 'Raise the example weight by one.', 'pending_approval', '2026-01-07 09:01+00'),
  ('ISSUE', 'sextant/example-page', 'The example table is not read.', 'pending_approval', '2026-01-07 09:02+00');
SELECT proposal_id, kind, target, payload, status, submitted_at FROM core.edit_proposal ORDER BY proposal_id;

\echo == each required column
INSERT INTO core.edit_proposal (kind, target, payload, status, submitted_at) VALUES (NULL, 'catalog/example', 'Text.', 'pending_approval', '2026-01-07 10:00+00');
INSERT INTO core.edit_proposal (kind, target, payload, status, submitted_at) VALUES ('DATA', NULL, 'Text.', 'pending_approval', '2026-01-07 10:00+00');
INSERT INTO core.edit_proposal (kind, target, payload, status, submitted_at) VALUES ('DATA', 'catalog/example', NULL, 'pending_approval', '2026-01-07 10:00+00');
INSERT INTO core.edit_proposal (kind, target, payload, status, submitted_at) VALUES ('DATA', 'catalog/example', 'Text.', NULL, '2026-01-07 10:00+00');
INSERT INTO core.edit_proposal (kind, target, payload, status, submitted_at) VALUES ('DATA', 'catalog/example', 'Text.', 'pending_approval', NULL);

\echo == the target is not blank
INSERT INTO core.edit_proposal (kind, target, payload, status) VALUES ('DATA', ' ', 'Text.', 'pending_approval');

\echo == the payload is at most 4096 bytes: 4096 is accepted, 4097 is not
INSERT INTO core.edit_proposal (kind, target, payload, status, submitted_at)
VALUES ('DATA', 'catalog/example', repeat('x', 4096), 'pending_approval', '2026-01-07 11:00+00');
INSERT INTO core.edit_proposal (kind, target, payload, status)
VALUES ('DATA', 'catalog/example', repeat('x', 4097), 'pending_approval');

\echo == bytes are counted, not characters: 2048 two-byte letters fit, 2049 do not
INSERT INTO core.edit_proposal (kind, target, payload, status, submitted_at)
VALUES ('DATA', 'catalog/example', repeat('é', 2048), 'pending_approval', '2026-01-07 11:01+00');
INSERT INTO core.edit_proposal (kind, target, payload, status)
VALUES ('DATA', 'catalog/example', repeat('é', 2049), 'pending_approval');

\echo == a kind or a status outside the known ones is unfamiliar
INSERT INTO core.edit_proposal (kind, target, payload, status) VALUES ('CODE', 'catalog/example', 'Text.', 'pending_approval');
INSERT INTO core.edit_proposal (kind, target, payload, status) VALUES ('data', 'catalog/example', 'Text.', 'pending_approval');
INSERT INTO core.edit_proposal (kind, target, payload, status) VALUES ('DATA', 'catalog/example', 'Text.', 'proposed');

\echo == the status moves, and the rules apply to the change
UPDATE core.edit_proposal SET status = 'approved' WHERE proposal_id = 1;
UPDATE core.edit_proposal SET status = 'declined' WHERE proposal_id = 2;
UPDATE core.edit_proposal SET status = 'merged' WHERE proposal_id = 3;
UPDATE core.edit_proposal SET payload = repeat('x', 5000) WHERE proposal_id = 3;

\echo == what was kept
SELECT proposal_id, kind, status, octet_length(payload) AS bytes FROM core.edit_proposal ORDER BY proposal_id;
