\i fixtures/sample_record.sql
\set ECHO all
-- Rule: the public views are the whole public surface. This is every column
-- they have and every row they show for the sample record. A new column, or a
-- private value showing up, changes this output and fails the test.

SELECT table_name AS view, string_agg(column_name, ', ' ORDER BY ordinal_position) AS columns
FROM information_schema.columns
WHERE table_schema = 'pub'
GROUP BY 1
ORDER BY 1;

SET SESSION AUTHORIZATION pub_ro;

SELECT * FROM pub.item ORDER BY item_id;

SELECT * FROM pub.item_history ORDER BY entry_id;

SELECT * FROM pub.evaluation ORDER BY evaluation_id;

SELECT * FROM pub.evaluation_gate ORDER BY evaluation_id, gate;

SELECT * FROM pub.evaluation_factor ORDER BY evaluation_id, factor;

SELECT * FROM pub.decision ORDER BY decision_id;

SELECT * FROM pub.pause ORDER BY pause_id;

-- The text of a proposal is shown only once the owner has approved it:
-- proposal 1 is waiting and proposal 3 was declined.
SELECT * FROM pub.edit_proposal ORDER BY proposal_id;

SELECT * FROM pub.restore_drill ORDER BY drill_id;

-- Work whose lease has run out counts as waiting again.
SELECT * FROM pub.queue_depth ORDER BY worker, lane;

RESET SESSION AUTHORIZATION;

-- None of the private values of the sample record appears in any public view:
-- not an address, not its hash, not a lease token, not an unapproved proposal.
CREATE TEMPORARY TABLE published AS
SELECT to_jsonb(v)::text AS line FROM pub.item v
UNION ALL SELECT to_jsonb(v)::text FROM pub.item_history v
UNION ALL SELECT to_jsonb(v)::text FROM pub.evaluation v
UNION ALL SELECT to_jsonb(v)::text FROM pub.evaluation_gate v
UNION ALL SELECT to_jsonb(v)::text FROM pub.evaluation_factor v
UNION ALL SELECT to_jsonb(v)::text FROM pub.decision v
UNION ALL SELECT to_jsonb(v)::text FROM pub.queue_depth v
UNION ALL SELECT to_jsonb(v)::text FROM pub.pause v
UNION ALL SELECT to_jsonb(v)::text FROM pub.edit_proposal v
UNION ALL SELECT to_jsonb(v)::text FROM pub.restore_drill v;

SELECT count(*) AS lines_published FROM published;
SELECT count(*) AS private_values_published
FROM published p
JOIN (
    SELECT address AS private_value FROM core.item WHERE address IS NOT NULL
    UNION ALL SELECT address_sha256 FROM core.item WHERE address_sha256 IS NOT NULL
    UNION ALL SELECT lease_token::text FROM core.queue WHERE lease_token IS NOT NULL
    UNION ALL SELECT payload FROM core.edit_proposal WHERE status IN ('pending_approval', 'declined')
) private ON position(private.private_value IN p.line) > 0;
