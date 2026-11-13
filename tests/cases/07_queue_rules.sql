\i fixtures/sample_record.sql
\set ECHO all
-- Rules for the queue: work is for a named worker, in one of three lanes, and
-- a lease is whole or absent. Work is taken urgent first, then normal, then
-- backfill, and within a lane in the order it arrived.

-- The order in which tidegauge's work is taken, whatever order it arrived in.
SELECT queue_id, lane, lane_rank, queued_at FROM core.queue
WHERE worker = 'tidegauge'
ORDER BY lane_rank, queue_id;

-- The lane decides the rank; it cannot be set by hand.
INSERT INTO core.queue (worker, lane, lane_rank) VALUES ('tidegauge', 'backfill', 1);

-- The three lanes, each accepted.
BEGIN;
INSERT INTO core.queue (worker, lane) SELECT 'sextant', lane FROM unnest(core.lanes()) AS lane
RETURNING lane, lane_rank;
ROLLBACK;

-- A lane is one of three: missing or broken is E_PARSE, unknown is E_NEEDS_SUBTOOL.
INSERT INTO core.queue (worker, lane) VALUES ('sextant', NULL);
INSERT INTO core.queue (worker, lane) VALUES ('sextant', 'very urgent');
INSERT INTO core.queue (worker, lane) VALUES ('sextant', 'express');

-- The worker is a well-formed name: E_PARSE.
INSERT INTO core.queue (worker, lane) VALUES (NULL, 'normal');
INSERT INTO core.queue (worker, lane) VALUES ('Sextant', 'normal');
INSERT INTO core.queue (worker, lane) VALUES ('sextant worker', 'normal');
INSERT INTO core.queue (worker, lane) VALUES (repeat('a', 101), 'normal');

-- Work is about an item, a proposal or neither, never both: E_PARSE.
INSERT INTO core.queue (worker, lane, item_id, proposal_id) VALUES ('bellbuoy', 'urgent', 'PA-0001', 2);
INSERT INTO core.queue (worker, lane, proposal_id) VALUES ('bellbuoy', 'urgent', 2) RETURNING queue_id, proposal_id;

-- A lease has a token and an end time together, and a heartbeat needs a lease: E_PARSE.
INSERT INTO core.queue (worker, lane, lease_token) VALUES ('sextant', 'normal', '00000000-0000-4000-8000-000000000009');
INSERT INTO core.queue (worker, lane, leased_until) VALUES ('sextant', 'normal', '2999-01-01 00:00+00');
INSERT INTO core.queue (worker, lane, heartbeat_at) VALUES ('sextant', 'normal', '2026-01-11 00:00+00');
UPDATE core.queue SET lease_token = NULL WHERE queue_id = 3;
INSERT INTO core.queue (worker, lane, attempt) VALUES ('sextant', 'normal', -1);
INSERT INTO core.queue (worker, lane, attempt) VALUES ('sextant', 'normal', NULL);

-- Releasing a lease clears all of it.
UPDATE core.queue SET lease_token = NULL, leased_until = NULL, heartbeat_at = NULL WHERE queue_id = 3
RETURNING queue_id, lease_token, leased_until, heartbeat_at;

-- Work is about an item or a proposal that exists.
INSERT INTO core.queue (worker, lane, item_id) VALUES ('sextant', 'normal', 'PA-0999');
INSERT INTO core.queue (worker, lane, proposal_id) VALUES ('bellbuoy', 'urgent', 999);
