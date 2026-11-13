\set ECHO all
-- Rules for a restore drill: it records when it ran and what each of its four
-- checks found, and it passed only if all four ran and passed.

-- Every combination of the four outcomes, where empty means the check did not run.
INSERT INTO core.restore_drill (ran_at, decrypt_passed, logbook_passed, plainforge_passed, lazarette_passed)
SELECT '2026-01-31 03:00+00', a, b, c, d
FROM unnest(ARRAY[true, false, NULL]) WITH ORDINALITY AS w (a, wn),
     unnest(ARRAY[true, false, NULL]) WITH ORDINALITY AS x (b, xn),
     unnest(ARRAY[true, false, NULL]) WITH ORDINALITY AS y (c, yn),
     unnest(ARRAY[true, false, NULL]) WITH ORDINALITY AS z (d, zn)
ORDER BY wn, xn, yn, zn;

SELECT count(*) AS drills, count(*) FILTER (WHERE passed) AS passed FROM core.restore_drill;
SELECT decrypt_passed, logbook_passed, plainforge_passed, lazarette_passed, passed
FROM core.restore_drill WHERE passed;
SELECT count(*) AS drills_with_an_empty_overall_result FROM core.restore_drill WHERE passed IS NULL;

-- The overall result follows from the four checks; it cannot be set by hand.
INSERT INTO core.restore_drill (ran_at, decrypt_passed, passed) VALUES ('2026-02-28 03:00+00', false, true);

-- A drill says when it ran: E_PARSE.
INSERT INTO core.restore_drill (ran_at, decrypt_passed) VALUES (NULL, true);

-- What the public sees of the latest drill.
INSERT INTO core.restore_drill (ran_at, decrypt_passed, logbook_passed, plainforge_passed, lazarette_passed)
VALUES ('2026-02-28 03:00+00', true, true, false, true);
SET SESSION AUTHORIZATION pub_ro;
SELECT ran_at, passed, decrypt_passed, logbook_passed, plainforge_passed, lazarette_passed
FROM pub.restore_drill ORDER BY ran_at DESC, drill_id DESC LIMIT 1;
