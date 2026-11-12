-- A database whose only publication is a snapshot publication: no log
-- reader agent exists for it. snaponly-teardown.sql removes everything.
SET NOCOUNT ON;
CREATE DATABASE m_snaponly;
GO
USE m_snaponly;
CREATE TABLE dbo.m_so1 (id int PRIMARY KEY, a int);
EXEC sp_replicationdboption @dbname = N'm_snaponly', @optname = N'publish', @value = N'true';
EXEC sp_addpublication @publication = N'm_so', @status = N'active', @repl_freq = N'snapshot',
     @independent_agent = N'true', @immediate_sync = N'false';
-- The snapshot agent's schedule never fires: once, on 9999-12-31.
EXEC sp_addpublication_snapshot @publication = N'm_so', @frequency_type = 1, @active_start_date = 99991231,
     @publisher_security_mode = 1;
EXEC sp_addarticle @publication = N'm_so', @article = N'm_so1', @source_owner = N'dbo', @source_object = N'm_so1';
