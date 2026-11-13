-- 0009: Logbook gives out every item identifier, past PA-9999 as well, and
-- each number has one form.
--
-- A number up to 9999 is written with four digits: PA-0001. A larger one is
-- written as it is, with no leading zero: PA-10000. The numbers run to
-- PA-999999999. Muster no longer supplies an identifier, so a supplied one
-- cannot collide with one that is given out later.

ALTER SEQUENCE core.item_number MAXVALUE 999999999;

CREATE FUNCTION core.next_item_id() RETURNS text
LANGUAGE sql VOLATILE
RETURN (SELECT 'PA-' || lpad(n::text, greatest(4, length(n::text)), '0')
        FROM nextval('core.item_number') AS n);

REVOKE ALL ON FUNCTION core.next_item_id() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION core.next_item_id() TO muster;

ALTER TABLE core.item ALTER COLUMN item_id SET DEFAULT core.next_item_id();

-- Four digits, or five to nine that do not start with 0. PA-00001 and
-- PA-010000 would be second spellings of a number, so they are refused.
CREATE OR REPLACE FUNCTION core.check_item(r core.item) RETURNS void
LANGUAGE plpgsql IMMUTABLE
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    IF r.item_id IS NULL OR r.item_id !~ '^PA-([0-9]{4}|[1-9][0-9]{4,8})$' THEN
        RAISE EXCEPTION 'E_PARSE: item_id must look like PA-0001';
    END IF;
    PERFORM core.require_known('state', r.state, core.item_states());
    PERFORM core.require_text('title', r.title, 200);
    IF r.address IS NOT NULL THEN
        PERFORM core.require_text('address', r.address, 2000);
    END IF;
END
$$;

-- Muster adds an item by giving its state, title and address. The identifier
-- and the time it was recorded come from Logbook. The owner of the database
-- can still insert any column.
REVOKE INSERT ON core.item FROM muster;
GRANT INSERT (state, title, address) ON core.item TO muster;
