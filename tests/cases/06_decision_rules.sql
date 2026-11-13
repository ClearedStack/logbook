\i fixtures/sample_record.sql
\set ECHO all
-- Rules for a decision: one of six outcomes, about a recorded evaluation, with
-- a written reason whenever it is not what the evaluation recommended.
--
-- In the sample record evaluation 1 recommends build, evaluation 2 failed a
-- gate and recommends nothing, and evaluation 3 recommends park.

-- Following the recommendation needs no reason.
INSERT INTO core.decision (evaluation_id, outcome) VALUES (3, 'park') RETURNING decision_id, outcome, reason;

-- Overriding it needs one: E_PARSE without, accepted with.
INSERT INTO core.decision (evaluation_id, outcome) VALUES (3, 'build');
INSERT INTO core.decision (evaluation_id, outcome, reason) VALUES (3, 'build', '  ');
INSERT INTO core.decision (evaluation_id, outcome, reason) VALUES (3, 'build', 'The sample blocker has cleared.')
RETURNING decision_id, outcome, reason;

-- Merge and reopen are never what an evaluation recommends, so they always need a reason.
INSERT INTO core.decision (evaluation_id, outcome) VALUES (1, 'merge');
INSERT INTO core.decision (evaluation_id, outcome, reason) VALUES (1, 'merge', 'It belongs inside the sample planner.')
RETURNING decision_id, outcome, reason;

-- Reopening a screened-out item is an override, so it needs a reason too.
INSERT INTO core.decision (evaluation_id, outcome) VALUES (2, 'reopen');
INSERT INTO core.decision (evaluation_id, outcome, reason) VALUES (2, 'reopen', 'The idea was split into one job.')
RETURNING decision_id, outcome, reason;

-- The outcome is one of six: missing or broken is E_PARSE, unknown is E_NEEDS_SUBTOOL.
INSERT INTO core.decision (evaluation_id, outcome, reason) VALUES (1, NULL, 'Sample.');
INSERT INTO core.decision (evaluation_id, outcome, reason) VALUES (1, 'screened-out', 'Sample.');
INSERT INTO core.decision (evaluation_id, outcome, reason) VALUES (1, 'postpone', 'Sample.');

-- A decision is about an evaluation that exists: E_PARSE.
INSERT INTO core.decision (evaluation_id, outcome) VALUES (999, 'build');
INSERT INTO core.decision (evaluation_id, outcome) VALUES (NULL, 'build');

-- A reason, when given, is real text of a sensible length: E_PARSE.
INSERT INTO core.decision (evaluation_id, outcome, reason) VALUES (1, 'build', '');
INSERT INTO core.decision (evaluation_id, outcome, reason) VALUES (1, 'build', repeat('x', 2001));

-- The decision log, as the public sees it.
SELECT decision_id, item_id, recommendation, outcome, overridden, reason FROM pub.decision ORDER BY decision_id;
