-- Self-test fixture: leaves a distribution.dbo.MSpublisher_databases row for an m_
-- database, as sp_addlogreader_agent does when publish is disabled without dropping a
-- publication. Expected: GUARD residue. selftest.sh deletes it right after.
SET NOCOUNT ON;
INSERT distribution.dbo.MSpublisher_databases (publisher_id, publisher_db, publisher_engine_edition)
SELECT TOP (1) publisher_id, N'm_ghostdb', publisher_engine_edition FROM distribution.dbo.MSpublisher_databases WHERE publisher_db = N'Sales';
SELECT 'R|a|ok|';
SELECT 'R|TOTAL|1';
