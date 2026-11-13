-- Logbook migration 0002: the working records (the core schema).
--
-- Three kinds of object are made here:
--   1. Known sets: the item states, lanes, workers and so on. They change only
--      by migration.
--   2. Working tables: items, the queue, evaluations, decisions, edit
--      proposals, the ledger and restore drills.
--   3. Rules: one trigger function for each working table. A row that breaks a
--      rule is refused with a public error code and a fixed message.
--
-- Why rules are triggers and not CHECK constraints: when PostgreSQL refuses a
-- row on a CHECK or NOT NULL constraint it prints the whole row, and a row can
-- hold a lease token. The rules run first and print a fixed message that never
-- repeats a value. The NOT NULL and foreign-key constraints stay as a second
-- line of defence.
--
-- Every rule is one line that calls core.refuse_parse or
-- core.refuse_unfamiliar with its message. The tests read those lines to prove
-- that each rule has a saved example, so keep one call to a line.

BEGIN;

INSERT INTO core.migration (version, name) VALUES (2, 'working_records');

-- ---------------------------------------------------------------------------
-- Refusals
-- ---------------------------------------------------------------------------

-- E_PARSE: the data was broken.
CREATE FUNCTION core.refuse_parse(rule text) RETURNS void
LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
  RAISE EXCEPTION 'E_PARSE: %', rule USING ERRCODE = '22000';
END
$$;

-- E_NEEDS_SUBTOOL: the data was valid and unfamiliar.
CREATE FUNCTION core.refuse_unfamiliar(rule text) RETURNS void
LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
  RAISE EXCEPTION 'E_NEEDS_SUBTOOL: %', rule USING ERRCODE = '0A000';
END
$$;

-- ---------------------------------------------------------------------------
-- Known sets
-- ---------------------------------------------------------------------------

-- The fourteen states of an item.
CREATE TABLE core.item_state (
  state text PRIMARY KEY
);

INSERT INTO core.item_state (state) VALUES
  ('discovered'), ('recorded'), ('observed'), ('screened-out'), ('scored'),
  ('approved'), ('building'), ('live'), ('parked'), ('linked'), ('merged'),
  ('rejected'), ('retired'), ('needs_subtool');

-- The three priority lanes, in the order a worker empties them.
CREATE TABLE core.lane (
  lane        text    PRIMARY KEY,
  drain_order integer NOT NULL UNIQUE
);

INSERT INTO core.lane (lane, drain_order) VALUES
  ('urgent', 1), ('normal', 2), ('backfill', 3);

-- The ten workers, by their names in the naming registry.
CREATE TABLE core.worker (
  worker text    PRIMARY KEY,
  stage  integer NOT NULL UNIQUE
);

INSERT INTO core.worker (worker, stage) VALUES
  ('trawl', 1), ('sextant', 2), ('assay', 3), ('countersign', 4), ('waybill', 5),
  ('moldloft', 6), ('shakedown', 7), ('chartroom', 8), ('tidegauge', 9),
  ('bellbuoy', 10);

-- What a queue entry can be. One status follows from each call a worker makes
-- (lease, complete, fail, needs_subtool), plus waiting for an entry no worker
-- has taken.
CREATE TABLE core.queue_status (
  status text PRIMARY KEY
);

INSERT INTO core.queue_status (status) VALUES
  ('waiting'), ('leased'), ('completed'), ('failed'), ('needs_subtool');

-- What the owner can decide. The first four are also what a score can
-- recommend.
CREATE TABLE core.outcome (
  outcome       text    PRIMARY KEY,
  recommendable boolean NOT NULL
);

INSERT INTO core.outcome (outcome, recommendable) VALUES
  ('build', true), ('link', true), ('park', true), ('reject', true),
  ('merge', false), ('override', false);

-- The three kinds of edit a reader can propose.
CREATE TABLE core.edit_kind (
  kind text PRIMARY KEY
);

