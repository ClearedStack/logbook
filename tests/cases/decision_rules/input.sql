-- The rules for core.decision, tried as Muster's role.
SET ROLE core_rw;
INSERT INTO core.item (item_id, state, title, source_url, source_hash)
VALUES ('PA-0001', 'scored', 'Example rate calculator', 'https://example.test/tools/one', repeat('a', 64));

\echo == every outcome is accepted
INSERT INTO core.decision (item_id, outcome, reason, decided_at) VALUES
  ('PA-0001', 'build', '', '2026-01-06 09:00+00'),
  ('PA-0001', 'link', 'A free, private tool already does this.', '2026-01-06 09:01+00'),
  ('PA-0001', 'merge', 'Belongs inside PA-0002.', '2026-01-06 09:02+00'),
  ('PA-0001', 'park', 'Waiting for a final rule.', '2026-01-06 09:03+00'),
  ('PA-0001', 'reject', 'Below the threshold.', '2026-01-06 09:04+00'),
  ('PA-0001', 'override', 'The gate was applied to the wrong page.', '2026-01-06 09:05+00');
SELECT decision_id, item_id, outcome, reason, decided_at FROM core.decision ORDER BY decision_id;

\echo == each required column
INSERT INTO core.decision (item_id, outcome, reason, decided_at) VALUES (NULL, 'build', '', '2026-01-06 10:00+00');
INSERT INTO core.decision (item_id, outcome, reason, decided_at) VALUES ('PA-0001', NULL, '', '2026-01-06 10:00+00');
INSERT INTO core.decision (item_id, outcome, reason, decided_at) VALUES ('PA-0001', 'build', NULL, '2026-01-06 10:00+00');
INSERT INTO core.decision (item_id, outcome, reason, decided_at) VALUES ('PA-0001', 'build', '', NULL);

\echo == an outcome outside the six is unfamiliar
INSERT INTO core.decision (item_id, outcome) VALUES ('PA-0001', 'split');

\echo == an override needs a written reason
INSERT INTO core.decision (item_id, outcome) VALUES ('PA-0001', 'override');
INSERT INTO core.decision (item_id, outcome, reason) VALUES ('PA-0001', 'override', '   ');

\echo == a decision about an item that is not recorded
INSERT INTO core.decision (item_id, outcome) VALUES ('PA-0009', 'build');

\echo == what was kept
SELECT count(*) AS decisions FROM core.decision;
