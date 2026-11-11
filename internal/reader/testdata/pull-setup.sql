-- A pull subscription of the lab instance to itself, after
-- lab/campaign/08-pull.sh:126-158. The lab test splits the script on GO and
-- runs each batch on one connection; pull-teardown.sql removes everything.
SET NOCOUNT ON;
USE Sales;
CREATE TABLE dbo.m_pt1 (id int PRIMARY KEY, a int);
CREATE DATABASE m_psub;
GO
USE Sales;
EXEC sp_addpublication @publication = N'm_pp', @status = N'active', @allow_pull = N'true',
     @independent_agent = N'true', @immediate_sync = N'false';
-- The snapshot agent's schedule never fires: once, on 9999-12-31.
EXEC sp_addpublication_snapshot @publication = N'm_pp', @frequency_type = 1, @active_start_date = 99991231,
     @publisher_security_mode = 1;
EXEC sp_addarticle @publication = N'm_pp', @article = N'm_pt1', @source_owner = N'dbo', @source_object = N'm_pt1';
GO
USE Sales;
DECLARE @srv sysname = @@SERVERNAME;
-- Without @subscriber the call is refused with 14043.
EXEC sp_addsubscription @publication = N'm_pp', @subscriber = @srv, @destination_db = N'm_psub',
     @subscription_type = N'pull', @sync_type = N'automatic', @article = N'all';
GO
USE m_psub;
DECLARE @srv sysname = @@SERVERNAME;
-- independent_agent and immediate_sync default to 1 when omitted: the
-- publication's values are passed.
EXEC sp_addpullsubscription @publisher = @srv, @publisher_db = N'Sales', @publication = N'm_pp',
     @subscription_type = N'pull', @independent_agent = N'true', @immediate_sync = N'false';
-- No frequency parameter: the job has no schedule
-- (11-defaults D.sp_addpullsubscription_agent.pull.@frequency_type).
EXEC sp_addpullsubscription_agent @publisher = @srv, @publisher_db = N'Sales', @publication = N'm_pp',
     @distributor = @srv, @subscriber_security_mode = 1, @distributor_security_mode = 1;
