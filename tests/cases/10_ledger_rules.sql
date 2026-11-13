\i fixtures/sample_record.sql
\set ECHO all
-- Rules for the ledger: entries are added and never changed or removed, not
-- even by the owner of the database. An entry is about one item or one
-- proposal, and records a move between states that Logbook knows.

-- An entry cannot be changed, removed or swept away.
UPDATE core.ledger SET note = 'Rewritten.' WHERE entry_id = 13;
UPDATE core.ledger SET to_state = 'scored' WHERE entry_id = 13;
DELETE FROM core.ledger WHERE entry_id = 13;
DELETE FROM core.ledger;
TRUNCATE core.ledger;
TRUNCATE core.item CASCADE;
TRUNCATE core.edit_proposal CASCADE;

-- An item or a proposal with a history cannot be removed from under it.
DELETE FROM core.item WHERE item_id = 'PA-0002';
DELETE FROM core.edit_proposal WHERE proposal_id = 3;

-- Every entry is still there, unchanged.
SELECT count(*) AS entries, min(entry_id) AS first, max(entry_id) AS last FROM core.ledger;
SELECT entry_id, item_id, from_state, to_state, note FROM core.ledger WHERE entry_id = 13;

-- Adding is allowed. The three error codes, each accepted on an entry.
INSERT INTO core.ledger (item_id, actor, from_state, to_state, error_code, note, recorded_at)
SELECT 'PA-0005', 'tidegauge', 'parked', 'parked', code, 'Sample failure. Nothing changed.', '2026-01-13 09:00+00'
FROM unnest(core.error_codes()) AS code
RETURNING entry_id, from_state, to_state, error_code;

-- An entry is about one item or one proposal: E_PARSE.
INSERT INTO core.ledger (actor, to_state) VALUES ('muster', 'recorded');
INSERT INTO core.ledger (item_id, proposal_id, actor, to_state) VALUES ('PA-0001', 1, 'muster', 'approved');

-- An item moves between item states, and a proposal between proposal statuses.
-- A status is not a state: unknown is E_NEEDS_SUBTOOL, missing or broken is E_PARSE.
INSERT INTO core.ledger (item_id, actor, from_state, to_state) VALUES ('PA-0005', 'owner', 'parked', 'declined');
INSERT INTO core.ledger (item_id, actor, from_state, to_state) VALUES ('PA-0005', 'owner', 'pending_approval', 'observed');
INSERT INTO core.ledger (proposal_id, actor, from_state, to_state) VALUES (1, 'owner', 'pending_approval', 'scored');
INSERT INTO core.ledger (proposal_id, actor, from_state, to_state) VALUES (1, 'owner', 'recorded', 'approved');
INSERT INTO core.ledger (item_id, actor, from_state, to_state) VALUES ('PA-0005', 'owner', 'parked', NULL);
INSERT INTO core.ledger (item_id, actor, from_state, to_state) VALUES ('PA-0005', 'owner', 'parked', 'screened-out');
INSERT INTO core.ledger (item_id, actor, from_state, to_state) VALUES ('PA-0005', 'owner', 'screened-out', 'observed');

-- The error code is one of three: broken is E_PARSE, unknown is E_NEEDS_SUBTOOL.
INSERT INTO core.ledger (item_id, actor, from_state, to_state, error_code) VALUES ('PA-0005', 'tidegauge', 'parked', 'parked', 'timeout!');
INSERT INTO core.ledger (item_id, actor, from_state, to_state, error_code) VALUES ('PA-0005', 'tidegauge', 'parked', 'parked', 'E_UNKNOWN');
INSERT INTO core.ledger (item_id, actor, from_state, to_state, error_code) VALUES ('PA-0005', 'tidegauge', 'parked', 'parked', 'e_timeout');

-- The actor is a well-formed name, and a note is real text: E_PARSE.
INSERT INTO core.ledger (item_id, actor, from_state, to_state) VALUES ('PA-0005', NULL, 'parked', 'observed');
INSERT INTO core.ledger (item_id, actor, from_state, to_state) VALUES ('PA-0005', 'The Owner', 'parked', 'observed');
INSERT INTO core.ledger (item_id, actor, from_state, to_state, note) VALUES ('PA-0005', 'owner', 'parked', 'observed', '');
INSERT INTO core.ledger (item_id, actor, from_state, to_state, note) VALUES ('PA-0005', 'owner', 'parked', 'observed', repeat('x', 2001));

-- An entry is about an item or a proposal that exists.
INSERT INTO core.ledger (item_id, actor, to_state) VALUES ('PA-0999', 'trawl', 'discovered');
INSERT INTO core.ledger (proposal_id, actor, to_state) VALUES (999, 'muster', 'pending_approval');

-- Only the three accepted entries were added.
SELECT count(*) AS entries, max(entry_id) AS last FROM core.ledger;
