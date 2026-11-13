\i fixtures/sample_record.sql
\set ECHO all
-- Rules for an item: an identifier such as PA-0001 or PA-10000, one of the fourteen
-- states, a title, and an address no other item has.

-- The fourteen states, each accepted.
BEGIN;
INSERT INTO core.item (state, title)
SELECT state, 'Sample item in state ' || state FROM unnest(core.item_states()) AS state
RETURNING item_id, state;
ROLLBACK;

-- A broken identifier is refused: E_PARSE.
INSERT INTO core.item (item_id, state, title) VALUES ('PA-12', 'recorded', 'Sample');
INSERT INTO core.item (item_id, state, title) VALUES ('PA-1234567890', 'recorded', 'Sample');
INSERT INTO core.item (item_id, state, title) VALUES ('PA-00012', 'recorded', 'Sample');
INSERT INTO core.item (item_id, state, title) VALUES ('pa-0012', 'recorded', 'Sample');
INSERT INTO core.item (item_id, state, title) VALUES ('PA-001X', 'recorded', 'Sample');
INSERT INTO core.item (item_id, state, title) VALUES (NULL, 'recorded', 'Sample');

-- A missing or broken state is refused: E_PARSE.
INSERT INTO core.item (state, title) VALUES (NULL, 'Sample');
INSERT INTO core.item (state, title) VALUES ('', 'Sample');
INSERT INTO core.item (state, title) VALUES ('screened-out', 'Sample');
INSERT INTO core.item (state, title) VALUES ('live; DROP TABLE core.item', 'Sample');

-- A well-formed state Logbook does not know is refused: E_NEEDS_SUBTOOL.
INSERT INTO core.item (state, title) VALUES ('archived', 'Sample');
INSERT INTO core.item (state, title) VALUES ('Live', 'Sample');
UPDATE core.item SET state = 'paused' WHERE item_id = 'PA-0001';

-- A missing, blank, overlong or damaged title is refused: E_PARSE.
INSERT INTO core.item (state, title) VALUES ('recorded', NULL);
INSERT INTO core.item (state, title) VALUES ('recorded', '   ');
INSERT INTO core.item (state, title) VALUES ('recorded', repeat('x', 201));
INSERT INTO core.item (state, title) VALUES ('recorded', 'Sample' || chr(7));
INSERT INTO core.item (state, title, address) VALUES ('recorded', 'Sample', ' ');

-- A refusal never repeats the value it refused.
INSERT INTO core.item (state, title) VALUES ('made_up_secret_value', 'Sample');

-- The hash is taken from the address, and is the same on every machine.
SELECT item_id, address, address_sha256 FROM core.item ORDER BY item_id;
INSERT INTO core.item (state, title, address, address_sha256)
VALUES ('recorded', 'Sample', 'https://tools.example/other', repeat('0', 64));

-- An address that is already recorded cannot be recorded again.
INSERT INTO core.item (state, title, address)
VALUES ('discovered', 'Sample page-count planner, seen again', 'https://tools.example/page-count');

-- Nothing above was kept.
SELECT count(*) AS items FROM core.item;

-- A refused or abandoned insert still uses up its number, so identifiers can
-- have gaps. They stop at PA-999999999: Logbook refuses to go past that, and
-- does not invent a longer identifier.
SELECT setval('core.item_number', 999999998);
INSERT INTO core.item (state, title) VALUES ('discovered', 'Sample last item') RETURNING item_id;
INSERT INTO core.item (state, title) VALUES ('discovered', 'Sample item too many');
