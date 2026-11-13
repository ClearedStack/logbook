-- Made-up records used by every test case. Nothing here is real.
-- PA-0001 is published; PA-0002 is not and must never show in pub.*.

INSERT INTO core.item (item_id, title, summary, state, published, created_at, updated_at) VALUES
    ('PA-0001', 'Lighthouse keeper rota', 'A made-up published item.', 'built', true,
     '2001-01-01 09:00+00', '2001-01-05 09:00+00'),
    ('PA-0002', 'Unpublished kite survey', 'A made-up internal item.', 'screening', false,
     '2001-02-01 09:00+00', '2001-02-02 09:00+00');

INSERT INTO core.evaluation (item_id, outcome, detail, evaluated_at) VALUES
    ('PA-0001', 'pass', '{"internal_note": "made-up note A"}', '2001-01-02 09:00+00'),
    ('PA-0002', 'fail', '{"internal_note": "made-up note B"}', '2001-02-02 09:00+00');

INSERT INTO core.decision (item_id, decision, reason, decided_at) VALUES
    ('PA-0001', 'accept', 'made-up internal reason A', '2001-01-03 09:00+00'),
    ('PA-0002', 'hold',   'made-up internal reason B', '2001-02-02 10:00+00');

INSERT INTO core.queue_lease (item_id, step, status, lease_token, leased_until) VALUES
    ('PA-0001', 'build',  'leased', '00000000-0000-4000-8000-000000000001', '2001-01-04 09:00+00'),
    ('PA-0002', 'screen', 'needs_subtool', NULL, NULL);

INSERT INTO core.edit_proposal (item_id, payload, status, submitted_at, decided_at) VALUES
    ('PA-0001', '{"summary": "approved made-up edit"}', 'approved', '2001-01-04 09:00+00', '2001-01-05 09:00+00'),
    ('PA-0001', '{"summary": "pending made-up edit"}',  'pending',  '2001-01-06 09:00+00', NULL),
    ('PA-0001', '{"summary": "rejected made-up edit"}', 'rejected', '2001-01-06 10:00+00', '2001-01-07 09:00+00'),
    ('PA-0002', '{"summary": "approved edit to an unpublished item"}', 'approved', '2001-02-02 11:00+00', '2001-02-03 09:00+00');

INSERT INTO core.ledger (recorded_at, item_id, kind, body) VALUES
    ('2001-01-01 09:00+00', 'PA-0001', 'item_created', '{"n": 1}'),
    ('2001-02-01 09:00+00', 'PA-0002', 'item_created', '{"n": 2}');

-- Drill 1 finished; drill 2 is still running and must not show in pub.*.
INSERT INTO core.restore_drill (started_at, finished_at) VALUES
    ('2001-03-01 02:00+00', '2001-03-01 02:30+00'),
    ('2001-04-01 02:00+00', NULL);

INSERT INTO core.restore_drill_check (drill_id, check_name, passed, checked_at) VALUES
    (1, 'example_check_a', true,  '2001-03-01 02:10+00'),
    (1, 'example_check_b', false, '2001-03-01 02:20+00'),
    (2, 'example_check_a', true,  '2001-04-01 02:10+00');
