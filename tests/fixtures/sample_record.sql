-- A small made-up record for the saved examples: five items, their
-- evaluations and decisions, three proposals, some queued work and three
-- restore drills. Every title, address, reason and date here is invented.
-- Identifiers are given out in the order of the rows, starting from 1.

INSERT INTO core.item (state, title, address, recorded_at) VALUES
    ('live',          'Sample page-count planner', 'https://tools.example/page-count',  '2026-01-05 09:00+00'),
    ('screened_out',  'Sample all-in-one suite',   'https://tools.example/suite',       '2026-01-06 09:00+00'),
    ('needs_subtool', 'Sample form reader',        'https://tools.example/form-reader', '2026-01-07 09:00+00'),
    ('scored',        'Sample threshold lookup',   'https://tools.example/thresholds',  '2026-01-08 09:00+00'),
    ('parked',        'Sample table checker',      NULL,                                '2026-01-09 09:00+00');

INSERT INTO core.evaluation (item_id, profile, gates, factors, score, recommendation, evaluated_at) VALUES
    ('PA-0001', 'sample-profile',
     '{"public_source": {"passed": true}, "runs_in_browser": {"passed": true}, "private_by_design": {"passed": true},
       "one_job": {"passed": true}, "arithmetic_not_advice": {"passed": true}}',
     '{"need": {"rating": 5, "weight": 4}, "gap": {"rating": 4, "weight": 4}, "source": {"rating": 5, "weight": 3},
       "browser_fit": {"rating": 4, "weight": 3}, "size": {"rating": 4, "weight": 2},
       "checkable": {"rating": 5, "weight": 2}, "upkeep": {"rating": 4, "weight": 2}}',
     89, 'build', '2026-01-05 13:00+00'),
    ('PA-0002', 'sample-profile',
     '{"public_source": {"passed": true}, "runs_in_browser": {"passed": true}, "private_by_design": {"passed": true},
       "one_job": {"passed": false, "reason": "It does several jobs, not one."}, "arithmetic_not_advice": {"passed": true}}',
     '{}', NULL, NULL, '2026-01-06 12:00+00'),
    ('PA-0004', 'sample-profile',
     '{"public_source": {"passed": true}, "runs_in_browser": {"passed": true}, "private_by_design": {"passed": true},
       "one_job": {"passed": true}, "arithmetic_not_advice": {"passed": true}}',
     '{"need": {"rating": 4, "weight": 4}, "gap": {"rating": 3, "weight": 4}, "source": {"rating": 4, "weight": 3},
       "browser_fit": {"rating": 3, "weight": 3}, "size": {"rating": 3, "weight": 2},
       "checkable": {"rating": 3, "weight": 2}, "upkeep": {"rating": 3, "weight": 2}}',
     67, 'park', '2026-01-08 12:00+00'),
    ('PA-0005', 'sample-profile',
     '{"public_source": {"passed": true}, "runs_in_browser": {"passed": true}, "private_by_design": {"passed": true},
       "one_job": {"passed": true}, "arithmetic_not_advice": {"passed": true}}',
     '{"need": {"rating": 5, "weight": 4}, "gap": {"rating": 5, "weight": 4}, "source": {"rating": 4, "weight": 3},
       "browser_fit": {"rating": 4, "weight": 3}, "size": {"rating": 3, "weight": 2},
       "checkable": {"rating": 4, "weight": 2}, "upkeep": {"rating": 3, "weight": 2}}',
     84, 'build', '2026-01-09 12:00+00');

INSERT INTO core.decision (evaluation_id, outcome, reason, decided_at) VALUES
    (1, 'build', NULL, '2026-01-05 14:00+00'),
    (4, 'park', 'Held until the sample rule it rests on is final.', '2026-01-09 14:00+00');

INSERT INTO core.edit_proposal (element_id, owner_repo, edit_class, payload, status, submitted_at, decided_at) VALUES
    ('pipeline.sextant', 'sextant', 'ISSUE',
     'The sample form layout is not read.', 'pending_approval', '2026-01-10 08:00+00', NULL),
    ('command.hero.mission', 'clearedstack.com', 'DATA',
     'Make the sample sentence shorter.', 'live', '2026-01-10 09:00+00', '2026-01-10 10:00+00'),
    ('worker.assay.role', 'assay', 'CONFIG',
     'Set the sample weight to nine.', 'declined', '2026-01-10 11:00+00', '2026-01-10 12:00+00');

INSERT INTO core.pause (item_id, worker, pattern, paused_from, paused_at, replayed_at) VALUES
    ('PA-0001', 'assay', 'assay.e-needs-subtool.no-sample-profile', 'observed',
     '2026-01-05 11:00+00', '2026-01-05 12:00+00'),
    ('PA-0003', 'sextant', 'sextant.e-needs-subtool.sample-form-layout', 'recorded',
     '2026-01-07 10:00+00', NULL);

INSERT INTO core.queue (worker, lane, item_id, queued_at, attempt, lease_token, leased_until, heartbeat_at) VALUES
    ('countersign', 'normal',   'PA-0004', '2026-01-08 12:00+00', 0, NULL, NULL, NULL),
    ('tidegauge',   'backfill', NULL,      '2026-01-11 01:00+00', 1,
     '00000000-0000-4000-8000-000000000001', '2026-01-11 01:05+00', '2026-01-11 01:01+00'),
    ('tidegauge',   'normal',   NULL,      '2026-01-11 02:00+00', 0,
     '00000000-0000-4000-8000-000000000002', '2999-01-01 00:00+00', '2026-01-11 02:01+00'),
    ('tidegauge',   'urgent',   'PA-0001', '2026-01-11 03:00+00', 0, NULL, NULL, NULL),
    ('tidegauge',   'normal',   NULL,      '2026-01-11 04:00+00', 0, NULL, NULL, NULL);

