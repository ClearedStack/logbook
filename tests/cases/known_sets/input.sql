-- The known sets. A value added, removed or renamed changes this output.

\echo == the migrations applied
SELECT version, name FROM core.migration ORDER BY version;

\echo == the fourteen item states
SELECT state FROM core.item_state ORDER BY state;

\echo == the three lanes, in the order they are emptied
SELECT lane, drain_order FROM core.lane ORDER BY drain_order;

\echo == the ten workers
SELECT worker, stage FROM core.worker ORDER BY stage;

\echo == the queue statuses
SELECT status FROM core.queue_status ORDER BY status;

\echo == the outcomes
SELECT outcome, recommendable FROM core.outcome ORDER BY outcome;

\echo == the kinds of edit
SELECT kind FROM core.edit_kind ORDER BY kind;

\echo == the proposal statuses
SELECT status FROM core.edit_status ORDER BY status;
