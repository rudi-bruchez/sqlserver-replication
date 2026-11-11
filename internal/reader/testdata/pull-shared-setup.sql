-- Two publications without an independent agent, pulled into one
-- subscription database of the lab instance itself: they share one pull
-- agent. pull-shared-teardown.sql removes everything.
SET NOCOUNT ON;
USE Sales;
CREATE TABLE dbo.m_pst1 (id int PRIMARY KEY, a int);
CREATE TABLE dbo.m_pst2 (id int PRIMARY KEY, a int);
CREATE DATABASE m_pssub;
GO
USE Sales;
EXEC sp_addpublication @publication = N'm_ps1', @status = N'active', @allow_pull = N'true',
     @independent_agent = N'false', @immediate_sync = N'false';
EXEC sp_addpublication_snapshot @publication = N'm_ps1', @frequency_type = 1, @active_start_date = 99991231,
     @publisher_security_mode = 1;
EXEC sp_addarticle @publication = N'm_ps1', @article = N'm_pst1', @source_owner = N'dbo', @source_object = N'm_pst1';
EXEC sp_addpublication @publication = N'm_ps2', @status = N'active', @allow_pull = N'true',
     @independent_agent = N'false', @immediate_sync = N'false';
EXEC sp_addpublication_snapshot @publication = N'm_ps2', @frequency_type = 1, @active_start_date = 99991231,
     @publisher_security_mode = 1;
EXEC sp_addarticle @publication = N'm_ps2', @article = N'm_pst2', @source_owner = N'dbo', @source_object = N'm_pst2';
GO
USE Sales;
DECLARE @srv sysname = @@SERVERNAME;
EXEC sp_addsubscription @publication = N'm_ps1', @subscriber = @srv, @destination_db = N'm_pssub',
     @subscription_type = N'pull', @sync_type = N'automatic', @article = N'all';
EXEC sp_addsubscription @publication = N'm_ps2', @subscriber = @srv, @destination_db = N'm_pssub',
     @subscription_type = N'pull', @sync_type = N'automatic', @article = N'all';
GO
USE m_pssub;
DECLARE @srv sysname = @@SERVERNAME;
EXEC sp_addpullsubscription @publisher = @srv, @publisher_db = N'Sales', @publication = N'm_ps1',
     @subscription_type = N'pull', @independent_agent = N'false', @immediate_sync = N'false';
EXEC sp_addpullsubscription_agent @publisher = @srv, @publisher_db = N'Sales', @publication = N'm_ps1',
     @distributor = @srv, @subscriber_security_mode = 1, @distributor_security_mode = 1;
EXEC sp_addpullsubscription @publisher = @srv, @publisher_db = N'Sales', @publication = N'm_ps2',
     @subscription_type = N'pull', @independent_agent = N'false', @immediate_sync = N'false';
EXEC sp_addpullsubscription_agent @publisher = @srv, @publisher_db = N'Sales', @publication = N'm_ps2',
     @distributor = @srv, @subscriber_security_mode = 1, @distributor_security_mode = 1;
