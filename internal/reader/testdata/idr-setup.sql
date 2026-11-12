-- Identity range management on a transactional publication (Task 12 fix 1):
-- m_id0 with the default (none), m_idm with manual, m_idn with manual on a
-- table without an identity column. idr-teardown.sql removes everything.
SET NOCOUNT ON;
USE Sales;
CREATE TABLE dbo.m_id0 (id int IDENTITY PRIMARY KEY, a int);
CREATE TABLE dbo.m_idm (id int IDENTITY PRIMARY KEY, a int);
CREATE TABLE dbo.m_idn (id int PRIMARY KEY, a int);
GO
USE Sales;
EXEC sp_addpublication @publication = N'm_idr', @status = N'active', @independent_agent = N'true', @immediate_sync = N'false';
EXEC sp_addarticle @publication = N'm_idr', @article = N'm_id0', @source_owner = N'dbo', @source_object = N'm_id0';
EXEC sp_addarticle @publication = N'm_idr', @article = N'm_idm', @source_owner = N'dbo', @source_object = N'm_idm',
     @identityrangemanagementoption = N'manual';
EXEC sp_addarticle @publication = N'm_idr', @article = N'm_idn', @source_owner = N'dbo', @source_object = N'm_idn',
     @identityrangemanagementoption = N'manual';
