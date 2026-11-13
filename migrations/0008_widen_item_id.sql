-- 0008: an item identifier is PA- followed by 4 to 9 digits, where it was
-- exactly 4. This is the rule in the shared contract.
--
-- Only the test of item_id changes. The rest of core.check_item is as it was
-- in 0003, and so is the column default: the numbers Logbook gives out itself
-- still come from core.item_number and still stop at PA-9999. An identifier
-- past that has to be supplied by whoever inserts the row.

CREATE OR REPLACE FUNCTION core.check_item(r core.item) RETURNS void
LANGUAGE plpgsql IMMUTABLE
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    IF r.item_id IS NULL OR r.item_id !~ '^PA-[0-9]{4,9}$' THEN
        RAISE EXCEPTION 'E_PARSE: item_id must look like PA-0001';
    END IF;
    PERFORM core.require_known('state', r.state, core.item_states());
    PERFORM core.require_text('title', r.title, 200);
    IF r.address IS NOT NULL THEN
        PERFORM core.require_text('address', r.address, 2000);
    END IF;
END
$$;