INSERT INTO core.ledger (item_id, actor, from_state, to_state, error_code, note, recorded_at) VALUES
    ('PA-0001', 'trawl',     NULL,            'discovered',    NULL, NULL, '2026-01-05 09:00+00'),
    ('PA-0001', 'trawl',     'discovered',    'recorded',      NULL, NULL, '2026-01-05 09:01+00'),
    ('PA-0001', 'sextant',   'recorded',      'observed',      NULL, NULL, '2026-01-05 10:00+00'),
    ('PA-0001', 'assay',     'observed',      'needs_subtool', 'E_NEEDS_SUBTOOL',
     'No profile for this kind of tool.', '2026-01-05 11:00+00'),
    ('PA-0001', 'muster',    'needs_subtool', 'observed',      NULL,
     'Run again after the rule shipped.', '2026-01-05 12:00+00'),
    ('PA-0001', 'assay',     'observed',      'scored',        NULL, NULL, '2026-01-05 13:00+00'),
    ('PA-0001', 'owner',     'scored',        'approved',      NULL, NULL, '2026-01-05 14:00+00'),
    ('PA-0001', 'moldloft',  'approved',      'building',      NULL, NULL, '2026-01-05 15:00+00'),
    ('PA-0001', 'chartroom', 'building',      'live',          NULL, NULL, '2026-01-05 16:00+00'),
    ('PA-0002', 'trawl',     NULL,            'discovered',    NULL, NULL, '2026-01-06 09:00+00'),
    ('PA-0002', 'trawl',     'discovered',    'recorded',      NULL, NULL, '2026-01-06 09:01+00'),
    ('PA-0002', 'sextant',   'recorded',      'observed',      NULL, NULL, '2026-01-06 10:00+00'),
    ('PA-0002', 'assay',     'observed',      'screened_out',  NULL,
     'Failed the one-job gate.', '2026-01-06 12:00+00'),
    ('PA-0003', 'trawl',     NULL,            'discovered',    NULL, NULL, '2026-01-07 09:00+00'),
    ('PA-0003', 'trawl',     'discovered',    'recorded',      NULL, NULL, '2026-01-07 09:01+00'),
    ('PA-0003', 'sextant',   'recorded',      'needs_subtool', 'E_NEEDS_SUBTOOL',
     'No rule for this page layout.', '2026-01-07 10:00+00'),
    ('PA-0004', 'trawl',     NULL,            'discovered',    NULL, NULL, '2026-01-08 09:00+00'),
    ('PA-0004', 'trawl',     'discovered',    'recorded',      NULL, NULL, '2026-01-08 09:01+00'),
    ('PA-0004', 'sextant',   'recorded',      'recorded',      'E_TIMEOUT',
     'The public page took too long. Still queued.', '2026-01-08 10:00+00'),
    ('PA-0004', 'sextant',   'recorded',      'observed',      NULL, NULL, '2026-01-08 11:00+00'),
    ('PA-0004', 'assay',     'observed',      'scored',        NULL, NULL, '2026-01-08 12:00+00'),
    ('PA-0005', 'trawl',     NULL,            'discovered',    NULL, NULL, '2026-01-09 09:00+00'),
    ('PA-0005', 'trawl',     'discovered',    'recorded',      NULL, NULL, '2026-01-09 09:01+00'),
    ('PA-0005', 'sextant',   'recorded',      'observed',      NULL, NULL, '2026-01-09 10:00+00'),
    ('PA-0005', 'assay',     'observed',      'scored',        NULL, NULL, '2026-01-09 12:00+00'),
    ('PA-0005', 'owner',     'scored',        'parked',        NULL,
     'Held until the sample rule it rests on is final.', '2026-01-09 14:00+00');

INSERT INTO core.ledger (proposal_id, actor, from_state, to_state, note, recorded_at) VALUES
    (1, 'muster',     NULL,               'pending_approval', NULL, '2026-01-10 08:00+00'),
    (2, 'muster',     NULL,               'pending_approval', NULL, '2026-01-10 09:00+00'),
    (2, 'owner',      'pending_approval', 'approved',         NULL, '2026-01-10 10:00+00'),
    (2, 'bellbuoy',   'approved',         'building',         NULL, '2026-01-10 10:05+00'),
    (2, 'shipkeeper', 'building',         'live',             NULL, '2026-01-10 10:30+00'),
    (3, 'muster',     NULL,               'pending_approval', NULL, '2026-01-10 11:00+00'),
    (3, 'owner',      'pending_approval', 'declined',
     'The sample weight stays as it is.', '2026-01-10 12:00+00');

INSERT INTO core.restore_drill (ran_at, decrypt_passed, logbook_passed, plainforge_passed, lazarette_passed) VALUES
    ('2026-01-31 03:00+00', true,  true,  true,  true),
    ('2026-02-28 03:00+00', true,  false, true,  true),
    ('2026-03-31 03:00+00', false, NULL,  NULL,  NULL);
