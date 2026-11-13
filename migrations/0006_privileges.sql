-- 0006: who may do what. Everything not granted here is refused.
--
-- A view or table added by a later migration needs its own grant in that
-- migration. The tests list every privilege, so a missing or extra one fails.

DO $$
BEGIN
    EXECUTE format('GRANT CONNECT ON DATABASE %I TO muster, pub_ro', current_database());
END
$$;

-- Conn, through pub_ro: read the public views. Nothing else.
GRANT USAGE ON SCHEMA pub TO pub_ro;
GRANT SELECT ON
    pub.item, pub.item_history,
    pub.evaluation, pub.evaluation_gate, pub.evaluation_factor,
    pub.decision, pub.queue_depth, pub.pause,
    pub.edit_proposal, pub.restore_drill
TO pub_ro;

-- Muster: read every working table, and write each one only in the way its
-- job needs. It cannot delete an item, change an identifier, rewrite a
-- proposal's text, or change any row of a table that is a trail.
GRANT USAGE ON SCHEMA core TO muster;
GRANT SELECT ON ALL TABLES IN SCHEMA core TO muster;

GRANT INSERT ON core.item TO muster;
GRANT UPDATE (state, title, address) ON core.item TO muster;
GRANT USAGE ON SEQUENCE core.item_number TO muster;

GRANT INSERT ON core.edit_proposal TO muster;
GRANT UPDATE (status, decided_at) ON core.edit_proposal TO muster;

GRANT INSERT, DELETE ON core.queue TO muster;
GRANT UPDATE (attempt, lease_token, leased_until, heartbeat_at) ON core.queue TO muster;

GRANT INSERT ON core.pause TO muster;
GRANT UPDATE (replayed_at) ON core.pause TO muster;

GRANT INSERT ON core.evaluation, core.decision, core.ledger, core.restore_drill TO muster;

-- The checks run inside Muster's own writes, so Muster must be able to call them.
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA core TO muster;
