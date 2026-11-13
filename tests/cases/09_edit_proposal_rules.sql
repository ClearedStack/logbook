\i fixtures/sample_record.sql
\set ECHO all
-- Rules for an edit proposal: it names an element and the repository that owns
-- it, is one of three kinds, is at most 4096 bytes, and has one of five
-- statuses. Its text is published only once the owner has approved it.

-- A new proposal waits for the owner.
INSERT INTO core.edit_proposal (element_id, owner_repo, edit_class, payload, submitted_at)
VALUES ('pipeline.trawl', 'trawl', 'ISSUE', 'A sample source is missing.', '2026-01-12 08:00+00')
RETURNING proposal_id, status, decided_at;

-- The three kinds, each accepted.
BEGIN;
INSERT INTO core.edit_proposal (element_id, owner_repo, edit_class, payload)
SELECT 'pipeline.trawl', 'trawl', edit_class, 'Sample.' FROM unnest(core.edit_classes()) AS edit_class
RETURNING edit_class;
ROLLBACK;

-- The kind is one of three: missing or broken is E_PARSE, unknown is E_NEEDS_SUBTOOL.
INSERT INTO core.edit_proposal (element_id, owner_repo, edit_class, payload) VALUES ('pipeline.trawl', 'trawl', NULL, 'Sample.');
INSERT INTO core.edit_proposal (element_id, owner_repo, edit_class, payload) VALUES ('pipeline.trawl', 'trawl', 'DATA+CONFIG', 'Sample.');
INSERT INTO core.edit_proposal (element_id, owner_repo, edit_class, payload) VALUES ('pipeline.trawl', 'trawl', 'CODE', 'Sample.');
INSERT INTO core.edit_proposal (element_id, owner_repo, edit_class, payload) VALUES ('pipeline.trawl', 'trawl', 'data', 'Sample.');

-- Exactly 4096 bytes is accepted. One byte more is refused: E_PARSE.
-- Bytes are counted, not characters: 2048 two-byte letters fit, 2049 do not.
INSERT INTO core.edit_proposal (element_id, owner_repo, edit_class, payload)
VALUES ('pipeline.trawl', 'trawl', 'DATA', repeat('x', 4096))
RETURNING proposal_id, octet_length(payload) AS bytes;
INSERT INTO core.edit_proposal (element_id, owner_repo, edit_class, payload)
VALUES ('pipeline.trawl', 'trawl', 'DATA', repeat('x', 4097));
INSERT INTO core.edit_proposal (element_id, owner_repo, edit_class, payload)
VALUES ('pipeline.trawl', 'trawl', 'DATA', repeat('é', 2048))
RETURNING proposal_id, char_length(payload) AS characters, octet_length(payload) AS bytes;
INSERT INTO core.edit_proposal (element_id, owner_repo, edit_class, payload)
VALUES ('pipeline.trawl', 'trawl', 'DATA', repeat('é', 2049));

-- The text must be there, and hold no control characters: E_PARSE.
INSERT INTO core.edit_proposal (element_id, owner_repo, edit_class, payload) VALUES ('pipeline.trawl', 'trawl', 'DATA', NULL);
INSERT INTO core.edit_proposal (element_id, owner_repo, edit_class, payload) VALUES ('pipeline.trawl', 'trawl', 'DATA', E' \n\t ');
INSERT INTO core.edit_proposal (element_id, owner_repo, edit_class, payload) VALUES ('pipeline.trawl', 'trawl', 'DATA', 'Sample' || chr(27) || '[2J');
-- Line breaks and tabs are ordinary text.
INSERT INTO core.edit_proposal (element_id, owner_repo, edit_class, payload)
VALUES ('pipeline.trawl', 'trawl', 'DATA', E'First sample line.\n\tSecond sample line.')
RETURNING proposal_id;

-- The element and the repository are well-formed names: E_PARSE.
INSERT INTO core.edit_proposal (element_id, owner_repo, edit_class, payload) VALUES (NULL, 'trawl', 'DATA', 'Sample.');
INSERT INTO core.edit_proposal (element_id, owner_repo, edit_class, payload) VALUES ('pipeline..trawl', 'trawl', 'DATA', 'Sample.');
INSERT INTO core.edit_proposal (element_id, owner_repo, edit_class, payload) VALUES ('<script>', 'trawl', 'DATA', 'Sample.');
INSERT INTO core.edit_proposal (element_id, owner_repo, edit_class, payload) VALUES ('pipeline.trawl', NULL, 'DATA', 'Sample.');
INSERT INTO core.edit_proposal (element_id, owner_repo, edit_class, payload) VALUES ('pipeline.trawl', '../trawl', 'DATA', 'Sample.');

-- The status is one of five: broken is E_PARSE, unknown is E_NEEDS_SUBTOOL.
UPDATE core.edit_proposal SET status = 'pending approval' WHERE proposal_id = 1;
UPDATE core.edit_proposal SET status = 'withdrawn', decided_at = '2026-01-12 09:00+00' WHERE proposal_id = 1;

-- decided_at is set when a proposal leaves pending_approval, and not before: E_PARSE.
UPDATE core.edit_proposal SET status = 'approved' WHERE proposal_id = 1;
UPDATE core.edit_proposal SET decided_at = '2026-01-12 09:00+00' WHERE proposal_id = 1;

-- Approving a proposal is what publishes its text.
SELECT proposal_id, status, payload FROM pub.edit_proposal WHERE proposal_id = 1;
UPDATE core.edit_proposal SET status = 'approved', decided_at = '2026-01-12 09:00+00' WHERE proposal_id = 1;
SELECT proposal_id, status, payload FROM pub.edit_proposal WHERE proposal_id = 1;
UPDATE core.edit_proposal SET status = 'building' WHERE proposal_id = 1;
SELECT proposal_id, status, payload FROM pub.edit_proposal WHERE proposal_id = 1;
UPDATE core.edit_proposal SET status = 'live' WHERE proposal_id = 1;
SELECT proposal_id, status, payload FROM pub.edit_proposal WHERE proposal_id = 1;

-- Nothing about who sent a proposal is kept: there is no column to keep it in.
SELECT string_agg(column_name, ', ' ORDER BY ordinal_position) AS columns
FROM information_schema.columns
WHERE table_schema = 'core' AND table_name = 'edit_proposal';
