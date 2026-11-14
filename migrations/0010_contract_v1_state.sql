-- 0010: places in Logbook for the rest of Muster's Contract v1 state, and the
-- public view of component health.
--
-- Added here so Muster can be stateless across restarts:
--   core.item.source            where a candidate was found
--   core.edit_proposal.reason   why the reader proposed the change
--   core.edit_proposal.file_path the file in owner_repo from the ownership map
--   core.queue.held             work stopped by E_PARSE until released
--   core.result                 each worker's JSON object result
--   core.lease_outcome          the answer to the call that ended the last lease
--   core.component_health       each component's latest health and image digest
--   core.submission_count       each visitor key's daily submission count
--   pub.component_health        component health and error codes, without digests
--
-- Also fixes pub.queue_depth so steps scheduled in the future (such as
-- Tidegauge's seven-day checks) and stopped steps are not counted as waiting or
-- claimed, and caps edit_proposal numbering at 999999999 to match EP-999999999.

-- ---------------------------------------------------------------------------
-- Fixed lists from Contract v1, and checks for names with hyphens or paths.
-- ---------------------------------------------------------------------------

CREATE FUNCTION core.item_sources() RETURNS text[]
LANGUAGE sql IMMUTABLE PARALLEL SAFE
RETURN ARRAY['sam-gov', 'github-issues', 'web-sweep', 'site-form'];

CREATE FUNCTION core.health_states() RETURNS text[]
LANGUAGE sql IMMUTABLE PARALLEL SAFE
RETURN ARRAY['healthy', 'idle', 'degraded', 'paused'];

CREATE FUNCTION core.lease_calls() RETURNS text[]
LANGUAGE sql IMMUTABLE PARALLEL SAFE
RETURN ARRAY['complete', 'fail', 'needs_subtool'];

-- A value from a fixed list whose entries are lower-case slugs such as sam-gov.
CREATE FUNCTION core.require_known_slug(field text, value text, known text[]) RETURNS void
LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    PERFORM core.require_slug(field, value);
    IF value <> ALL (known) THEN
        RAISE EXCEPTION 'E_NEEDS_SUBTOOL: % is a name Logbook has no rule for', field;
    END IF;
END
$$;

-- A relative file path inside a repository, such as src/data/site.ts.
CREATE FUNCTION core.require_relative_path(field text, value text, max_bytes integer) RETURNS void
LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    IF value IS NULL OR value = '' THEN
        RAISE EXCEPTION 'E_PARSE: % is missing', field;
    ELSIF octet_length(value) > max_bytes THEN
        RAISE EXCEPTION 'E_PARSE: % is longer than % bytes', field, max_bytes;
    ELSIF value !~ '^[A-Za-z0-9._\[\]-]+(/[A-Za-z0-9._\[\]-]+)*$'
          OR value ~ '(^|/)\.\.?(/|$)' THEN
        RAISE EXCEPTION 'E_PARSE: % is not a well-formed relative path', field;
    END IF;
END
$$;

-- ---------------------------------------------------------------------------
-- Existing working tables: source on item, reason and file_path on proposal,
-- and held on queue.
-- ---------------------------------------------------------------------------

ALTER TABLE core.item ADD COLUMN source text;
COMMENT ON COLUMN core.item.source IS 'Where the item was found, when recorded through intake: sam-gov, github-issues, web-sweep or site-form. Not published.';

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
    IF r.source IS NOT NULL THEN
        PERFORM core.require_known_slug('source', r.source, core.item_sources());
    END IF;
END
$$;

ALTER TABLE core.edit_proposal ALTER COLUMN proposal_id SET MAXVALUE 999999999;
ALTER TABLE core.edit_proposal
    ADD COLUMN reason text,
    ADD COLUMN file_path text;
COMMENT ON COLUMN core.edit_proposal.reason IS 'Why the reader proposed the change, at most 4096 bytes. Not published.';
COMMENT ON COLUMN core.edit_proposal.file_path IS 'The file in owner_repo that owns the element, from the ownership map. Not published.';

CREATE OR REPLACE FUNCTION core.check_edit_proposal(r core.edit_proposal) RETURNS void
LANGUAGE plpgsql IMMUTABLE
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    IF r.proposal_id IS NULL OR r.proposal_id < 1 OR r.proposal_id > 999999999 THEN
        RAISE EXCEPTION 'E_PARSE: proposal_id must be from 1 to 999999999';
    END IF;
    PERFORM core.require_slug('element_id', r.element_id);
    PERFORM core.require_slug('owner_repo', r.owner_repo);
    PERFORM core.require_known('edit_class', r.edit_class, core.edit_classes());
    PERFORM core.require_text('payload', r.payload, 4096);
    IF r.reason IS NOT NULL THEN
        PERFORM core.require_text('reason', r.reason, 4096);
    END IF;
    IF r.file_path IS NOT NULL THEN
        PERFORM core.require_relative_path('file_path', r.file_path, 500);
    END IF;
    PERFORM core.require_known('status', r.status, core.proposal_statuses());
    IF (r.status = 'pending_approval') <> (r.decided_at IS NULL) THEN
        RAISE EXCEPTION 'E_PARSE: decided_at is set once a proposal leaves pending_approval, and not before';
    END IF;
END
$$;

ALTER TABLE core.queue ADD COLUMN held boolean NOT NULL DEFAULT false;
COMMENT ON COLUMN core.queue.held IS 'True when a worker failed with E_PARSE and the step is stopped until the owner releases it.';

CREATE OR REPLACE FUNCTION core.check_queue(r core.queue) RETURNS void
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
    IF r.held IS NULL THEN
        RAISE EXCEPTION 'E_PARSE: held is missing';
    END IF;
    IF r.held AND (r.lease_token IS NOT NULL OR r.leased_until IS NOT NULL OR r.heartbeat_at IS NOT NULL) THEN
        RAISE EXCEPTION 'E_PARSE: a held queue entry has no live lease';
    END IF;
END
$$;

-- A step scheduled for a future time (such as a seven-day Tidegauge check) is
-- not waiting yet, and a held step is neither waiting nor claimed.
CREATE OR REPLACE VIEW pub.queue_depth WITH (security_barrier) AS
SELECT q.worker,
       q.lane,
       count(*) FILTER (WHERE q.leased_until IS NULL OR q.leased_until <= now()) AS waiting,
       count(*) FILTER (WHERE q.leased_until > now()) AS claimed
FROM core.queue q
WHERE NOT q.held
  AND q.queued_at <= now()
  AND (q.leased_until IS NULL OR isfinite(q.leased_until))
GROUP BY q.worker, q.lane;

-- ---------------------------------------------------------------------------
-- Worker results: the latest JSON object each worker produced for an item or
-- an edit proposal. Never published directly.
-- ---------------------------------------------------------------------------

CREATE TABLE core.result (
    result_id   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    item_id     text REFERENCES core.item,
    proposal_id bigint REFERENCES core.edit_proposal,
    worker      text NOT NULL,
    payload     jsonb NOT NULL,
    recorded_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX result_item_worker ON core.result (item_id, worker) WHERE item_id IS NOT NULL;
CREATE UNIQUE INDEX result_proposal_worker ON core.result (proposal_id, worker) WHERE proposal_id IS NOT NULL;
COMMENT ON TABLE core.result IS 'The latest JSON object each worker returned for an item or an edit proposal. Replaced only by the same worker completing another step on the same subject.';

CREATE FUNCTION core.check_result(r core.result) RETURNS void
LANGUAGE plpgsql IMMUTABLE
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    IF num_nonnulls(r.item_id, r.proposal_id) <> 1 THEN
        RAISE EXCEPTION 'E_PARSE: a result is about one item or one proposal';
    END IF;
    PERFORM core.require_slug('worker', r.worker);
    IF r.payload IS NULL OR jsonb_typeof(r.payload) <> 'object' THEN
        RAISE EXCEPTION 'E_PARSE: payload must be a JSON object';
    END IF;
    IF octet_length(r.payload::text) > 262144 THEN
        RAISE EXCEPTION 'E_PARSE: payload is longer than 262144 bytes';
    END IF;
    IF r.recorded_at IS NULL THEN
        RAISE EXCEPTION 'E_PARSE: recorded_at is missing';
    END IF;
END
$$;

CREATE TRIGGER guard BEFORE INSERT OR UPDATE ON core.result
    FOR EACH ROW EXECUTE FUNCTION core.guard();

-- ---------------------------------------------------------------------------
-- Lease outcomes: how the last lease on a step ended, so a worker repeating a
-- call whose acknowledgement was lost receives the same answer again.
-- ---------------------------------------------------------------------------

CREATE TABLE core.lease_outcome (
    outcome_id  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    item_id     text REFERENCES core.item,
    proposal_id bigint REFERENCES core.edit_proposal,
    is_incident boolean NOT NULL DEFAULT false,
    lease       text NOT NULL,
    worker      text NOT NULL,
    call_name   text NOT NULL,
    call_arg    text,
    ack_state   text NOT NULL,
    ack_next    text,
    ack_held    boolean NOT NULL DEFAULT false,
    recorded_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX lease_outcome_item ON core.lease_outcome (item_id, is_incident) WHERE item_id IS NOT NULL;
CREATE UNIQUE INDEX lease_outcome_proposal ON core.lease_outcome (proposal_id) WHERE proposal_id IS NOT NULL;
COMMENT ON TABLE core.lease_outcome IS 'How the last lease on each subject ended, so a repeated worker call gets the same answer.';

CREATE FUNCTION core.check_lease_outcome(r core.lease_outcome) RETURNS void
LANGUAGE plpgsql IMMUTABLE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    known_states text[];
    expected_prefix text;
BEGIN
    IF num_nonnulls(r.item_id, r.proposal_id) <> 1 THEN
        RAISE EXCEPTION 'E_PARSE: a lease outcome is about one item or one proposal';
    END IF;
    IF r.is_incident IS NULL THEN
        RAISE EXCEPTION 'E_PARSE: is_incident is missing';
    END IF;
    IF r.proposal_id IS NOT NULL AND r.is_incident THEN
        RAISE EXCEPTION 'E_PARSE: an incident lease belongs to an item, not a proposal';
    END IF;

    IF r.item_id IS NOT NULL THEN
        known_states := core.item_states();
        IF r.is_incident THEN
            expected_prefix := 'incident:' || r.item_id || '.';
        ELSE
            expected_prefix := r.item_id || '.';
        END IF;
    ELSE
        known_states := core.proposal_statuses();
        expected_prefix := 'EP-' || lpad(r.proposal_id::text, greatest(4, length(r.proposal_id::text)), '0') || '.';
    END IF;

    IF r.lease IS NULL
       OR left(r.lease, length(expected_prefix)) <> expected_prefix
       OR substr(r.lease, length(expected_prefix) + 1) !~ '^[1-9][0-9]*\.[1-9][0-9]*$' THEN
        RAISE EXCEPTION 'E_PARSE: lease must name the subject, arrival and attempt';
    END IF;

    PERFORM core.require_slug('worker', r.worker);
    PERFORM core.require_known('call_name', r.call_name, core.lease_calls());
    PERFORM core.require_known('ack_state', r.ack_state, known_states);

    IF r.call_name = 'complete' THEN
        PERFORM core.require_known('call_arg', r.call_arg, known_states);
    ELSIF r.call_name = 'fail' THEN
        IF r.call_arg = 'E_NEEDS_SUBTOOL' THEN
            RAISE EXCEPTION 'E_PARSE: fail takes E_TIMEOUT or E_PARSE';
        END IF;
        PERFORM core.require_known('call_arg', r.call_arg, core.error_codes());
    ELSIF r.call_arg IS NOT NULL THEN
        RAISE EXCEPTION 'E_PARSE: needs_subtool carries no call_arg';
    END IF;

    IF r.ack_next IS NOT NULL THEN
        PERFORM core.require_slug('ack_next', r.ack_next);
    END IF;
    IF r.ack_held IS NULL THEN
        RAISE EXCEPTION 'E_PARSE: ack_held is missing';
    END IF;
    IF r.ack_held AND r.ack_next IS NOT NULL THEN
        RAISE EXCEPTION 'E_PARSE: a held step has no next worker';
    END IF;
    IF r.recorded_at IS NULL THEN
        RAISE EXCEPTION 'E_PARSE: recorded_at is missing';
    END IF;
END
$$;

CREATE TRIGGER guard BEFORE INSERT OR UPDATE ON core.lease_outcome
    FOR EACH ROW EXECUTE FUNCTION core.guard();

-- ---------------------------------------------------------------------------
-- Component health: what Shipkeeper reported last for each component, and the
-- public view of that health without image digests.
-- ---------------------------------------------------------------------------

CREATE TABLE core.component_health (
    component   text PRIMARY KEY,
    state       text NOT NULL,
    error_code  text,
    digest      text,
    reported_at timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE core.component_health IS 'The latest health report and image digest recorded for each platform component.';
COMMENT ON COLUMN core.component_health.digest IS 'The container image digest Shipkeeper saw last, used to trigger replay and mark building proposals live. Not published.';

CREATE FUNCTION core.check_component_health(r core.component_health) RETURNS void
LANGUAGE plpgsql IMMUTABLE
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    PERFORM core.require_slug('component', r.component);
    PERFORM core.require_known('state', r.state, core.health_states());
    IF r.error_code IS NOT NULL THEN
        PERFORM core.require_known('error_code', r.error_code, core.error_codes());
    END IF;
    IF r.digest IS NOT NULL AND r.digest !~ '^sha256:[0-9a-f]{64}$' THEN
        RAISE EXCEPTION 'E_PARSE: digest must be sha256: followed by 64 lower-case hexadecimal digits';
    END IF;
    IF r.reported_at IS NULL THEN
        RAISE EXCEPTION 'E_PARSE: reported_at is missing';
    END IF;
END
$$;

CREATE TRIGGER guard BEFORE INSERT OR UPDATE ON core.component_health
    FOR EACH ROW EXECUTE FUNCTION core.guard();

CREATE VIEW pub.component_health WITH (security_barrier) AS
SELECT h.component,
       h.state,
       h.error_code,
       h.reported_at
FROM core.component_health h;
COMMENT ON VIEW pub.component_health IS 'The latest health state and public error code of each component that has reported.';

-- ---------------------------------------------------------------------------
-- Daily submission counts: rate-limit counters keyed by HMAC-SHA-256 visitor
-- hash and UTC day. Visitor addresses themselves are never stored.
-- ---------------------------------------------------------------------------

CREATE TABLE core.submission_count (
    submission_day date NOT NULL,
    visitor_key    text NOT NULL,
    submissions    integer NOT NULL DEFAULT 1,
    PRIMARY KEY (submission_day, visitor_key)
);
COMMENT ON TABLE core.submission_count IS 'How many intake submissions a salted visitor hash has made on a UTC day. Never published.';

CREATE FUNCTION core.check_submission_count(r core.submission_count) RETURNS void
LANGUAGE plpgsql IMMUTABLE
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    IF r.submission_day IS NULL THEN
        RAISE EXCEPTION 'E_PARSE: submission_day is missing';
    END IF;
    IF r.visitor_key IS NULL OR r.visitor_key !~ '^[0-9a-f]{64}$' THEN
        RAISE EXCEPTION 'E_PARSE: visitor_key must be 64 lower-case hexadecimal digits';
    END IF;
    IF r.submissions IS NULL OR r.submissions < 1 THEN
        RAISE EXCEPTION 'E_PARSE: submissions must be 1 or more';
    END IF;
END
$$;

CREATE TRIGGER guard BEFORE INSERT OR UPDATE ON core.submission_count
    FOR EACH ROW EXECUTE FUNCTION core.guard();

-- ---------------------------------------------------------------------------
-- Privileges on the new columns, tables, view and functions.
-- ---------------------------------------------------------------------------

GRANT SELECT ON pub.component_health TO pub_ro;

GRANT INSERT (source), UPDATE (source) ON core.item TO muster;
GRANT UPDATE (held) ON core.queue TO muster;

GRANT SELECT, INSERT ON core.result TO muster;
GRANT UPDATE (payload, recorded_at) ON core.result TO muster;

GRANT SELECT, INSERT, DELETE ON core.lease_outcome TO muster;
GRANT UPDATE (lease, worker, call_name, call_arg, ack_state, ack_next, ack_held, recorded_at)
    ON core.lease_outcome TO muster;

GRANT SELECT, INSERT ON core.component_health TO muster;
GRANT UPDATE (state, error_code, digest, reported_at) ON core.component_health TO muster;

GRANT SELECT, INSERT, DELETE ON core.submission_count TO muster;
GRANT UPDATE (submissions) ON core.submission_count TO muster;

REVOKE ALL ON FUNCTION
    core.item_sources(),
    core.health_states(),
    core.lease_calls(),
    core.require_known_slug(text, text, text[]),
    core.require_relative_path(text, text, integer),
    core.check_result(core.result),
    core.check_lease_outcome(core.lease_outcome),
    core.check_component_health(core.component_health),
    core.check_submission_count(core.submission_count)
FROM PUBLIC;

GRANT EXECUTE ON FUNCTION
    core.item_sources(),
    core.health_states(),
    core.lease_calls(),
    core.require_known_slug(text, text, text[]),
    core.require_relative_path(text, text, integer),
    core.check_result(core.result),
    core.check_lease_outcome(core.lease_outcome),
    core.check_component_health(core.component_health),
    core.check_submission_count(core.submission_count)
TO muster;

-- ---------------------------------------------------------------------------
-- Integrity checks: cover the four new working tables and the new public view.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION core.integrity_check()
RETURNS TABLE (check_name text, failures bigint)
LANGUAGE sql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
SELECT c.check_name, c.failures
FROM (VALUES
    (1,  'item rows are well-formed', core.malformed_rows('item')),
    (2,  'evaluation rows are well-formed', core.malformed_rows('evaluation')),
    (3,  'decision rows are well-formed', core.malformed_rows('decision')),
    (4,  'edit_proposal rows are well-formed', core.malformed_rows('edit_proposal')),
    (5,  'queue rows are well-formed', core.malformed_rows('queue')),
    (6,  'pause rows are well-formed', core.malformed_rows('pause')),
    (7,  'ledger rows are well-formed', core.malformed_rows('ledger')),
    (8,  'restore_drill rows are well-formed', core.malformed_rows('restore_drill')),
    (9,  'result rows are well-formed', core.malformed_rows('result')),
    (10, 'lease_outcome rows are well-formed', core.malformed_rows('lease_outcome')),
    (11, 'component_health rows are well-formed', core.malformed_rows('component_health')),
    (12, 'submission_count rows are well-formed', core.malformed_rows('submission_count')),

    (13, 'each item is in the state its last ledger entry gave it',
        (SELECT count(*)
         FROM core.item i
         WHERE i.state IS DISTINCT FROM (
             SELECT l.to_state FROM core.ledger l
             WHERE l.item_id = i.item_id
             ORDER BY l.entry_id DESC LIMIT 1))),

    (14, 'each item ledger entry starts where the one before it ended',
        (SELECT count(*)
         FROM (SELECT l.from_state,
                      lag(l.to_state) OVER (PARTITION BY l.item_id ORDER BY l.entry_id) AS state_before
               FROM core.ledger l
               WHERE l.item_id IS NOT NULL) trail
         WHERE trail.from_state IS DISTINCT FROM trail.state_before)),

    (15, 'each proposal has the status its last ledger entry gave it',
        (SELECT count(*)
         FROM core.edit_proposal p
         WHERE p.status IS DISTINCT FROM (
             SELECT l.to_state FROM core.ledger l
             WHERE l.proposal_id = p.proposal_id
             ORDER BY l.entry_id DESC LIMIT 1))),

    (16, 'each proposal ledger entry starts where the one before it ended',
        (SELECT count(*)
         FROM (SELECT l.from_state,
                      lag(l.to_state) OVER (PARTITION BY l.proposal_id ORDER BY l.entry_id) AS status_before
               FROM core.ledger l
               WHERE l.proposal_id IS NOT NULL) trail
         WHERE trail.from_state IS DISTINCT FROM trail.status_before)),

    (17, 'an item is in needs_subtool exactly when it has an open pause',
        (SELECT count(*)
         FROM core.item i
         WHERE (i.state = 'needs_subtool') <> EXISTS (
             SELECT FROM core.pause p
             WHERE p.item_id = i.item_id AND p.replayed_at IS NULL))),

    (18, 'each public view shows every row of its working table',
        abs((SELECT count(*) FROM pub.item) - (SELECT count(*) FROM core.item))
      + abs((SELECT count(*) FROM pub.item_history)
            - (SELECT count(*) FROM core.ledger WHERE item_id IS NOT NULL))
      + abs((SELECT count(*) FROM pub.evaluation) - (SELECT count(*) FROM core.evaluation))
      + abs((SELECT count(*) FROM pub.decision) - (SELECT count(*) FROM core.decision))
      + abs((SELECT count(*) FROM pub.pause) - (SELECT count(*) FROM core.pause))
      + abs((SELECT count(*) FROM pub.edit_proposal) - (SELECT count(*) FROM core.edit_proposal))
      + abs((SELECT count(*) FROM pub.restore_drill) - (SELECT count(*) FROM core.restore_drill))
      + abs((SELECT count(*) FROM pub.component_health) - (SELECT count(*) FROM core.component_health))),

    (19, 'no public view shows the text of an unapproved proposal',
        (SELECT count(*)
         FROM pub.edit_proposal shown
         JOIN core.edit_proposal p ON p.proposal_id = shown.proposal_id
         WHERE shown.payload IS NOT NULL
           AND p.status NOT IN ('approved', 'building', 'live')))
) AS c (position, check_name, failures)
ORDER BY c.position;
$$;

REVOKE ALL ON FUNCTION core.integrity_check() FROM PUBLIC, muster;