INSERT INTO core.edit_kind (kind) VALUES ('DATA'), ('CONFIG'), ('ISSUE');

-- Where an edit proposal stands.
CREATE TABLE core.edit_status (
  status text PRIMARY KEY
);

INSERT INTO core.edit_status (status) VALUES
  ('pending_approval'), ('approved'), ('building'), ('live'), ('declined');

-- ---------------------------------------------------------------------------
-- Items
-- ---------------------------------------------------------------------------

CREATE TABLE core.item (
  item_id     text        PRIMARY KEY,
  state       text        NOT NULL REFERENCES core.item_state,
  title       text        NOT NULL,
  source_url  text        NOT NULL,
  source_hash text        NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT transaction_timestamp(),
  updated_at  timestamptz NOT NULL DEFAULT transaction_timestamp()
);

-- Not unique: a rejected candidate may be sent in again as a new item.
CREATE INDEX item_source_hash ON core.item (source_hash);

CREATE FUNCTION core.item_rules() RETURNS trigger
LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
  IF NEW.item_id IS NULL THEN PERFORM core.refuse_parse('item.item_id is required'); END IF;
  IF NEW.state IS NULL THEN PERFORM core.refuse_parse('item.state is required'); END IF;
  IF NEW.title IS NULL THEN PERFORM core.refuse_parse('item.title is required'); END IF;
  IF NEW.source_url IS NULL THEN PERFORM core.refuse_parse('item.source_url is required'); END IF;
  IF NEW.source_hash IS NULL THEN PERFORM core.refuse_parse('item.source_hash is required'); END IF;
  IF NEW.created_at IS NULL THEN PERFORM core.refuse_parse('item.created_at is required'); END IF;
  IF NEW.updated_at IS NULL THEN PERFORM core.refuse_parse('item.updated_at is required'); END IF;

  IF NEW.item_id !~ '^PA-[0-9]{4}$' THEN
    PERFORM core.refuse_parse('item.item_id must be PA- followed by four digits');
  END IF;
  IF btrim(NEW.title) = '' THEN
    PERFORM core.refuse_parse('item.title must not be blank');
  END IF;
  IF btrim(NEW.source_url) = '' THEN
    PERFORM core.refuse_parse('item.source_url must not be blank');
  END IF;
  IF NEW.source_hash !~ '^[0-9a-f]{64}$' THEN
    PERFORM core.refuse_parse('item.source_hash must be 64 lowercase hexadecimal characters');
  END IF;
  IF NOT EXISTS (SELECT FROM core.item_state s WHERE s.state = NEW.state) THEN
    PERFORM core.refuse_unfamiliar('item.state is not a known item state');
  END IF;
  RETURN NEW;
END
$$;

CREATE TRIGGER item_rules BEFORE INSERT OR UPDATE ON core.item
  FOR EACH ROW EXECUTE FUNCTION core.item_rules();

-- ---------------------------------------------------------------------------
-- Evaluation outcomes
-- ---------------------------------------------------------------------------

CREATE TABLE core.evaluation (
  evaluation_id  bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  item_id        text        NOT NULL REFERENCES core.item,
  gates_passed   boolean     NOT NULL,
  reason         text,
  score          integer,
  recommendation text        REFERENCES core.outcome,
  evaluated_at   timestamptz NOT NULL DEFAULT transaction_timestamp()
);

CREATE INDEX evaluation_item ON core.evaluation (item_id);

