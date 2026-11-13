\i fixtures/sample_record.sql
\set ECHO all
-- Rules for a pause: it names the worker that stopped, the pattern it had no
-- rule for and the state to go back to, and an item has one open pause at most.

-- Every open pause for one worker and pattern, which is what a replay acts on.
SELECT pause_id, item_id, paused_from FROM core.pause
WHERE worker = 'sextant' AND pattern = 'sextant.e-needs-subtool.sample-form-layout' AND replayed_at IS NULL
ORDER BY pause_id;

-- An item that is already paused cannot be paused again.
INSERT INTO core.pause (item_id, worker, pattern, paused_from)
VALUES ('PA-0003', 'sextant', 'sextant.e-needs-subtool.another-layout', 'recorded');

-- Once it has been replayed, it can be.
UPDATE core.pause SET replayed_at = '2026-01-07 12:00+00' WHERE pause_id = 2;
INSERT INTO core.pause (item_id, worker, pattern, paused_from, paused_at)
VALUES ('PA-0003', 'sextant', 'sextant.e-needs-subtool.another-layout', 'recorded', '2026-01-07 13:00+00')
RETURNING pause_id, item_id, replayed_at;

-- The state to go back to is one of the fourteen, and not needs_subtool itself.
INSERT INTO core.pause (item_id, worker, pattern, paused_from) VALUES ('PA-0004', 'assay', 'sample.pattern', NULL);
INSERT INTO core.pause (item_id, worker, pattern, paused_from) VALUES ('PA-0004', 'assay', 'sample.pattern', 'screened-out');
INSERT INTO core.pause (item_id, worker, pattern, paused_from) VALUES ('PA-0004', 'assay', 'sample.pattern', 'waiting');
INSERT INTO core.pause (item_id, worker, pattern, paused_from) VALUES ('PA-0004', 'assay', 'sample.pattern', 'needs_subtool');

-- The worker is a well-formed name and the pattern is real text: E_PARSE.
INSERT INTO core.pause (item_id, worker, pattern, paused_from) VALUES ('PA-0004', NULL, 'sample.pattern', 'observed');
INSERT INTO core.pause (item_id, worker, pattern, paused_from) VALUES ('PA-0004', 'Assay!', 'sample.pattern', 'observed');
INSERT INTO core.pause (item_id, worker, pattern, paused_from) VALUES ('PA-0004', 'assay', NULL, 'observed');
INSERT INTO core.pause (item_id, worker, pattern, paused_from) VALUES ('PA-0004', 'assay', '', 'observed');
INSERT INTO core.pause (item_id, worker, pattern, paused_from) VALUES ('PA-0004', 'assay', repeat('x', 201), 'observed');

-- A replay cannot come before the pause: E_PARSE.
INSERT INTO core.pause (item_id, worker, pattern, paused_from, paused_at, replayed_at)
VALUES ('PA-0004', 'assay', 'sample.pattern', 'observed', '2026-01-08 12:00+00', '2026-01-08 11:00+00');

-- A pause is about an item that exists.
INSERT INTO core.pause (item_id, worker, pattern, paused_from) VALUES ('PA-0999', 'assay', 'sample.pattern', 'observed');
