-- 0007: the integrity checks a restore drill runs on a restored copy.
--
-- core.integrity_check() returns one row for each check, always in the same
-- order, with the number of things that failed it. All zeros is a pass. It
-- reads both schemas, so neither muster nor pub_ro can call it; it is run by
-- the owner of the database.

-- Whether a working table's own check would refuse this row today. Any error
-- other than a refusal is not caught, and stops the whole check.
CREATE FUNCTION core.is_refused(working_table text, whole_row anyelement) RETURNS boolean
LANGUAGE plpgsql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    EXECUTE format('SELECT core.%I($1)', 'check_' || working_table) USING whole_row;
    RETURN false;
EXCEPTION WHEN raise_exception THEN
    RETURN true;
END
$$;

-- How many rows of one working table its own check would refuse today. A
-- restore loads rows without running the checks, which is why they run here.
CREATE FUNCTION core.malformed_rows(working_table text) RETURNS bigint
LANGUAGE plpgsql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    refused bigint;
BEGIN
    EXECUTE format('SELECT count(*) FROM core.%I AS t WHERE core.is_refused(%L, t)',
                   working_table, working_table)
    INTO refused;
    RETURN refused;
END
$$;

CREATE FUNCTION core.integrity_check()
RETURNS TABLE (check_name text, failures bigint)
LANGUAGE sql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
SELECT c.check_name, c.failures
FROM (VALUES
    (1, 'item rows are well-formed', core.malformed_rows('item')),
    (2, 'evaluation rows are well-formed', core.malformed_rows('evaluation')),
    (3, 'decision rows are well-formed', core.malformed_rows('decision')),
    (4, 'edit_proposal rows are well-formed', core.malformed_rows('edit_proposal')),
    (5, 'queue rows are well-formed', core.malformed_rows('queue')),
    (6, 'pause rows are well-formed', core.malformed_rows('pause')),
    (7, 'ledger rows are well-formed', core.malformed_rows('ledger')),
    (8, 'restore_drill rows are well-formed', core.malformed_rows('restore_drill')),

    (9, 'each item is in the state its last ledger entry gave it',
        (SELECT count(*)
         FROM core.item i
         WHERE i.state IS DISTINCT FROM (
             SELECT l.to_state FROM core.ledger l
             WHERE l.item_id = i.item_id
             ORDER BY l.entry_id DESC LIMIT 1))),

    (10, 'each item ledger entry starts where the one before it ended',
        (SELECT count(*)
         FROM (SELECT l.from_state,
                      lag(l.to_state) OVER (PARTITION BY l.item_id ORDER BY l.entry_id) AS state_before
               FROM core.ledger l
               WHERE l.item_id IS NOT NULL) trail
         WHERE trail.from_state IS DISTINCT FROM trail.state_before)),

    (11, 'each proposal has the status its last ledger entry gave it',
        (SELECT count(*)
         FROM core.edit_proposal p
         WHERE p.status IS DISTINCT FROM (
             SELECT l.to_state FROM core.ledger l
             WHERE l.proposal_id = p.proposal_id
             ORDER BY l.entry_id DESC LIMIT 1))),

    (12, 'each proposal ledger entry starts where the one before it ended',
        (SELECT count(*)
         FROM (SELECT l.from_state,
                      lag(l.to_state) OVER (PARTITION BY l.proposal_id ORDER BY l.entry_id) AS status_before
               FROM core.ledger l
               WHERE l.proposal_id IS NOT NULL) trail
         WHERE trail.from_state IS DISTINCT FROM trail.status_before)),

    (13, 'an item is in needs_subtool exactly when it has an open pause',
        (SELECT count(*)
         FROM core.item i
         WHERE (i.state = 'needs_subtool') <> EXISTS (
             SELECT FROM core.pause p
             WHERE p.item_id = i.item_id AND p.replayed_at IS NULL))),

    (14, 'each public view shows every row of its working table',
        abs((SELECT count(*) FROM pub.item) - (SELECT count(*) FROM core.item))
      + abs((SELECT count(*) FROM pub.item_history)
            - (SELECT count(*) FROM core.ledger WHERE item_id IS NOT NULL))
      + abs((SELECT count(*) FROM pub.evaluation) - (SELECT count(*) FROM core.evaluation))
      + abs((SELECT count(*) FROM pub.decision) - (SELECT count(*) FROM core.decision))
      + abs((SELECT count(*) FROM pub.pause) - (SELECT count(*) FROM core.pause))
      + abs((SELECT count(*) FROM pub.edit_proposal) - (SELECT count(*) FROM core.edit_proposal))
      + abs((SELECT count(*) FROM pub.restore_drill) - (SELECT count(*) FROM core.restore_drill))),

    (15, 'no public view shows the text of an unapproved proposal',
        (SELECT count(*)
         FROM pub.edit_proposal shown
         JOIN core.edit_proposal p ON p.proposal_id = shown.proposal_id
         WHERE shown.payload IS NOT NULL
           AND p.status NOT IN ('approved', 'building', 'live')))
) AS c (position, check_name, failures)
ORDER BY c.position;
$$;

-- GRANT ... ON ALL FUNCTIONS in 0006 covered only what existed then. Say it
-- outright so nobody has to work that out.
REVOKE ALL ON FUNCTION core.is_refused(text, anyelement) FROM PUBLIC, muster;
REVOKE ALL ON FUNCTION core.malformed_rows(text) FROM PUBLIC, muster;
REVOKE ALL ON FUNCTION core.integrity_check() FROM PUBLIC, muster;