CREATE FUNCTION core.evaluation_rules() RETURNS trigger
LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
  IF NEW.item_id IS NULL THEN PERFORM core.refuse_parse('evaluation.item_id is required'); END IF;
  IF NEW.gates_passed IS NULL THEN PERFORM core.refuse_parse('evaluation.gates_passed is required'); END IF;
  IF NEW.evaluated_at IS NULL THEN PERFORM core.refuse_parse('evaluation.evaluated_at is required'); END IF;

  IF NEW.gates_passed THEN
    IF NEW.score IS NULL OR NEW.score < 20 OR NEW.score > 100 THEN
      PERFORM core.refuse_parse('evaluation.score must be 20 to 100 when the gates are passed');
    END IF;
    IF NEW.recommendation IS NULL THEN
      PERFORM core.refuse_parse('evaluation.recommendation is required when the gates are passed');
    END IF;
    IF NOT EXISTS (SELECT FROM core.outcome o WHERE o.outcome = NEW.recommendation AND o.recommendable) THEN
      PERFORM core.refuse_unfamiliar('evaluation.recommendation is not a known recommendation');
    END IF;
  ELSE
    IF NEW.reason IS NULL OR btrim(NEW.reason) = '' THEN
      PERFORM core.refuse_parse('evaluation.reason is required when a gate is failed');
    END IF;
    IF NEW.score IS NOT NULL OR NEW.recommendation IS NOT NULL THEN
      PERFORM core.refuse_parse('evaluation.score and recommendation must be empty when a gate is failed');
    END IF;
  END IF;
  RETURN NEW;
END
$$;

CREATE TRIGGER evaluation_rules BEFORE INSERT OR UPDATE ON core.evaluation
  FOR EACH ROW EXECUTE FUNCTION core.evaluation_rules();

-- ---------------------------------------------------------------------------
-- Decision trail
-- ---------------------------------------------------------------------------

CREATE TABLE core.decision (
  decision_id bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  item_id     text        NOT NULL REFERENCES core.item,
  outcome     text        NOT NULL REFERENCES core.outcome,
  reason      text        NOT NULL DEFAULT '',
  decided_at  timestamptz NOT NULL DEFAULT transaction_timestamp()
);

CREATE INDEX decision_item ON core.decision (item_id);

CREATE FUNCTION core.decision_rules() RETURNS trigger
LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
  IF NEW.item_id IS NULL THEN PERFORM core.refuse_parse('decision.item_id is required'); END IF;
  IF NEW.outcome IS NULL THEN PERFORM core.refuse_parse('decision.outcome is required'); END IF;
  IF NEW.reason IS NULL THEN PERFORM core.refuse_parse('decision.reason is required'); END IF;
  IF NEW.decided_at IS NULL THEN PERFORM core.refuse_parse('decision.decided_at is required'); END IF;

  IF NOT EXISTS (SELECT FROM core.outcome o WHERE o.outcome = NEW.outcome) THEN
    PERFORM core.refuse_unfamiliar('decision.outcome is not a known outcome');
  END IF;
  IF NEW.outcome = 'override' AND btrim(NEW.reason) = '' THEN
    PERFORM core.refuse_parse('decision.reason must not be blank for an override');
  END IF;
  RETURN NEW;
END
$$;

CREATE TRIGGER decision_rules BEFORE INSERT OR UPDATE ON core.decision
  FOR EACH ROW EXECUTE FUNCTION core.decision_rules();

-- ---------------------------------------------------------------------------
-- Edit proposals
-- ---------------------------------------------------------------------------

CREATE TABLE core.edit_proposal (
  proposal_id  bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  kind         text        NOT NULL REFERENCES core.edit_kind,
  target       text        NOT NULL,
  payload      text        NOT NULL,
  status       text        NOT NULL REFERENCES core.edit_status,
  submitted_at timestamptz NOT NULL DEFAULT transaction_timestamp()
);

