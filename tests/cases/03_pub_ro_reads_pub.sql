-- The read-only role reads the public views and sees only what is meant to
-- be public: published items, approved proposals, finished drills.
SET ROLE pub_ro;
\echo == pub.item
SELECT * FROM pub.item ORDER BY item_id;
\echo == pub.evaluation
SELECT * FROM pub.evaluation ORDER BY item_id, evaluated_at;
\echo == pub.decision
SELECT * FROM pub.decision ORDER BY item_id, decided_at;
\echo == pub.edit_proposal
SELECT * FROM pub.edit_proposal ORDER BY item_id, decided_at;
\echo == pub.restore_drill
SELECT * FROM pub.restore_drill ORDER BY drill_id, check_name;
