-- The rules for core.evaluation, tried as Muster's role.
SET ROLE core_rw;
INSERT INTO core.item (item_id, state, title, source_url, source_hash)
VALUES ('PA-0001', 'observed', 'Example rate calculator', 'https://example.test/tools/one', repeat('a', 64));

\echo == a passed evaluation and a failed one are accepted
INSERT INTO core.evaluation (item_id, gates_passed, score, recommendation, evaluated_at)
VALUES ('PA-0001', true, 82, 'build', '2026-01-05 10:00+00');
INSERT INTO core.evaluation (item_id, gates_passed, reason, evaluated_at)
VALUES ('PA-0001', false, 'Does more than one job.', '2026-01-05 11:00+00');
SELECT evaluation_id, item_id, gates_passed, reason, score, recommendation, evaluated_at FROM core.evaluation ORDER BY evaluation_id;

\echo == each required column
INSERT INTO core.evaluation (item_id, gates_passed, score, recommendation, evaluated_at)
VALUES (NULL, true, 82, 'build', '2026-01-05 10:00+00');
INSERT INTO core.evaluation (item_id, gates_passed, score, recommendation, evaluated_at)
VALUES ('PA-0001', NULL, 82, 'build', '2026-01-05 10:00+00');
INSERT INTO core.evaluation (item_id, gates_passed, score, recommendation, evaluated_at)
VALUES ('PA-0001', true, 82, 'build', NULL);

\echo == when the gates are passed: a score from 20 to 100 and a recommendation
INSERT INTO core.evaluation (item_id, gates_passed, score, recommendation) VALUES ('PA-0001', true, NULL, 'build');
INSERT INTO core.evaluation (item_id, gates_passed, score, recommendation) VALUES ('PA-0001', true, 19, 'reject');
INSERT INTO core.evaluation (item_id, gates_passed, score, recommendation) VALUES ('PA-0001', true, 101, 'build');
INSERT INTO core.evaluation (item_id, gates_passed, score, recommendation) VALUES ('PA-0001', true, 82, NULL);

\echo == the edges of the score are accepted
INSERT INTO core.evaluation (item_id, gates_passed, score, recommendation, evaluated_at)
VALUES ('PA-0001', true, 20, 'reject', '2026-01-05 12:00+00'), ('PA-0001', true, 100, 'link', '2026-01-05 13:00+00');

\echo == a recommendation outside the four is unfamiliar
INSERT INTO core.evaluation (item_id, gates_passed, score, recommendation) VALUES ('PA-0001', true, 82, 'split');
INSERT INTO core.evaluation (item_id, gates_passed, score, recommendation) VALUES ('PA-0001', true, 82, 'merge');
INSERT INTO core.evaluation (item_id, gates_passed, score, recommendation) VALUES ('PA-0001', true, 82, 'override');

\echo == when a gate is failed: a reason, and no score or recommendation
INSERT INTO core.evaluation (item_id, gates_passed) VALUES ('PA-0001', false);
INSERT INTO core.evaluation (item_id, gates_passed, reason) VALUES ('PA-0001', false, '  ');
INSERT INTO core.evaluation (item_id, gates_passed, reason, score) VALUES ('PA-0001', false, 'Needs a server.', 40);
INSERT INTO core.evaluation (item_id, gates_passed, reason, recommendation) VALUES ('PA-0001', false, 'Needs a server.', 'reject');

\echo == an evaluation of an item that is not recorded
INSERT INTO core.evaluation (item_id, gates_passed, score, recommendation) VALUES ('PA-0009', true, 82, 'build');

\echo == what was kept
SELECT evaluation_id, gates_passed, reason, score, recommendation FROM core.evaluation ORDER BY evaluation_id;
