\i fixtures/sample_record.sql
\set ECHO all
-- Rules for an evaluation: a result for each gate; if every gate passed, a
-- rating and a weight for each factor, a score that is their weighted sum and
-- a recommendation; if a gate failed, a reason and nothing else.

-- A reusable pair of made-up results.
\set gates_passed '{"sample_gate_a": {"passed": true}, "sample_gate_b": {"passed": true}}'
\set gates_failed '{"sample_gate_a": {"passed": true}, "sample_gate_b": {"passed": false, "reason": "Sample reason."}}'
\set factors '{"sample_factor_a": {"rating": 5, "weight": 4}, "sample_factor_b": {"rating": 2, "weight": 3}}'

-- Accepted: scored, and screened out.
INSERT INTO core.evaluation (item_id, profile, gates, factors, score, recommendation, split_flag)
VALUES ('PA-0004', 'sample-profile', :'gates_passed', :'factors', 26, 'reject', true)
RETURNING evaluation_id, score, recommendation, split_flag;
INSERT INTO core.evaluation (item_id, profile, gates)
VALUES ('PA-0004', 'sample-profile', :'gates_failed')
RETURNING evaluation_id, score, recommendation, split_flag;

-- The score must be the sum of each rating times its weight: E_PARSE.
INSERT INTO core.evaluation (item_id, profile, gates, factors, score, recommendation)
VALUES ('PA-0004', 'sample-profile', :'gates_passed', :'factors', 27, 'reject');
INSERT INTO core.evaluation (item_id, profile, gates, factors, score, recommendation)
VALUES ('PA-0004', 'sample-profile', :'gates_passed', :'factors', NULL, 'reject');

-- A recommendation is one of four: missing is E_PARSE, unknown is E_NEEDS_SUBTOOL.
INSERT INTO core.evaluation (item_id, profile, gates, factors, score, recommendation)
VALUES ('PA-0004', 'sample-profile', :'gates_passed', :'factors', 26, NULL);
INSERT INTO core.evaluation (item_id, profile, gates, factors, score, recommendation)
VALUES ('PA-0004', 'sample-profile', :'gates_passed', :'factors', 26, 'merge');

-- A rating is a whole number from 1 to 5, and a weight one from 1 to 100: E_PARSE.
INSERT INTO core.evaluation (item_id, profile, gates, factors, score, recommendation)
VALUES ('PA-0004', 'sample-profile', :'gates_passed', '{"sample_factor_a": {"rating": 6, "weight": 4}}', 24, 'reject');
INSERT INTO core.evaluation (item_id, profile, gates, factors, score, recommendation)
VALUES ('PA-0004', 'sample-profile', :'gates_passed', '{"sample_factor_a": {"rating": 0, "weight": 4}}', 0, 'reject');
INSERT INTO core.evaluation (item_id, profile, gates, factors, score, recommendation)
VALUES ('PA-0004', 'sample-profile', :'gates_passed', '{"sample_factor_a": {"rating": 2.5, "weight": 4}}', 10, 'reject');
INSERT INTO core.evaluation (item_id, profile, gates, factors, score, recommendation)
VALUES ('PA-0004', 'sample-profile', :'gates_passed', '{"sample_factor_a": {"rating": 5, "weight": 0}}', 0, 'reject');
INSERT INTO core.evaluation (item_id, profile, gates, factors, score, recommendation)
VALUES ('PA-0004', 'sample-profile', :'gates_passed', '{"sample_factor_a": {"rating": 4, "weight": 1.5}}', 6, 'reject');

