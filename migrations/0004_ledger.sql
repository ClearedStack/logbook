-- 0004: the ledger. One entry each time an item changes state or a proposal
-- changes status. Entries are added and never changed or removed.

CREATE TABLE core.ledger (
    entry_id    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    item_id     text REFERENCES core.item,
    proposal_id bigint REFERENCES core.edit_proposal,
    actor       text NOT NULL,
    from_state  text,
    to_state    text NOT NULL,
    error_code  text,
    note        text,
    recorded_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ledger_item ON core.ledger (item_id, entry_id) WHERE item_id IS NOT NULL;
CREATE INDEX ledger_proposal ON core.ledger (proposal_id, entry_id) WHERE proposal_id IS NOT NULL;
COMMENT ON TABLE core.ledger IS 'The append-only history of every item and every proposal.';
COMMENT ON COLUMN core.ledger.actor IS 'Who made the move: a worker or service by its name in the naming registry, or owner.';
COMMENT ON COLUMN core.ledger.from_state IS 'Empty on the first entry for an item or a proposal.';
COMMENT ON COLUMN core.ledger.to_state IS 'An item state for an item, a proposal status for a proposal. The same as from_state when a failure left it where it was.';
COMMENT ON COLUMN core.ledger.error_code IS 'One of the three public error codes, when the entry records a failure or a pause.';

CREATE FUNCTION core.check_ledger(r core.ledger) RETURNS void
LANGUAGE plpgsql IMMUTABLE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    known text[];
BEGIN
    IF num_nonnulls(r.item_id, r.proposal_id) <> 1 THEN
        RAISE EXCEPTION 'E_PARSE: a ledger entry is about one item or one proposal';
    END IF;
    PERFORM core.require_slug('actor', r.actor);
    IF r.item_id IS NOT NULL THEN
        known := core.item_states();
    ELSE
        known := core.proposal_statuses();
    END IF;
    PERFORM core.require_known('to_state', r.to_state, known);
    IF r.from_state IS NOT NULL THEN
        PERFORM core.require_known('from_state', r.from_state, known);
    END IF;
    IF r.error_code IS NOT NULL THEN
        PERFORM core.require_known('error_code', r.error_code, core.error_codes());
    END IF;
    IF r.note IS NOT NULL THEN
        PERFORM core.require_text('note', r.note, 2000);
    END IF;
END
$$;

CREATE FUNCTION core.ledger_is_append_only() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    RAISE EXCEPTION 'the ledger is append-only: an entry is never changed or removed';
END
$$;

CREATE TRIGGER append_only BEFORE UPDATE OR DELETE ON core.ledger
    FOR EACH ROW EXECUTE FUNCTION core.ledger_is_append_only();

CREATE TRIGGER append_only_truncate BEFORE TRUNCATE ON core.ledger
    FOR EACH STATEMENT EXECUTE FUNCTION core.ledger_is_append_only();

CREATE TRIGGER guard BEFORE INSERT ON core.ledger
    FOR EACH ROW EXECUTE FUNCTION core.guard();
