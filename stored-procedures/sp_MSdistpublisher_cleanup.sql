SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSdistpublisher_cleanup]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSdistpublisher_cleanup] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSdistpublisher_cleanup]
	@publisher [sysname]
WITH EXECUTE AS CALLER
AS
begin
	set nocount on
	declare @publisher_id smallint
	declare @job_id binary(16)
	declare @job_step_uid uniqueidentifier
	declare @retcode int
	declare @agent_id int
	
	--
	-- security check
	-- only db_owner can execute this
	--
	if (is_member ('db_owner') != 1) 
	begin
		raiserror(14260, 16, -1)
		return (1)
	end
	--
	-- security check
	-- Has to be executed from distribution database
	--
	if (sys.fn_MSrepl_isdistdb (db_name()) != 1)
	begin
		raiserror(21482, 16, -1, 'sp_MSdistpublisher_cleanup', 'distribution')
		return (1)
	end
	
	-- Delete agents
	-- Get the publisher id
	-- Check if publisher is a defined as a distribution publisher in the current database
	exec @retcode = sys.sp_MSvalidate_distpublisher @publisher, @publisher_id OUTPUT
	if @retcode <> 0
	begin
		return(1)
	end
	
	-- Dropping local jobs
	-- Use union in 'select'. Insensitive cursor will be used automatically.
	DECLARE hCagents CURSOR LOCAL FAST_FORWARD FOR
			SELECT job_id,
					job_step_uid
				FROM MSsnapshot_agents
				WHERE publisher_id = @publisher_id and local_job = 1
		UNION
			SELECT job_id,
					job_step_uid
				FROM MSlogreader_agents
				WHERE publisher_id = @publisher_id and local_job = 1
		UNION
			SELECT job_id,
					job_step_uid 
				FROM MSdistribution_agents
				WHERE publisher_id = @publisher_id and local_job = 1
		UNION
			SELECT job_id,
					job_step_uid
				FROM dbo.MSmerge_agents
				WHERE publisher_id = @publisher_id  and local_job = 1
		FOR READ ONLY

	OPEN hCagents
	FETCH hCagents INTO @job_id, @job_step_uid
   
	WHILE (@@fetch_status <> -1)
	BEGIN
		IF EXISTS (SELECT * FROM msdb.dbo.sysjobs_view WHERE job_id = @job_id)
		BEGIN
			exec @retcode = sys.sp_MSdrop_repl_job @job_id = @job_id,
													@job_step_uid = @job_step_uid
			if @retcode <> 0 or @@error <> 0
				return(1)
		END
		FETCH hCagents INTO @job_id, @job_step_uid
	end

	-- Clean up the tables, including
	--  4 Agent tables
	--  2 subscription tables
	--  article table
	--  publication table
	--  2 subscriber table
	-- The order is to avoid breaking monitoring


	delete MSpublisher_databases where publisher_id = @publisher_id
	if @@error <> 0 
		return (1) 

	delete dbo.MSpublications where publisher_id = @publisher_id
	if @@error <> 0 
		return (1) 

	delete MSarticles where publisher_id = @publisher_id
	if @@error <> 0 
		return (1) 

	delete dbo.MSsubscriptions where publisher_id = @publisher_id
	if @@error <> 0 
		return (1) 

	delete dbo.MSmerge_subscriptions where publisher_id = @publisher_id
	if @@error <> 0 
		return (1) 

	delete MSsnapshot_agents where publisher_id = @publisher_id
	if @@error <> 0 
		return (1) 
	
	delete MSlogreader_agents where publisher_id = @publisher_id
	if @@error <> 0 
		return (1) 

	-- delete cache for this agent
	delete MScached_peer_lsns 
			where agent_id in (select id 
								from MSdistribution_agents 
								where publisher_id = @publisher_id)
	if @@error <> 0 
		return (1)
			
	delete MSdistribution_agents where publisher_id = @publisher_id
	if @@error <> 0 
		return (1) 

	delete dbo.MSmerge_agents where publisher_id = @publisher_id
	if @@error <> 0 
		return (1) 

	delete MSsubscriber_info where UPPER(publisher) = UPPER(@publisher)
	if @@error <> 0 
		return (1) 

	delete MSsubscriber_schedule where UPPER(publisher) = UPPER(@publisher)
	if @@error <> 0 
		return (1) 

	delete dbo.MSpublication_access where not exists (select * from dbo.MSpublications p where
		p.publication_id = dbo.MSpublication_access.publication_id)
	if @@error <> 0 
		return (1) 

	-- We will also perform some extra cleanup for any PAL items that are
	-- no longer valid. PAL Items can become invalid if a user is dropped
	delete MSpublication_access 
		where sid != suser_sid(login, 0)
			or suser_sid(login, 0) is NULL
	if @@error <> 0 
		return (1) 
		
	delete MSrepl_originators where 
		not exists (select * from MSpublisher_databases p
			where p.id = MSrepl_originators.publisher_database_id )
	if @@error <> 0 
		return (1)
end
GO
GRANT EXECUTE ON [sys].[sp_MSdistpublisher_cleanup] TO [public] AS [dbo]
GO
