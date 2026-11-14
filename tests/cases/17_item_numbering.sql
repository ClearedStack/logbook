\set ECHO all
-- Rule: Logbook gives out every item identifier. Numbers up to 9999 are
-- written with four digits and larger ones with no leading zero, up to
-- PA-999999999. Muster cannot supply an identifier.

-- Muster adds three items across the old limit and is given each identifier.
SELECT setval('core.item_number', 9998);
SET SESSION AUTHORIZATION muster;
INSERT INTO core.item (state, title) VALUES ('discovered', 'Sample item, the last with four digits') RETURNING item_id;
INSERT INTO core.item (state, title) VALUES ('discovered', 'Sample item, the first with five digits') RETURNING item_id;
INSERT INTO core.item (state, title, address) VALUES ('discovered', 'Sample item after that', 'https://tools.example/after')
RETURNING item_id;

-- Muster supplying an identifier is refused, whether or not it is well-formed.
INSERT INTO core.item (item_id, state, title) VALUES ('PA-20000', 'discovered', 'Sample');
INSERT INTO core.item (item_id, state, title) VALUES ('PA-0001', 'discovered', 'Sample');
INSERT INTO core.item (item_id, state, title) VALUES (DEFAULT, 'discovered', 'Sample');
-- So is supplying the time it was recorded, or the hash of its address.
INSERT INTO core.item (state, title, recorded_at) VALUES ('discovered', 'Sample', '2026-01-12 10:00+00');
INSERT INTO core.item (state, title, address_sha256) VALUES ('discovered', 'Sample', repeat('0', 64));
-- It cannot move the numbering either.
SELECT setval('core.item_number', 1);
RESET SESSION AUTHORIZATION;

-- A number has one form. A second spelling of it is refused: E_PARSE.
INSERT INTO core.item (item_id, state, title) VALUES ('PA-00001', 'recorded', 'Sample');
INSERT INTO core.item (item_id, state, title) VALUES ('PA-010000', 'recorded', 'Sample');
INSERT INTO core.item (item_id, state, title) VALUES ('PA-000000001', 'recorded', 'Sample');
-- The one spelling of each is accepted from the owner of the database.
INSERT INTO core.item (item_id, state, title) VALUES ('PA-0001', 'recorded', 'Sample item one') RETURNING item_id;
INSERT INTO core.item (item_id, state, title) VALUES ('PA-0000', 'recorded', 'Sample item zero') RETURNING item_id;

-- What the numbering gives for the numbers around each change of width.
SELECT n AS number, 'PA-' || lpad(n::text, greatest(4, length(n::text)), '0') AS identifier,
       ('PA-' || lpad(n::text, greatest(4, length(n::text)), '0')) ~ '^PA-([0-9]{4}|[1-9][0-9]{4,8})$' AS accepted
FROM unnest(ARRAY[1, 9, 10, 999, 1000, 9999, 10000, 99999, 100000, 999999999]) AS n;

-- The numbers run to PA-999999999 and stop there. Logbook refuses to go past
-- it, and does not invent a longer identifier.
SELECT setval('core.item_number', 999999998);
INSERT INTO core.item (state, title) VALUES ('discovered', 'Sample last item') RETURNING item_id;
INSERT INTO core.item (state, title) VALUES ('discovered', 'Sample item too many');

-- Everything that was kept, and every kept row is well-formed.
SELECT item_id, title FROM core.item ORDER BY length(item_id), item_id;
SELECT core.malformed_rows('item') AS malformed_items;

-- pub_ro cannot call the function that gives out identifiers.
SET SESSION AUTHORIZATION pub_ro;
SELECT core.next_item_id();
