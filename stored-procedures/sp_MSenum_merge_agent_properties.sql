SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSenum_merge_agent_properties]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSenum_merge_agent_properties] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSenum_merge_agent_properties]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@show_security [bit]
WITH EXECUTE AS CALLER
AS
begin
	DECLARE @publisher_id int  -- Server id of the Publisher with respect to the Distributor
	declare @publication_id int
	declare @retcode int

    SELECT @publisher_id = NULL 
    SELECT @publisher_id = srvid 
      FROM MSreplservers
     WHERE UPPER(@publisher) = UPPER(srvname)  

	IF @publisher_id IS  NULL
	BEGIN
		RAISERROR(21169, 16, -1, @publisher, @@SERVERNAME, @publisher)    
	END

	select @publication_id = publication_id from 
		dbo.MSpublications where 
		publisher_id = @publisher_id and
		publisher_db = @publisher_db and
		(publication = @publication or @publication = N'%')
	if @publication_id is NULL
	begin
		raiserror (20026, 11, -1, @publication)
		return (1)
	end
	
	exec @retcode = sys.sp_MScheck_pull_access
		@agent_type = 1, -- merge agent
		@publication_id = @publication_id
	if @@error <> 0 or @retcode <> 0
	begin    
		RAISERROR (15247, 11, -1)
		return (1)
	end

	-- These are the main differences between @show_security = 0 and 1:
	--
	--	@show_security = 0
	--		This is the backcompat case and is really meant for 8.0
	--		publishers. Setting it to this value returns the following 
	--		column values:
	--
	--			job_id, offload_enabled, offload_server
	--
	--		Also note that the job_id returned here is from MSmerge_agents
	--		and NOT from sysjobs... so it is possible that the job has been
	--		deleted via komodo procs but we still return the old job_id
	--
	--	@show_security = 1
	--		This is the Yukon case returns the same columns as in @show_security = 0
	--		but also adds the following columns to the resultset:
	--		
	--			subscriber_security_mode, subscriber_login, publisher_security_mode,
	--			publisher_login, credential_identity, merge_agent_name
	--		
	--		Also note that the job_id returned here is from sysjobs and not
	--		from MSmerge_agents. So if the job is deleted via the komodo
	--		procedures then we will return NULL for the job_id
	IF @show_security = 1
	BEGIN
		SELECT sj.job_id, msma.offload_enabled, msma.offload_server,
				msma.subscriber_security_mode,
				msma.subscriber_login,
				sc.credential_identity,
				msma.publisher_security_mode,
				msma.publisher_login,
				msma.name
		 FROM dbo.MSmerge_agents msma
		 		LEFT JOIN msdb..sysjobs sj
		  			ON msma.job_id = sj.job_id
				LEFT JOIN msdb..sysjobsteps sjs
					ON msma.job_step_uid = sjs.step_uid
				LEFT JOIN msdb..sysproxies sp
					ON sjs.proxy_id = sp.proxy_id
				LEFT JOIN sys.credentials sc
					ON sp.credential_id = sc.credential_id
		 WHERE msma.publisher_id = @publisher_id 
		   AND msma.publisher_db = @publisher_db
		   AND (@publication = N'%' OR msma.publication = @publication)
	END
	ELSE
	BEGIN
		SELECT msma.job_id, msma.offload_enabled, msma.offload_server
		  FROM dbo.MSmerge_agents msma
		  LEFT JOIN msdb..sysjobs sj
		  		ON msma.job_id = sj.job_id
		 WHERE msma.publisher_id = @publisher_id 
		   AND msma.publisher_db = @publisher_db
		   AND (@publication = N'%' OR msma.publication = @publication)
	END
end
GO
GRANT EXECUTE ON [sys].[sp_MSenum_merge_agent_properties] TO [public] AS [dbo]
GO