CREATE FUNCTION core.edit_proposal_rules() RETURNS trigger
LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
  IF NEW.kind IS NULL THEN PERFORM core.refuse_parse('edit_proposal.kind is required'); END IF;
  IF NEW.target IS NULL THEN PERFORM core.refuse_parse('edit_proposal.target is required'); END IF;
  IF NEW.payload IS NULL THEN PERFORM core.refuse_parse('edit_proposal.payload is required'); END IF;
  IF NEW.status IS NULL THEN PERFORM core.refuse_parse('edit_proposal.status is required'); END IF;
  IF NEW.submitted_at IS NULL THEN PERFORM core.refuse_parse('edit_proposal.submitted_at is required'); END IF;

  IF btrim(NEW.target) = '' THEN
    PERFORM core.refuse_parse('edit_proposal.target must not be blank');
  END IF;
  IF octet_length(NEW.payload) > 4096 THEN
    PERFORM core.refuse_parse('edit_proposal.payload must be at most 4096 bytes');
  END IF;
  IF NOT EXISTS (SELECT FROM core.edit_kind k WHERE k.kind = NEW.kind) THEN
    PERFORM core.refuse_unfamiliar('edit_proposal.kind is not a known kind of edit');
  END IF;
  IF NOT EXISTS (SELECT FROM core.edit_status s WHERE s.status = NEW.status) THEN
    PERFORM core.refuse_unfamiliar('edit_proposal.status is not a known proposal status');
  END IF;
  RETURN NEW;
END
$$;

CREATE TRIGGER edit_proposal_rules BEFORE INSERT OR UPDATE ON core.edit_proposal
  FOR EACH ROW EXECUTE FUNCTION core.edit_proposal_rules();

-- ---------------------------------------------------------------------------
-- The queue and its leases
-- ---------------------------------------------------------------------------

CREATE TABLE core.queue (
  queue_id         bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  item_id          text        REFERENCES core.item,
  proposal_id      bigint      REFERENCES core.edit_proposal,
  worker           text        NOT NULL REFERENCES core.worker,
  lane             text        NOT NULL REFERENCES core.lane,
  status           text        NOT NULL REFERENCES core.queue_status,
  lease_token      text,
  lease_expires_at timestamptz,
  heartbeat_at     timestamptz,
  error_code       text,
  enqueued_at      timestamptz NOT NULL DEFAULT transaction_timestamp()
);

-- What a worker's next lease is chosen from.
CREATE INDEX queue_waiting ON core.queue (worker, lane, queue_id) WHERE status = 'waiting';
CREATE INDEX queue_item ON core.queue (item_id);
CREATE INDEX queue_proposal ON core.queue (proposal_id);

CREATE FUNCTION core.queue_rules() RETURNS trigger
LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
  IF NEW.worker IS NULL THEN PERFORM core.refuse_parse('queue.worker is required'); END IF;
  IF NEW.lane IS NULL THEN PERFORM core.refuse_parse('queue.lane is required'); END IF;
  IF NEW.status IS NULL THEN PERFORM core.refuse_parse('queue.status is required'); END IF;
  IF NEW.enqueued_at IS NULL THEN PERFORM core.refuse_parse('queue.enqueued_at is required'); END IF;

  IF NOT EXISTS (SELECT FROM core.worker w WHERE w.worker = NEW.worker) THEN
    PERFORM core.refuse_unfamiliar('queue.worker is not a known worker');
  END IF;
  IF NOT EXISTS (SELECT FROM core.lane l WHERE l.lane = NEW.lane) THEN
    PERFORM core.refuse_unfamiliar('queue.lane is not a known lane');
  END IF;
  IF NOT EXISTS (SELECT FROM core.queue_status s WHERE s.status = NEW.status) THEN
    PERFORM core.refuse_unfamiliar('queue.status is not a known queue status');
  END IF;

  IF NEW.item_id IS NOT NULL AND NEW.proposal_id IS NOT NULL THEN
    PERFORM core.refuse_parse('a queue entry may name an item or a proposal, not both');
  END IF;

  IF NEW.status = 'leased' THEN
    IF NEW.lease_token IS NULL OR NEW.lease_token = '' OR NEW.lease_expires_at IS NULL THEN
      PERFORM core.refuse_parse('a leased queue entry needs lease_token and lease_expires_at');
    END IF;
  ELSIF NEW.lease_token IS NOT NULL OR NEW.lease_expires_at IS NOT NULL THEN
    PERFORM core.refuse_parse('only a leased queue entry may hold lease_token or lease_expires_at');
  END IF;

  IF NEW.status = 'needs_subtool' THEN
    IF NEW.error_code IS DISTINCT FROM 'E_NEEDS_SUBTOOL' THEN
      PERFORM core.refuse_parse('queue.error_code must be E_NEEDS_SUBTOOL when status is needs_subtool');
    END IF;
  ELSIF NEW.status = 'failed' THEN
    IF NEW.error_code IS NULL OR NEW.error_code NOT IN ('E_TIMEOUT', 'E_PARSE') THEN
      PERFORM core.refuse_parse('queue.error_code must be E_TIMEOUT or E_PARSE when status is failed');
    END IF;
  ELSIF NEW.error_code IS NOT NULL THEN
    PERFORM core.refuse_parse('only a failed or needs_subtool queue entry may hold error_code');
  END IF;
  RETURN NEW;
