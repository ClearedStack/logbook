-- 0002: the fixed lists Logbook knows, and the checks that refuse a value.
--
-- A refusal carries one of two public error codes at the start of its message:
--   E_PARSE          the value is missing or broken
--   E_NEEDS_SUBTOOL  the value is well-formed, and Logbook has no rule for it
-- Logbook itself never raises E_TIMEOUT; it only stores that code when a
-- worker reports it. A refusal names the field and the rule, never the value.

CREATE FUNCTION core.item_states() RETURNS text[]
LANGUAGE sql IMMUTABLE PARALLEL SAFE
RETURN ARRAY[
    'discovered', 'recorded', 'observed', 'needs_subtool', 'screened_out',
    'scored', 'parked', 'approved', 'building', 'live',
    'rejected', 'linked', 'merged', 'retired'];

-- In the order they are emptied: urgent first, backfill last.
CREATE FUNCTION core.lanes() RETURNS text[]
LANGUAGE sql IMMUTABLE PARALLEL SAFE
RETURN ARRAY['urgent', 'normal', 'backfill'];

CREATE FUNCTION core.lane_rank(lane text) RETURNS integer
LANGUAGE sql IMMUTABLE PARALLEL SAFE
RETURN array_position(core.lanes(), lane);

CREATE FUNCTION core.error_codes() RETURNS text[]
LANGUAGE sql IMMUTABLE PARALLEL SAFE
RETURN ARRAY['E_TIMEOUT', 'E_PARSE', 'E_NEEDS_SUBTOOL'];

CREATE FUNCTION core.recommendations() RETURNS text[]
LANGUAGE sql IMMUTABLE PARALLEL SAFE
RETURN ARRAY['build', 'link', 'park', 'reject'];

-- What the owner can decide. reopen sends a screened-out item back to observed.
CREATE FUNCTION core.decision_outcomes() RETURNS text[]
LANGUAGE sql IMMUTABLE PARALLEL SAFE
RETURN ARRAY['build', 'link', 'merge', 'park', 'reject', 'reopen'];

CREATE FUNCTION core.edit_classes() RETURNS text[]
LANGUAGE sql IMMUTABLE PARALLEL SAFE
RETURN ARRAY['DATA', 'CONFIG', 'ISSUE'];

CREATE FUNCTION core.proposal_statuses() RETURNS text[]
LANGUAGE sql IMMUTABLE PARALLEL SAFE
RETURN ARRAY['pending_approval', 'approved', 'building', 'live', 'declined'];

-- A value from one of the fixed lists above.
CREATE FUNCTION core.require_known(field text, value text, known text[]) RETURNS void
LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    IF value IS NULL THEN
        RAISE EXCEPTION 'E_PARSE: % is missing', field;
    ELSIF value !~ '^[A-Za-z][A-Za-z0-9_]*$' THEN
        RAISE EXCEPTION 'E_PARSE: % is not a well-formed name', field;
    ELSIF value <> ALL (known) THEN
        RAISE EXCEPTION 'E_NEEDS_SUBTOOL: % is a name Logbook has no rule for', field;
    END IF;
END
$$;

-- A name that is listed somewhere else: a worker or repository in the naming
-- registry, an element in the ownership map, a gate, factor or profile of
-- Assay's. Logbook checks its form and leaves the list to its owner.
CREATE FUNCTION core.require_slug(field text, value text) RETURNS void
LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    IF value IS NULL THEN
        RAISE EXCEPTION 'E_PARSE: % is missing', field;
    ELSIF octet_length(value) > 100 OR value !~ '^[a-z][a-z0-9]*([._-][a-z0-9]+)*$' THEN
        RAISE EXCEPTION 'E_PARSE: % is not a well-formed name', field;
    END IF;
END
$$;

-- Free text that a person or a worker wrote.
CREATE FUNCTION core.require_text(field text, value text, max_bytes integer) RETURNS void
LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    IF value IS NULL OR value !~ '[^[:space:]]' THEN
        RAISE EXCEPTION 'E_PARSE: % is missing', field;
    ELSIF octet_length(value) > max_bytes THEN
        RAISE EXCEPTION 'E_PARSE: % is longer than % bytes', field, max_bytes;
    ELSIF value ~ '[\x01-\x08\x0b\x0c\x0e-\x1f\x7f]' THEN
        RAISE EXCEPTION 'E_PARSE: % holds control characters', field;
    END IF;
END
$$;

-- Every working table runs its own check function before a row is written.
-- The function is named check_ followed by the table's name.
CREATE FUNCTION core.guard() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    EXECUTE format('SELECT core.%I($1)', 'check_' || TG_TABLE_NAME) USING NEW;
    RETURN NEW;
END
$$;
