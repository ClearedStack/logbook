-- The read-only role cannot change anything, through the views or otherwise.
SET ROLE pub_ro;
\echo == writes through the public views are refused
INSERT INTO pub.item (item_id, title, summary, state) VALUES ('PA-0003', 'x', 'x', 'x');
UPDATE pub.item SET title = 'changed';
DELETE FROM pub.item;
TRUNCATE core.item;
\echo == creating objects is refused
CREATE TABLE pub.scratch (n int);
CREATE VIEW pub.peek AS SELECT 1;
CREATE TABLE core.scratch (n int);
\echo == nothing changed
RESET ROLE;
SELECT item_id, title FROM core.item ORDER BY item_id;
