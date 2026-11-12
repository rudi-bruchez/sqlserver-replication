-- Creates the publication database {db} with the tables dbo.m_t1, dbo.m_t2
-- and dbo.m_t3, 20 rows each (id 1 to 20, a from -9 to 10, b = id), and the
-- empty subscriber database {sub}. Nothing is published: the plans of the
-- tests do that. teardown.sql removes everything.
SET NOCOUNT ON;
USE master;
CREATE DATABASE {db};
CREATE DATABASE {sub};
GO
USE {db};
CREATE TABLE dbo.m_t1 (id int PRIMARY KEY, a int, b int);
CREATE TABLE dbo.m_t2 (id int PRIMARY KEY, a int, b int);
CREATE TABLE dbo.m_t3 (id int PRIMARY KEY, a int, b int);
WITH n AS (SELECT TOP (20) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS id FROM sys.all_objects)
INSERT dbo.m_t1 (id, a, b) SELECT id, id - 10, id FROM n;
INSERT dbo.m_t2 (id, a, b) SELECT id, a, b FROM dbo.m_t1;
INSERT dbo.m_t3 (id, a, b) SELECT id, a, b FROM dbo.m_t1;
