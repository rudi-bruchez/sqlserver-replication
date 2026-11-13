-- The databases of lab/fresh-apply.sh on m-fresh: the publication database
-- m_fresh_pub with dbo.m_t1 (primary key, 20 rows: id 1 to 20, a from -9 to
-- 10, b = id) and the empty subscriber database m_fresh_sub. Nothing is
-- published: sqlrepl apply of create.yaml does that. The container is removed
-- at the end, so there is no teardown.
SET NOCOUNT ON;
USE master;
CREATE DATABASE m_fresh_pub;
CREATE DATABASE m_fresh_sub;
GO
USE m_fresh_pub;
CREATE TABLE dbo.m_t1 (id int PRIMARY KEY, a int, b int);
WITH n AS (SELECT TOP (20) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS id FROM sys.all_objects)
INSERT dbo.m_t1 (id, a, b) SELECT id, id - 10, id FROM n;