END
$$;

CREATE TRIGGER queue_rules BEFORE INSERT OR UPDATE ON core.queue
  FOR EACH ROW EXECUTE FUNCTION core.queue_rules();

-- ---------------------------------------------------------------------------
-- The append-only ledger
-- ---------------------------------------------------------------------------

-- One row for each change of state of an item, or change of status of an edit
-- proposal. from_state is empty for the first entry about a subject. worker is
-- the worker whose result caused the change, and is empty when the owner or
-- Muster caused it.
CREATE TABLE core.ledger (
  ledger_id   bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  item_id     text        REFERENCES core.item,
  proposal_id bigint      REFERENCES core.edit_proposal,
  from_state  text,
  to_state    text        NOT NULL,
  worker      text        REFERENCES core.worker,
  recorded_at timestamptz NOT NULL DEFAULT transaction_timestamp()
);

CREATE INDEX ledger_item ON core.ledger (item_id);
CREATE INDEX ledger_proposal ON core.ledger (proposal_id);

CREATE FUNCTION core.ledger_rules() RETURNS trigger
LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
  IF NEW.to_state IS NULL THEN PERFORM core.refuse_parse('ledger.to_state is required'); END IF;
  IF NEW.recorded_at IS NULL THEN PERFORM core.refuse_parse('ledger.recorded_at is required'); END IF;

  IF (NEW.item_id IS NULL) = (NEW.proposal_id IS NULL) THEN
    PERFORM core.refuse_parse('a ledger entry must name exactly one item or proposal');
  END IF;

  IF NEW.item_id IS NOT NULL THEN
    IF NOT EXISTS (SELECT FROM core.item_state s WHERE s.state = NEW.to_state) THEN
      PERFORM core.refuse_unfamiliar('ledger.to_state is not a known item state');
    END IF;
    IF NEW.from_state IS NOT NULL AND NOT EXISTS (SELECT FROM core.item_state s WHERE s.state = NEW.from_state) THEN
      PERFORM core.refuse_unfamiliar('ledger.from_state is not a known item state');
    END IF;
  ELSE
    IF NOT EXISTS (SELECT FROM core.edit_status s WHERE s.status = NEW.to_state) THEN
      PERFORM core.refuse_unfamiliar('ledger.to_state is not a known proposal status');
    END IF;
    IF NEW.from_state IS NOT NULL AND NOT EXISTS (SELECT FROM core.edit_status s WHERE s.status = NEW.from_state) THEN
      PERFORM core.refuse_unfamiliar('ledger.from_state is not a known proposal status');
    END IF;
  END IF;

  IF NEW.worker IS NOT NULL AND NOT EXISTS (SELECT FROM core.worker w WHERE w.worker = NEW.worker) THEN
    PERFORM core.refuse_unfamiliar('ledger.worker is not a known worker');
  END IF;
  RETURN NEW;
