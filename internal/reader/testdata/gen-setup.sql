-- A push publication whose snapshot agent is run by the test, to an m_
-- subscription database with no distribution agent: the first run generates
-- a snapshot for the subscription, the second finds nothing to do.
-- gen-teardown.sql removes everything.
SET NOCOUNT ON;
USE Sales;
CREATE TABLE dbo.m_gt1 (id int PRIMARY KEY, a int);
INSERT dbo.m_gt1 VALUES (1, 1), (2, 2);
CREATE DATABASE m_gsub;
GO
USE Sales;
EXEC sp_addpublication @publication = N'm_gen', @status = N'active',
     @independent_agent = N'true', @immediate_sync = N'false';
-- The snapshot agent's schedule never fires: once, on 9999-12-31.
EXEC sp_addpublication_snapshot @publication = N'm_gen', @frequency_type = 1, @active_start_date = 99991231,
     @publisher_security_mode = 1;
EXEC sp_addarticle @publication = N'm_gen', @article = N'm_gt1', @source_owner = N'dbo', @source_object = N'm_gt1';
GO
USE Sales;
DECLARE @srv sysname = @@SERVERNAME;
-- No sp_addpushsubscription_agent: no distribution agent delivers the snapshot.
EXEC sp_addsubscription @publication = N'm_gen', @subscriber = @srv, @destination_db = N'm_gsub',
     @subscription_type = N'push', @sync_type = N'automatic', @article = N'all';
