-- The rules for core.item, tried as Muster's role.
SET ROLE core_rw;

\echo == a well-formed item is accepted
INSERT INTO core.item (item_id, state, title, source_url, source_hash, created_at, updated_at)
VALUES ('PA-0001', 'recorded', 'Example rate calculator', 'https://example.test/tools/one', repeat('a', 64), '2026-01-05 09:00+00', '2026-01-05 09:00+00');
SELECT item_id, state, title, source_url, source_hash, created_at, updated_at FROM core.item;

\echo == each required column
INSERT INTO core.item (item_id, state, title, source_url, source_hash, created_at, updated_at)
VALUES (NULL, 'recorded', 'Example', 'https://example.test/tools/two', repeat('b', 64), '2026-01-05 09:00+00', '2026-01-05 09:00+00');
INSERT INTO core.item (item_id, state, title, source_url, source_hash, created_at, updated_at)
VALUES ('PA-0002', NULL, 'Example', 'https://example.test/tools/two', repeat('b', 64), '2026-01-05 09:00+00', '2026-01-05 09:00+00');
INSERT INTO core.item (item_id, state, title, source_url, source_hash, created_at, updated_at)
VALUES ('PA-0002', 'recorded', NULL, 'https://example.test/tools/two', repeat('b', 64), '2026-01-05 09:00+00', '2026-01-05 09:00+00');
INSERT INTO core.item (item_id, state, title, source_url, source_hash, created_at, updated_at)
VALUES ('PA-0002', 'recorded', 'Example', NULL, repeat('b', 64), '2026-01-05 09:00+00', '2026-01-05 09:00+00');
INSERT INTO core.item (item_id, state, title, source_url, source_hash, created_at, updated_at)
VALUES ('PA-0002', 'recorded', 'Example', 'https://example.test/tools/two', NULL, '2026-01-05 09:00+00', '2026-01-05 09:00+00');
INSERT INTO core.item (item_id, state, title, source_url, source_hash, created_at, updated_at)
VALUES ('PA-0002', 'recorded', 'Example', 'https://example.test/tools/two', repeat('b', 64), NULL, '2026-01-05 09:00+00');
INSERT INTO core.item (item_id, state, title, source_url, source_hash, created_at, updated_at)
VALUES ('PA-0002', 'recorded', 'Example', 'https://example.test/tools/two', repeat('b', 64), '2026-01-05 09:00+00', NULL);

\echo == the identifier is PA- and four digits
INSERT INTO core.item (item_id, state, title, source_url, source_hash)
VALUES ('PA-002', 'recorded', 'Example', 'https://example.test/tools/two', repeat('b', 64));
INSERT INTO core.item (item_id, state, title, source_url, source_hash)
VALUES ('PA-00002', 'recorded', 'Example', 'https://example.test/tools/two', repeat('b', 64));
INSERT INTO core.item (item_id, state, title, source_url, source_hash)
VALUES ('pa-0002', 'recorded', 'Example', 'https://example.test/tools/two', repeat('b', 64));
INSERT INTO core.item (item_id, state, title, source_url, source_hash)
VALUES ('PA-000X', 'recorded', 'Example', 'https://example.test/tools/two', repeat('b', 64));
INSERT INTO core.item (item_id, state, title, source_url, source_hash)
VALUES (E'PA-0002\n', 'recorded', 'Example', 'https://example.test/tools/two', repeat('b', 64));

\echo == the title and the source address are not blank
INSERT INTO core.item (item_id, state, title, source_url, source_hash)
VALUES ('PA-0002', 'recorded', '   ', 'https://example.test/tools/two', repeat('b', 64));
INSERT INTO core.item (item_id, state, title, source_url, source_hash)
VALUES ('PA-0002', 'recorded', 'Example', '', repeat('b', 64));

\echo == the source hash is 64 lowercase hexadecimal characters
INSERT INTO core.item (item_id, state, title, source_url, source_hash)
VALUES ('PA-0002', 'recorded', 'Example', 'https://example.test/tools/two', repeat('b', 63));
INSERT INTO core.item (item_id, state, title, source_url, source_hash)
VALUES ('PA-0002', 'recorded', 'Example', 'https://example.test/tools/two', repeat('B', 64));

\echo == a state outside the fourteen is unfamiliar, not broken
INSERT INTO core.item (item_id, state, title, source_url, source_hash)
VALUES ('PA-0002', 'archived', 'Example', 'https://example.test/tools/two', repeat('b', 64));

\echo == the rules apply to a change as well
UPDATE core.item SET state = 'archived' WHERE item_id = 'PA-0001';
UPDATE core.item SET title = '' WHERE item_id = 'PA-0001';
UPDATE core.item SET state = 'screened-out', updated_at = '2026-01-06 09:00+00' WHERE item_id = 'PA-0001';

\echo == nothing that was refused was kept
SELECT item_id, state, title, updated_at FROM core.item ORDER BY item_id;

\echo == the same address may be recorded again as a new item
INSERT INTO core.item (item_id, state, title, source_url, source_hash, created_at, updated_at)
VALUES ('PA-0003', 'recorded', 'Example rate calculator', 'https://example.test/tools/one', repeat('a', 64), '2026-01-07 09:00+00', '2026-01-07 09:00+00');
SELECT item_id, state FROM core.item ORDER BY item_id;