-- A factor holds a rating and a weight, as numbers, and nothing else: E_PARSE.
INSERT INTO core.evaluation (item_id, profile, gates, factors, score, recommendation)
VALUES ('PA-0004', 'sample-profile', :'gates_passed', '{"sample_factor_a": {"rating": "5", "weight": 4}}', 20, 'reject');
INSERT INTO core.evaluation (item_id, profile, gates, factors, score, recommendation)
VALUES ('PA-0004', 'sample-profile', :'gates_passed', '{"sample_factor_a": {"rating": 5}}', 5, 'reject');
INSERT INTO core.evaluation (item_id, profile, gates, factors, score, recommendation)
VALUES ('PA-0004', 'sample-profile', :'gates_passed', '{"sample_factor_a": {"rating": 5, "weight": 4, "note": "x"}}', 20, 'reject');
INSERT INTO core.evaluation (item_id, profile, gates, factors, score, recommendation)
VALUES ('PA-0004', 'sample-profile', :'gates_passed', '{"sample_factor_a": 5}', 5, 'reject');
INSERT INTO core.evaluation (item_id, profile, gates, factors, score, recommendation)
VALUES ('PA-0004', 'sample-profile', :'gates_passed', '{"Sample Factor": {"rating": 5, "weight": 4}}', 20, 'reject');
INSERT INTO core.evaluation (item_id, profile, gates, factors, score, recommendation)
VALUES ('PA-0004', 'sample-profile', :'gates_passed', '[]', 0, 'reject');

-- An evaluation that passed every gate needs its factors: E_PARSE.
INSERT INTO core.evaluation (item_id, profile, gates, factors, score, recommendation)
VALUES ('PA-0004', 'sample-profile', :'gates_passed', '{}', 0, 'reject');

-- The gates must be there, each with passed as true or false: E_PARSE.
INSERT INTO core.evaluation (item_id, profile, gates) VALUES ('PA-0004', 'sample-profile', '{}');
INSERT INTO core.evaluation (item_id, profile, gates) VALUES ('PA-0004', 'sample-profile', '[true, true]');
INSERT INTO core.evaluation (item_id, profile, gates) VALUES ('PA-0004', 'sample-profile', NULL);
INSERT INTO core.evaluation (item_id, profile, gates) VALUES ('PA-0004', 'sample-profile', '{"sample_gate_a": true}');
INSERT INTO core.evaluation (item_id, profile, gates) VALUES ('PA-0004', 'sample-profile', '{"sample_gate_a": {"passed": "yes"}}');
INSERT INTO core.evaluation (item_id, profile, gates) VALUES ('PA-0004', 'sample-profile', '{"sample_gate_a": {"reason": "Sample."}}');
INSERT INTO core.evaluation (item_id, profile, gates) VALUES ('PA-0004', 'sample-profile', '{"sample_gate_a": {"passed": false, "reason": 7}}');
INSERT INTO core.evaluation (item_id, profile, gates) VALUES ('PA-0004', 'sample-profile', '{"sample_gate_a": {"passed": true, "score": 3}}');
INSERT INTO core.evaluation (item_id, profile, gates) VALUES ('PA-0004', 'sample-profile', '{"sample gate": {"passed": true}}');

-- A failed gate needs its reason: E_PARSE.
INSERT INTO core.evaluation (item_id, profile, gates) VALUES ('PA-0004', 'sample-profile', '{"sample_gate_a": {"passed": false}}');
INSERT INTO core.evaluation (item_id, profile, gates) VALUES ('PA-0004', 'sample-profile', '{"sample_gate_a": {"passed": false, "reason": " "}}');

-- Failing a gate ends the evaluation, so nothing else may be recorded: E_PARSE.
INSERT INTO core.evaluation (item_id, profile, gates, factors)
VALUES ('PA-0004', 'sample-profile', :'gates_failed', :'factors');
INSERT INTO core.evaluation (item_id, profile, gates, score)
VALUES ('PA-0004', 'sample-profile', :'gates_failed', 26);
INSERT INTO core.evaluation (item_id, profile, gates, recommendation)
VALUES ('PA-0004', 'sample-profile', :'gates_failed', 'reject');
INSERT INTO core.evaluation (item_id, profile, gates, split_flag)
VALUES ('PA-0004', 'sample-profile', :'gates_failed', true);

-- The profile is a well-formed name: E_PARSE.
INSERT INTO core.evaluation (item_id, profile, gates) VALUES ('PA-0004', NULL, :'gates_failed');
INSERT INTO core.evaluation (item_id, profile, gates) VALUES ('PA-0004', 'Sample Profile', :'gates_failed');

-- An evaluation is about an item that exists.
INSERT INTO core.evaluation (item_id, profile, gates) VALUES ('PA-0999', 'sample-profile', :'gates_failed');

-- Only the two accepted at the top were kept.
SELECT count(*) AS evaluations FROM core.evaluation;
