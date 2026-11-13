-- 0005: the public views. Each one names its columns one by one, so a column
-- added to a working table is not published until someone adds it here.
--
-- Never published: an item's address or its hash, a lease token, and the text
-- of a proposal the owner has not approved.
--
-- A view may not call a function in core: whoever reads a view needs the right
-- to call every function it uses, and pub_ro has none in core.

CREATE VIEW pub.item WITH (security_barrier) AS
SELECT i.item_id,
       i.state,
       i.title,
       i.recorded_at,
       (SELECT max(l.recorded_at) FROM core.ledger l WHERE l.item_id = i.item_id) AS changed_at
FROM core.item i;
COMMENT ON VIEW pub.item IS 'Every item, with its state and when that last changed.';

CREATE VIEW pub.item_history WITH (security_barrier) AS
SELECT l.entry_id,
       l.item_id,
       l.actor,
       l.from_state,
       l.to_state,
       l.error_code,
       l.note,
       l.recorded_at
FROM core.ledger l
WHERE l.item_id IS NOT NULL;
COMMENT ON VIEW pub.item_history IS 'Every change of state of every item, oldest first by entry_id.';

CREATE VIEW pub.evaluation WITH (security_barrier) AS
SELECT e.evaluation_id,
       e.item_id,
       e.profile,
       NOT EXISTS (SELECT FROM jsonb_each(e.gates) g
                   WHERE NOT (g.value -> 'passed')::boolean) AS gates_passed,
       e.score,
       e.recommendation,
       e.split_flag,
       e.evaluated_at
FROM core.evaluation e;
COMMENT ON VIEW pub.evaluation IS 'Every evaluation: whether the gates passed, the score and the recommendation.';

CREATE VIEW pub.evaluation_gate WITH (security_barrier) AS
SELECT e.evaluation_id,
       e.item_id,
       g.key AS gate,
       (g.value -> 'passed')::boolean AS passed,
       g.value ->> 'reason' AS reason
FROM core.evaluation e
CROSS JOIN LATERAL jsonb_each(e.gates) g;
COMMENT ON VIEW pub.evaluation_gate IS 'The result of each gate in each evaluation, with the reason for a failure.';

CREATE VIEW pub.evaluation_factor WITH (security_barrier) AS
SELECT e.evaluation_id,
       e.item_id,
       f.key AS factor,
       (f.value ->> 'rating')::integer AS rating,
       (f.value ->> 'weight')::integer AS weight,
       (f.value ->> 'rating')::integer * (f.value ->> 'weight')::integer AS points
FROM core.evaluation e
CROSS JOIN LATERAL jsonb_each(e.factors) f;
COMMENT ON VIEW pub.evaluation_factor IS 'The breakdown of points for each evaluation that was scored.';

CREATE VIEW pub.decision WITH (security_barrier) AS
SELECT d.decision_id,
       e.item_id,
       d.evaluation_id,
       e.recommendation,
       d.outcome,
       d.outcome IS DISTINCT FROM e.recommendation AS overridden,
       d.reason,
       d.decided_at
FROM core.decision d
JOIN core.evaluation e ON e.evaluation_id = d.evaluation_id;
COMMENT ON VIEW pub.decision IS 'The decision log: what was recommended, what the owner chose, and the reason.';

CREATE VIEW pub.queue_depth WITH (security_barrier) AS
SELECT q.worker,
       q.lane,
       count(*) FILTER (WHERE q.leased_until IS NULL OR q.leased_until <= now()) AS waiting,
       count(*) FILTER (WHERE q.leased_until > now()) AS claimed
FROM core.queue q
GROUP BY q.worker, q.lane;
COMMENT ON VIEW pub.queue_depth IS 'How much work is waiting and how much is claimed, for each worker and lane that has any.';

CREATE VIEW pub.pause WITH (security_barrier) AS
SELECT p.pause_id,
       p.item_id,
       p.worker,
       p.pattern,
       p.paused_at,
       p.replayed_at
FROM core.pause p;
COMMENT ON VIEW pub.pause IS 'Every pause for a missing rule. replayed_at is empty while the item is still waiting.';

CREATE VIEW pub.edit_proposal WITH (security_barrier) AS
SELECT p.proposal_id,
       p.element_id,
       p.owner_repo,
       p.edit_class,
       p.status,
       CASE WHEN p.status IN ('approved', 'building', 'live') THEN p.payload END AS payload,
       p.submitted_at,
       p.decided_at
FROM core.edit_proposal p;
COMMENT ON VIEW pub.edit_proposal IS 'Every proposal and its status. The proposed text appears only once the owner has approved it.';

CREATE VIEW pub.restore_drill WITH (security_barrier) AS
SELECT d.drill_id,
       d.ran_at,
       d.passed,
       d.decrypt_passed,
       d.logbook_passed,
       d.plainforge_passed,
       d.lazarette_passed
FROM core.restore_drill d;
COMMENT ON VIEW pub.restore_drill IS 'When each restore drill ran, whether it passed, and the outcome of each of its four checks.';
