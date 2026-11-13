-- The rules for core.restore_drill, tried as Muster's role.
SET ROLE core_rw;

\echo == a drill passes only when all four checks pass
INSERT INTO core.restore_drill (ran_at, decrypt_passed, database_passed, plainforge_passed, lazarette_passed) VALUES
  ('2026-01-01 03:00+00', true, true, true, true),
  ('2026-02-01 03:00+00', false, true, true, true),
  ('2026-03-01 03:00+00', true, false, true, true),
  ('2026-04-01 03:00+00', true, true, false, true),
  ('2026-05-01 03:00+00', true, true, true, false),
  ('2026-06-01 03:00+00', false, false, false, false);
SELECT drill_id, ran_at, decrypt_passed, database_passed, plainforge_passed, lazarette_passed, passed
FROM core.restore_drill ORDER BY drill_id;

\echo == each required column
INSERT INTO core.restore_drill (ran_at, decrypt_passed, database_passed, plainforge_passed, lazarette_passed) VALUES (NULL, true, true, true, true);
INSERT INTO core.restore_drill (ran_at, decrypt_passed, database_passed, plainforge_passed, lazarette_passed) VALUES ('2026-07-01 03:00+00', NULL, true, true, true);
INSERT INTO core.restore_drill (ran_at, decrypt_passed, database_passed, plainforge_passed, lazarette_passed) VALUES ('2026-07-01 03:00+00', true, NULL, true, true);
INSERT INTO core.restore_drill (ran_at, decrypt_passed, database_passed, plainforge_passed, lazarette_passed) VALUES ('2026-07-01 03:00+00', true, true, NULL, true);
INSERT INTO core.restore_drill (ran_at, decrypt_passed, database_passed, plainforge_passed, lazarette_passed) VALUES ('2026-07-01 03:00+00', true, true, true, NULL);
INSERT INTO core.restore_drill (decrypt_passed, database_passed, plainforge_passed, lazarette_passed) VALUES (true, true, true, true);

\echo == the overall result cannot be set by hand
INSERT INTO core.restore_drill (ran_at, decrypt_passed, database_passed, plainforge_passed, lazarette_passed, passed)
VALUES ('2026-07-01 03:00+00', false, true, true, true, true);

\echo == a recorded drill cannot be rewritten or removed
UPDATE core.restore_drill SET decrypt_passed = true WHERE drill_id = 2;
DELETE FROM core.restore_drill WHERE drill_id = 2;

\echo == what was kept
SELECT count(*) AS drills, count(*) FILTER (WHERE passed) AS passed FROM core.restore_drill;
