-- A snapshot publication of Sales whose snapshot agent uses the m_ profile
-- m_prof_snap, for the profile uses of the empty configuration.
-- prof-teardown.sql removes everything.
SET NOCOUNT ON;
USE Sales;
CREATE TABLE dbo.m_pft1 (id int PRIMARY KEY, a int);
GO
USE Sales;
EXEC sp_addpublication @publication = N'm_prof', @status = N'active', @repl_freq = N'snapshot',
     @independent_agent = N'true', @immediate_sync = N'false';
-- The snapshot agent's schedule never fires: once, on 9999-12-31.
EXEC sp_addpublication_snapshot @publication = N'm_prof', @frequency_type = 1, @active_start_date = 99991231,
     @publisher_security_mode = 1;
EXEC sp_addarticle @publication = N'm_prof', @article = N'm_pft1', @source_owner = N'dbo', @source_object = N'm_pft1';
GO
DECLARE @pid int, @aid int;
EXEC distribution.dbo.sp_add_agent_profile @profile_id = @pid OUTPUT, @profile_name = N'm_prof_snap', @agent_type = 1,
     @profile_type = 1, @description = N'm_ test profile', @default = 0;
SELECT @aid = id FROM distribution.dbo.MSsnapshot_agents WHERE publisher_db = N'Sales' AND publication = N'm_prof';
EXEC distribution.dbo.sp_update_agent_profile @agent_type = 1, @agent_id = @aid, @profile_id = @pid;