END
$$;

CREATE TRIGGER ledger_rules BEFORE INSERT ON core.ledger
  FOR EACH ROW EXECUTE FUNCTION core.ledger_rules();

-- Append-only. core_rw is given no right to change the ledger, so it is
-- refused by PostgreSQL before this runs. This trigger refuses everybody else,
-- the owner of the table included, and it refuses the attempt itself, even one
-- that would have touched no row.
CREATE FUNCTION core.ledger_append_only() RETURNS trigger
LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
  RAISE EXCEPTION 'permission denied: the ledger is append-only' USING ERRCODE = '42501';
END
$$;

CREATE TRIGGER ledger_append_only BEFORE UPDATE OR DELETE OR TRUNCATE ON core.ledger
  FOR EACH STATEMENT EXECUTE FUNCTION core.ledger_append_only();

-- ---------------------------------------------------------------------------
-- Restore drills
-- ---------------------------------------------------------------------------

-- One row for each monthly restore drill: when it ran and the outcome of each
-- of the four checks. passed is worked out from the four and cannot be set.
CREATE TABLE core.restore_drill (
  drill_id          bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  ran_at            timestamptz NOT NULL,
  decrypt_passed    boolean     NOT NULL,
  database_passed   boolean     NOT NULL,
  plainforge_passed boolean     NOT NULL,
  lazarette_passed  boolean     NOT NULL,
  passed            boolean     GENERATED ALWAYS AS
    (decrypt_passed AND database_passed AND plainforge_passed AND lazarette_passed) STORED
);

CREATE FUNCTION core.restore_drill_rules() RETURNS trigger
LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
  IF NEW.ran_at IS NULL THEN PERFORM core.refuse_parse('restore_drill.ran_at is required'); END IF;
  IF NEW.decrypt_passed IS NULL THEN PERFORM core.refuse_parse('restore_drill.decrypt_passed is required'); END IF;
  IF NEW.database_passed IS NULL THEN PERFORM core.refuse_parse('restore_drill.database_passed is required'); END IF;
  IF NEW.plainforge_passed IS NULL THEN PERFORM core.refuse_parse('restore_drill.plainforge_passed is required'); END IF;
  IF NEW.lazarette_passed IS NULL THEN PERFORM core.refuse_parse('restore_drill.lazarette_passed is required'); END IF;
  RETURN NEW;
END
$$;

CREATE TRIGGER restore_drill_rules BEFORE INSERT OR UPDATE ON core.restore_drill
  FOR EACH ROW EXECUTE FUNCTION core.restore_drill_rules();

-- ---------------------------------------------------------------------------
-- Privileges
-- ---------------------------------------------------------------------------

-- Muster. It reads the known sets and cannot change them. It adds to the
-- evaluations, the decisions, the ledger and the restore drills and cannot
-- rewrite them: a change of mind is a new row. It may delete only queue
-- entries.
GRANT SELECT ON
  core.item_state, core.lane, core.worker, core.queue_status, core.outcome,
  core.edit_kind, core.edit_status
  TO core_rw;
GRANT SELECT, INSERT, UPDATE ON core.item, core.edit_proposal TO core_rw;
GRANT SELECT, INSERT, UPDATE, DELETE ON core.queue TO core_rw;
GRANT SELECT, INSERT ON core.evaluation, core.decision, core.ledger, core.restore_drill TO core_rw;

-- The backup job reads everything in order to dump it, and writes nothing.
GRANT SELECT ON ALL TABLES IN SCHEMA core TO backup_ro;
GRANT SELECT ON ALL SEQUENCES IN SCHEMA core TO backup_ro;

-- Functions are callable by everyone unless that is taken away.
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA core FROM PUBLIC;
GRANT EXECUTE ON FUNCTION core.refuse_parse(text), core.refuse_unfamiliar(text) TO core_rw;

COMMIT;
