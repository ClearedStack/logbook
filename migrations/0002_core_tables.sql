-- Logbook migration 0002: the working tables (core schema).
--
-- These hold everything SPEC.md lists under "Single Source of Truth":
-- item records, evaluation outcomes, decision trails, queue leases,
-- anonymous edit proposals and the ledger, plus the restore drill results
-- that the Portal shows.

-- An item record, identified as PA-XXXX.
CREATE TABLE core.item (
    item_id    text        PRIMARY KEY CHECK (item_id ~ '^PA-[0-9]{4}$'),
    title      text        NOT NULL CHECK (title <> ''),
    summary    text        NOT NULL DEFAULT '',
    state      text        NOT NULL CHECK (state <> ''),
    -- Nothing about an item appears in pub.* until this is set to true.
    published  boolean     NOT NULL DEFAULT false,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

-- The outcome of evaluating an item. "detail" is internal working data.
CREATE TABLE core.evaluation (
    evaluation_id bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    item_id       text        NOT NULL REFERENCES core.item (item_id),
    outcome       text        NOT NULL CHECK (outcome <> ''),
    detail        jsonb       NOT NULL DEFAULT '{}'::jsonb,
    evaluated_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX evaluation_item_idx ON core.evaluation (item_id);

-- One step in an item's decision trail. "reason" is internal.
CREATE TABLE core.decision (
    decision_id bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    item_id     text        NOT NULL REFERENCES core.item (item_id),
    decision    text        NOT NULL CHECK (decision <> ''),
    reason      text        NOT NULL DEFAULT '',
    decided_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX decision_item_idx ON core.decision (item_id);

-- A queue step for an item and, while a worker holds it, its lease.
-- lease_token is an internal token and must never reach pub.*.
CREATE TABLE core.queue_lease (
    lease_id     bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    item_id      text        NOT NULL REFERENCES core.item (item_id),
    step         text        NOT NULL CHECK (step <> ''),
    status       text        NOT NULL CHECK (status <> ''),
    lease_token  uuid,
    leased_until timestamptz,
    created_at   timestamptz NOT NULL DEFAULT now(),
    -- A lease has both a token and an expiry, or neither.
    CHECK ((lease_token IS NULL) = (leased_until IS NULL))
);
CREATE INDEX queue_lease_item_idx ON core.queue_lease (item_id);

-- An anonymous edit proposal. There is deliberately no column that
-- identifies who sent it.
CREATE TABLE core.edit_proposal (
    proposal_id  bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    item_id      text        NOT NULL REFERENCES core.item (item_id),
    payload      jsonb       NOT NULL,
    status       text        NOT NULL DEFAULT 'pending'
                             CHECK (status IN ('pending', 'approved', 'rejected')),
    submitted_at timestamptz NOT NULL DEFAULT now(),
    decided_at   timestamptz,
    -- A proposal has a decision time exactly when it has been decided.
    CHECK ((status = 'pending') = (decided_at IS NULL))
);
CREATE INDEX edit_proposal_item_idx ON core.edit_proposal (item_id);

-- The ledger. Enforcing append-only is not part of this migration.
CREATE TABLE core.ledger (
    entry_id    bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    recorded_at timestamptz NOT NULL DEFAULT now(),
    item_id     text        REFERENCES core.item (item_id),
    kind        text        NOT NULL CHECK (kind <> ''),
    body        jsonb       NOT NULL DEFAULT '{}'::jsonb
);
CREATE INDEX ledger_item_idx ON core.ledger (item_id);

-- One monthly restore drill, and the outcome of each of its checks.
CREATE TABLE core.restore_drill (
    drill_id    bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    started_at  timestamptz NOT NULL,
    finished_at timestamptz,
    CHECK (finished_at IS NULL OR finished_at >= started_at)
);

CREATE TABLE core.restore_drill_check (
    drill_id   bigint      NOT NULL REFERENCES core.restore_drill (drill_id),
    check_name text        NOT NULL CHECK (check_name <> ''),
    passed     boolean     NOT NULL,
    checked_at timestamptz NOT NULL,
    PRIMARY KEY (drill_id, check_name)
);
