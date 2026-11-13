-- The read-only role, pub_ro, reads the public views and cannot reach a
-- working table.

\echo == as pub_ro: every working table is refused
SET ROLE pub_ro;
SELECT * FROM core.item;
SELECT * FROM core.queue;
SELECT * FROM core.evaluation;
SELECT * FROM core.decision;
SELECT * FROM core.edit_proposal;
SELECT * FROM core.ledger;
SELECT * FROM core.restore_drill;
SELECT * FROM core.item_state;
SELECT * FROM core.migration;

\echo == as pub_ro: every public view can be read
SELECT count(*) AS item FROM pub.item;
SELECT count(*) AS item_history FROM pub.item_history;
SELECT count(*) AS evaluation FROM pub.evaluation;
SELECT count(*) AS decision FROM pub.decision;
SELECT count(*) AS queue_length FROM pub.queue_length;
SELECT count(*) AS edit_proposal FROM pub.edit_proposal;
SELECT count(*) AS restore_drill FROM pub.restore_drill;

\echo == as pub_ro: nothing can be written or made
INSERT INTO pub.item (item_id, title, state) VALUES ('PA-0001', 'Example', 'recorded');
UPDATE pub.item SET title = 'Example';
DELETE FROM pub.item;
CREATE TABLE pub.example (n integer);
CREATE TABLE public.example (n integer);
CREATE TEMPORARY TABLE example (n integer);
SELECT core.refuse_parse('example');
RESET ROLE;

\echo == if the schema were ever opened to pub_ro by mistake, each table would still refuse
GRANT USAGE ON SCHEMA core TO pub_ro;
SET ROLE pub_ro;
SELECT * FROM core.item;
SELECT * FROM core.queue;
SELECT * FROM core.evaluation;
SELECT * FROM core.decision;
SELECT * FROM core.edit_proposal;
SELECT * FROM core.ledger;
SELECT * FROM core.restore_drill;
SELECT * FROM core.item_state;
SELECT * FROM core.migration;
RESET ROLE;
REVOKE USAGE ON SCHEMA core FROM pub_ro;

\echo == a login that is a member of pub_ro, connecting for itself
CREATE ROLE example_conn LOGIN IN ROLE pub_ro;
\connect - example_conn
SELECT current_user;
SELECT count(*) AS item FROM pub.item;
SELECT * FROM core.item;
SET ROLE core_rw;
SET ROLE backup_ro;
\connect - postgres
DROP ROLE example_conn;

\echo == a login that is a member of no role cannot connect at all
CREATE ROLE example_stranger LOGIN;
SELECT has_database_privilege('example_stranger', current_database(), 'CONNECT') AS may_connect;
DROP ROLE example_stranger;
