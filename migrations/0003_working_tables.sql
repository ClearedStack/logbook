-- 0003: the working tables, and the rule each one checks before a row is written.

-- ---------------------------------------------------------------------------
-- Items: one row for every idea for a tool.
-- ---------------------------------------------------------------------------

CREATE SEQUENCE core.item_number AS integer MINVALUE 1 MAXVALUE 9999 NO CYCLE;

-- The hash that tells whether an address has been recorded before. It is taken
-- over the UTF-8 bytes of the address, so it is the same on every machine.
CREATE FUNCTION core.address_sha256(address text) RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE
RETURN encode(sha256(convert_to(address, 'UTF8')), 'hex');

CREATE TABLE core.item (
    item_id        text PRIMARY KEY
                   DEFAULT 'PA-' || lpad(nextval('core.item_number')::text, 4, '0'),
    state          text NOT NULL,
    title          text NOT NULL,
    address        text,
    address_sha256 text UNIQUE
                   GENERATED ALWAYS AS (core.address_sha256(address)) STORED,
    recorded_at    timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE core.item IS 'One row for each item. An item has one identifier and exactly one state.';
COMMENT ON COLUMN core.item.address IS 'The cleaned public address the item was found at, if it has one. Not published.';
COMMENT ON COLUMN core.item.address_sha256 IS 'SHA-256 of the cleaned address. Two items cannot share one.';

CREATE FUNCTION core.check_item(r core.item) RETURNS void
LANGUAGE plpgsql IMMUTABLE
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    IF r.item_id IS NULL OR r.item_id !~ '^PA-[0-9]{4}$' THEN
        RAISE EXCEPTION 'E_PARSE: item_id must look like PA-0001';
    END IF;
    PERFORM core.require_known('state', r.state, core.item_states());
    PERFORM core.require_text('title', r.title, 200);
    IF r.address IS NOT NULL THEN
        PERFORM core.require_text('address', r.address, 2000);
    END IF;
END
$$;

CREATE TRIGGER guard BEFORE INSERT OR UPDATE ON core.item
    FOR EACH ROW EXECUTE FUNCTION core.guard();

-- ---------------------------------------------------------------------------
-- Evaluations: what the gates and the rubric said about an item.
-- ---------------------------------------------------------------------------

CREATE TABLE core.evaluation (
    evaluation_id  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    item_id        text NOT NULL REFERENCES core.item,
    profile        text NOT NULL,
    gates          jsonb NOT NULL,
    factors        jsonb NOT NULL DEFAULT '{}',
    score          integer,
    recommendation text,
    split_flag     boolean NOT NULL DEFAULT false,
    evaluated_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX evaluation_item ON core.evaluation (item_id, evaluation_id);
COMMENT ON TABLE core.evaluation IS 'One row each time an item is screened and scored. Rows are added, never changed.';
COMMENT ON COLUMN core.evaluation.gates IS 'One entry for each gate: {"gate name": {"passed": true}} or {"passed": false, "reason": "..."}.';
COMMENT ON COLUMN core.evaluation.factors IS 'One entry for each rubric factor: {"factor name": {"rating": 1 to 5, "weight": whole number}}. Empty when a gate failed.';
COMMENT ON COLUMN core.evaluation.split_flag IS 'True when the owner is asked to consider splitting the idea into smaller tools.';

CREATE FUNCTION core.check_evaluation(r core.evaluation) RETURNS void
LANGUAGE plpgsql IMMUTABLE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    name        text;
    entry       jsonb;
    gate_failed boolean := false;
    rating      numeric;
    weight      numeric;
    total       numeric := 0;
BEGIN
    PERFORM core.require_slug('profile', r.profile);

    IF r.gates IS NULL OR jsonb_typeof(r.gates) <> 'object' OR r.gates = '{}' THEN
        RAISE EXCEPTION 'E_PARSE: gates must hold a result for each gate';
    END IF;
    FOR name, entry IN SELECT * FROM jsonb_each(r.gates) LOOP
        PERFORM core.require_slug('gate name', name);
        IF jsonb_typeof(entry) <> 'object'
           OR jsonb_typeof(entry -> 'passed') IS DISTINCT FROM 'boolean'
           OR entry - 'passed' - 'reason' <> '{}'
           OR (entry ? 'reason' AND jsonb_typeof(entry -> 'reason') <> 'string') THEN
            RAISE EXCEPTION 'E_PARSE: a gate result holds passed (true or false) and an optional reason';
        END IF;
        IF NOT (entry -> 'passed')::boolean THEN
            gate_failed := true;
            PERFORM core.require_text('reason for a failed gate', entry ->> 'reason', 1000);
        ELSIF entry ? 'reason' THEN
            PERFORM core.require_text('reason for a gate', entry ->> 'reason', 1000);
        END IF;
    END LOOP;

    IF r.factors IS NULL OR jsonb_typeof(r.factors) <> 'object' THEN
        RAISE EXCEPTION 'E_PARSE: factors must hold a rating for each factor';
    END IF;

    IF gate_failed THEN
        IF r.factors <> '{}' OR r.score IS NOT NULL OR r.recommendation IS NOT NULL OR r.split_flag THEN
            RAISE EXCEPTION 'E_PARSE: an evaluation that failed a gate has no factors, score, recommendation or split flag';
        END IF;
        RETURN;
    END IF;

    IF r.factors = '{}' THEN
        RAISE EXCEPTION 'E_PARSE: factors must hold a rating for each factor';
    END IF;
    FOR name, entry IN SELECT * FROM jsonb_each(r.factors) LOOP
        PERFORM core.require_slug('factor name', name);
        IF jsonb_typeof(entry) <> 'object'
           OR jsonb_typeof(entry -> 'rating') IS DISTINCT FROM 'number'
           OR jsonb_typeof(entry -> 'weight') IS DISTINCT FROM 'number'
           OR entry - 'rating' - 'weight' <> '{}' THEN
            RAISE EXCEPTION 'E_PARSE: a factor holds a rating and a weight';
        END IF;
        rating := (entry ->> 'rating')::numeric;
        weight := (entry ->> 'weight')::numeric;
        IF rating NOT IN (1, 2, 3, 4, 5) THEN
            RAISE EXCEPTION 'E_PARSE: a rating is a whole number from 1 to 5';
        END IF;
        IF weight < 1 OR weight > 100 OR weight <> trunc(weight) THEN
            RAISE EXCEPTION 'E_PARSE: a weight is a whole number from 1 to 100';
        END IF;
        total := total + rating * weight;
    END LOOP;

    IF r.score IS NULL OR r.score <> total THEN
        RAISE EXCEPTION 'E_PARSE: score must equal the sum of each rating times its weight';
    END IF;
    PERFORM core.require_known('recommendation', r.recommendation, core.recommendations());
END
$$;

CREATE TRIGGER guard BEFORE INSERT OR UPDATE ON core.evaluation
    FOR EACH ROW EXECUTE FUNCTION core.guard();

-- ---------------------------------------------------------------------------
-- Decisions: what the owner chose, and why.
-- ---------------------------------------------------------------------------

CREATE TABLE core.decision (
    decision_id   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    evaluation_id bigint NOT NULL REFERENCES core.evaluation,
    outcome       text NOT NULL,
    reason        text,
    decided_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX decision_evaluation ON core.decision (evaluation_id, decision_id);
COMMENT ON TABLE core.decision IS 'The decision trail: one row for each decision the owner makes on an evaluation. Rows are added, never changed.';
COMMENT ON COLUMN core.decision.reason IS 'Required whenever the outcome is not what the evaluation recommended.';

CREATE FUNCTION core.check_decision(r core.decision) RETURNS void
LANGUAGE plpgsql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    recommended text;
BEGIN
    PERFORM core.require_known('outcome', r.outcome, core.decision_outcomes());
    SELECT e.recommendation INTO recommended
    FROM core.evaluation e
    WHERE e.evaluation_id = r.evaluation_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'E_PARSE: evaluation_id does not name a recorded evaluation';
    END IF;
    IF r.outcome IS DISTINCT FROM recommended THEN
        PERFORM core.require_text('reason for an override', r.reason, 2000);
    ELSIF r.reason IS NOT NULL THEN
        PERFORM core.require_text('reason', r.reason, 2000);
    END IF;
END
$$;

CREATE TRIGGER guard BEFORE INSERT OR UPDATE ON core.decision
    FOR EACH ROW EXECUTE FUNCTION core.guard();

-- ---------------------------------------------------------------------------
-- Edit proposals: changes proposed by readers, waiting on the owner.
-- ---------------------------------------------------------------------------

CREATE TABLE core.edit_proposal (
    proposal_id  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    element_id   text NOT NULL,
    owner_repo   text NOT NULL,
    edit_class   text NOT NULL,
    payload      text NOT NULL,
    status       text NOT NULL DEFAULT 'pending_approval',
    submitted_at timestamptz NOT NULL DEFAULT now(),
    decided_at   timestamptz
);
CREATE INDEX edit_proposal_status ON core.edit_proposal (status, proposal_id);
COMMENT ON TABLE core.edit_proposal IS 'One row for each proposal that passed the automatic checks. Nothing here says who sent it.';
COMMENT ON COLUMN core.edit_proposal.element_id IS 'The element the proposal is about, as named in the ownership map.';
COMMENT ON COLUMN core.edit_proposal.payload IS 'The proposed change, at most 4096 bytes. Published only once approved.';

CREATE FUNCTION core.check_edit_proposal(r core.edit_proposal) RETURNS void
LANGUAGE plpgsql IMMUTABLE
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    PERFORM core.require_slug('element_id', r.element_id);
    PERFORM core.require_slug('owner_repo', r.owner_repo);
    PERFORM core.require_known('edit_class', r.edit_class, core.edit_classes());
    PERFORM core.require_text('payload', r.payload, 4096);
    PERFORM core.require_known('status', r.status, core.proposal_statuses());
    IF (r.status = 'pending_approval') <> (r.decided_at IS NULL) THEN
        RAISE EXCEPTION 'E_PARSE: decided_at is set once a proposal leaves pending_approval, and not before';
    END IF;
END
$$;

CREATE TRIGGER guard BEFORE INSERT OR UPDATE ON core.edit_proposal
    FOR EACH ROW EXECUTE FUNCTION core.guard();

-- ---------------------------------------------------------------------------
-- The queue: work waiting for a worker, and the lease of whoever has claimed it.
-- ---------------------------------------------------------------------------

CREATE TABLE core.queue (
    queue_id     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    worker       text NOT NULL,
    lane         text NOT NULL,
    lane_rank    integer GENERATED ALWAYS AS (core.lane_rank(lane)) STORED,
    item_id      text REFERENCES core.item,
    proposal_id  bigint REFERENCES core.edit_proposal,
    queued_at    timestamptz NOT NULL DEFAULT now(),
    attempt      integer NOT NULL DEFAULT 0,
    lease_token  uuid,
    leased_until timestamptz,
    heartbeat_at timestamptz
);
CREATE INDEX queue_next ON core.queue (worker, lane_rank, queue_id);
CREATE INDEX queue_item ON core.queue (item_id) WHERE item_id IS NOT NULL;
COMMENT ON TABLE core.queue IS 'One row for each piece of work waiting or claimed. A finished piece of work is deleted in the transaction that records its result.';
COMMENT ON COLUMN core.queue.worker IS 'The worker the work is for, by its name in the naming registry.';
COMMENT ON COLUMN core.queue.lane_rank IS '1 for urgent, 2 for normal, 3 for backfill. Take work in order of lane_rank, then queue_id.';
COMMENT ON COLUMN core.queue.lease_token IS 'Held by the worker that claimed the work. Internal: never published.';
COMMENT ON COLUMN core.queue.leased_until IS 'When the lease runs out. After that the work may be claimed again.';

CREATE FUNCTION core.check_queue(r core.queue) RETURNS void
LANGUAGE plpgsql IMMUTABLE
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    PERFORM core.require_slug('worker', r.worker);
    PERFORM core.require_known('lane', r.lane, core.lanes());
    IF r.item_id IS NOT NULL AND r.proposal_id IS NOT NULL THEN
        RAISE EXCEPTION 'E_PARSE: a queue entry is about an item or a proposal, not both';
    END IF;
    IF r.attempt IS NULL OR r.attempt < 0 THEN
        RAISE EXCEPTION 'E_PARSE: attempt is a count of 0 or more';
    END IF;
    IF (r.lease_token IS NULL) <> (r.leased_until IS NULL) THEN
        RAISE EXCEPTION 'E_PARSE: a lease has both a token and an end time, or neither';
    END IF;
    IF r.heartbeat_at IS NOT NULL AND r.lease_token IS NULL THEN
        RAISE EXCEPTION 'E_PARSE: a heartbeat belongs to a lease';
    END IF;
END
$$;

CREATE TRIGGER guard BEFORE INSERT OR UPDATE ON core.queue
    FOR EACH ROW EXECUTE FUNCTION core.guard();

-- ---------------------------------------------------------------------------
-- Pauses: items waiting for a rule to be written, and when they were run again.
-- ---------------------------------------------------------------------------

CREATE TABLE core.pause (
    pause_id    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    item_id     text NOT NULL REFERENCES core.item,
    worker      text NOT NULL,
    pattern     text NOT NULL,
    paused_from text NOT NULL,
    paused_at   timestamptz NOT NULL DEFAULT now(),
    replayed_at timestamptz
);
CREATE UNIQUE INDEX pause_one_open ON core.pause (item_id) WHERE replayed_at IS NULL;
CREATE INDEX pause_waiting ON core.pause (worker, pattern) WHERE replayed_at IS NULL;
COMMENT ON TABLE core.pause IS 'One row each time a worker stops on an item it has no rule for. An item has at most one open pause.';
COMMENT ON COLUMN core.pause.pattern IS 'The fingerprint of the unfamiliar case. Every open pause with the same worker and pattern is replayed together.';
COMMENT ON COLUMN core.pause.paused_from IS 'The state the item was in, and goes back to when it is replayed.';
COMMENT ON COLUMN core.pause.replayed_at IS 'Empty while the item is still waiting.';

CREATE FUNCTION core.check_pause(r core.pause) RETURNS void
LANGUAGE plpgsql IMMUTABLE
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    PERFORM core.require_slug('worker', r.worker);
    PERFORM core.require_text('pattern', r.pattern, 200);
    PERFORM core.require_known('paused_from', r.paused_from, core.item_states());
    IF r.paused_from = 'needs_subtool' THEN
        RAISE EXCEPTION 'E_PARSE: paused_from is the state before the pause, so it cannot be needs_subtool';
    END IF;
    IF r.replayed_at < r.paused_at THEN
        RAISE EXCEPTION 'E_PARSE: replayed_at cannot be earlier than paused_at';
    END IF;
END
$$;

CREATE TRIGGER guard BEFORE INSERT OR UPDATE ON core.pause
    FOR EACH ROW EXECUTE FUNCTION core.guard();

-- ---------------------------------------------------------------------------
-- Restore drills: when each monthly drill ran, and what its four checks found.
-- ---------------------------------------------------------------------------

CREATE TABLE core.restore_drill (
    drill_id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ran_at            timestamptz NOT NULL,
    decrypt_passed    boolean,
    logbook_passed    boolean,
    plainforge_passed boolean,
    lazarette_passed  boolean,
    passed            boolean GENERATED ALWAYS AS (
                          COALESCE(decrypt_passed AND logbook_passed
                                   AND plainforge_passed AND lazarette_passed, false)) STORED
);
COMMENT ON TABLE core.restore_drill IS 'One row for each restore drill. Rows are added, never changed.';
COMMENT ON COLUMN core.restore_drill.decrypt_passed IS 'The archives downloaded and opened with the current key. Empty if the check did not run.';
COMMENT ON COLUMN core.restore_drill.logbook_passed IS 'The database loaded and passed its integrity checks. Empty if the check did not run.';
COMMENT ON COLUMN core.restore_drill.plainforge_passed IS 'The repositories passed Git''s consistency check. Empty if the check did not run.';
COMMENT ON COLUMN core.restore_drill.lazarette_passed IS 'The image manifests and signatures resolved. Empty if the check did not run.';
COMMENT ON COLUMN core.restore_drill.passed IS 'True only when all four checks ran and passed.';

CREATE FUNCTION core.check_restore_drill(r core.restore_drill) RETURNS void
LANGUAGE plpgsql IMMUTABLE
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    IF r.ran_at IS NULL THEN
        RAISE EXCEPTION 'E_PARSE: ran_at is missing';
    END IF;
END
$$;

CREATE TRIGGER guard BEFORE INSERT OR UPDATE ON core.restore_drill
    FOR EACH ROW EXECUTE FUNCTION core.guard();
