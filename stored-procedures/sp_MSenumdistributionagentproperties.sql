SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSenumdistributionagentproperties]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSenumdistributionagentproperties] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSenumdistributionagentproperties]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@show_security [bit]
WITH EXECUTE AS CALLER
AS
begin
	DECLARE @independent_agent bit 
	DECLARE @publisher_id int  -- Server id of the Publisher with respect to the Distributor
   
	--
	-- security check
	-- only db_owner can execute this
	--
	if (is_member ('db_owner') != 1) 
	begin
		raiserror(14260, 16, -1)
		return (1)
	end

    SELECT @publisher_id = NULL 
    SELECT @publisher_id = srvid 
      FROM MSreplservers
     WHERE UPPER(@publisher) = UPPER(srvname)  
    
    IF @publisher_id IS NULL
    BEGIN
        RAISERROR(21169, 16, -1, @publisher, @@SERVERNAME, @publisher)    
    END

	IF @publication <> '%' -- A publication name is specified 
	BEGIN
		-- Determine whether the given publication shares an 
		-- agent with other publicaitons in the same database
		-- or not
		SELECT @independent_agent = 0
		SELECT @independent_agent = independent_agent 
		  FROM dbo.MSpublications
		 WHERE publisher_id = @publisher_id
		   AND publisher_db = @publisher_db
		   AND publication = @publication  
		
		IF @independent_agent IS NULL
		BEGIN
			RAISERROR(20026, 16, -1, @publication)
		END

		IF @independent_agent = 0 
		BEGIN
			-- If the publication shares an agent with 
			-- other publications, change the publication
			-- name to 'ALL' before querying the MSdistribution_agents
			-- table
			SELECT @publication = N'ALL'                
		END
	END

	-- These are the main differences between @show_security = 0 and 1:
	--
	--	@show_security = 0
	--		This is the backcompat case and is really meant for 8.0
	--		publishers. Setting it to this value returns the following 
	--		column values:
	--
	--			job_id, offload_enabled, offload_server, dts_package_name,
	--			dts_package_location, status
	--
	--		Also note that the job_id returned here is from MSdistribution_agents
	--		and NOT from sysjobs... so it is possible that the job has been
	--		deleted via komodo procs but we still return the old job_id
	--
	--	@show_security = 1
	--		This is the Yukon case returns the same columns as in @show_security = 0
	--		but also adds the following columns to the resultset:
	--		
	--			subscriber_security_mode, subscriber_login, credential_identity
	--			distribution_agent_name, subscriber_type, subscriber_provider,
	--			subscriber_datasource, subscriber_providerstring, subscriber_location,
	--			subscriber_catalog
	--		
	--		Also note that the job_id returned here is from sysjobs and not
	--		from MSdistribution_agents. So if the job is deleted via the komodo
	--		procedures then we will return NULL for the job_id
	IF @show_security = 1
	BEGIN
		SELECT sj.job_id, msda.offload_enabled, msda.offload_server, 
			   msda.dts_package_name, msda.dts_package_location,
			   -- status of this agent, only useful in detecting
			   -- whether or not the agent has be deactivated by cleanup
			   -- If so, all the rows in dbo.MSsubscriptions will be 0
			   (select top 1 s.status 
					from dbo.MSsubscriptions s where
					s.agent_id = msda.id),
				msda.subscriber_security_mode,
				msda.subscriber_login,
				sc.credential_identity,
				msda.name,
				msda.subscriber_type,
				msda.subscriber_provider,
				msda.subscriber_datasrc,
				msda.subscriber_provider_string,
				msda.subscriber_location,
				msda.subscriber_catalog
		  FROM MSdistribution_agents msda
		  		LEFT JOIN msdb..sysjobs sj
		  			ON msda.job_id = sj.job_id
				LEFT JOIN msdb..sysjobsteps sjs
					ON msda.job_step_uid = sjs.step_uid
				LEFT JOIN msdb..sysproxies sp
					ON sjs.proxy_id = sp.proxy_id
				LEFT JOIN sys.credentials sc
					ON sp.credential_id = sc.credential_id
		 WHERE msda.publisher_id = @publisher_id 
		   AND msda.publisher_db = @publisher_db
		   AND msda.publication LIKE @publication
	END
	ELSE
	BEGIN
		SELECT msda.job_id, msda.offload_enabled, msda.offload_server, 
			   msda.dts_package_name, msda.dts_package_location,
			   -- status of this agent, only useful in detecting
			   -- whether or not the agent has be deactivated by cleanup
			   -- If so, all the rows in dbo.MSsubscriptions will be 0
			   (select top 1 s.status from dbo.MSsubscriptions s where
					s.agent_id = msda.id)
		  FROM MSdistribution_agents msda
		  		LEFT JOIN msdb..sysjobs sj
		  			ON msda.job_id = sj.job_id
		 WHERE msda.publisher_id = @publisher_id 
		   AND msda.publisher_db = @publisher_db
		   AND msda.publication LIKE @publication
	END
end
GO
GRANT EXECUTE ON [sys].[sp_MSenumdistributionagentproperties] TO [public] AS [dbo]
GO
