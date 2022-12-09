SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSreplagentjobexists]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSreplagentjobexists] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSreplagentjobexists]
	@type [int],
	@exists [bit] OUTPUT,
	@job_name [sysname] OUTPUT,
	@job_id [uniqueidentifier] OUTPUT,
	@job_step_uid [uniqueidentifier] OUTPUT,
	@proxy_id [int] OUTPUT,
	@publisher_id [int] OUTPUT,
	@subscriber_id [int] OUTPUT,
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@subscriber [sysname],
	@subscriber_db [sysname],
	@independent_agent [bit],
	@frompublisher [bit]
WITH EXECUTE AS CALLER
AS
begin
	set nocount on
	DECLARE @category_id	int,
			@subsystem		sysname,
			@dbname sysname,
			@srvname sysname

	SELECT @exists			= 0,
			@dbname = db_name(),
			@srvname = upper(CONVERT(sysname, SERVERPROPERTY('ServerName')))

	-- security: Has to be executed by SA 
	--			 or DBO of distdb
	IF IS_SRVROLEMEMBER('sysadmin') != 1
		AND NOT (IS_MEMBER ('db_owner') = 1
				AND sys.fn_MSrepl_isdistdb(@dbname) = 1)
	BEGIN
		-- You do not have the required permissions to complete the operation.
		RAISERROR (14126, 16, -1)
		RETURN 1
	END
	
	--
	-- if executed from publisher
	--
	if (@frompublisher = 1)
	begin
		declare @loc_publisher sysname
				,@loc_distribdb sysname
				,@rpcsrvname sysname
				,@rpc nvarchar(1000)
				,@retcode int
		--
		-- get the distributor rpc info
		--
		select @loc_publisher = @srvname
		EXEC @retcode = sys.sp_MSrepl_getdistributorinfo @publisher = @loc_publisher,
												@rpcsrvname = @rpcsrvname OUTPUT,
												@distribdb = @loc_distribdb OUTPUT

		IF @@error <> 0 OR @retcode <> 0 or (@rpcsrvname IS NULL) or (@loc_distribdb IS NULL)
		BEGIN
			RAISERROR (14080, 16, -1, @loc_publisher)
			RETURN (1)
		END
		--
		-- execute the RPC
		--
		select @rpc = quotename(@rpcsrvname) + N'.' + quotename(@loc_distribdb) + N'.dbo.sp_MSreplagentjobexists'
		exec @retcode = @rpc @type = @type
							,@exists = @exists output
							,@job_name = @job_name output
							,@job_id = @job_id output
							,@job_step_uid = @job_step_uid output
							,@proxy_id = @proxy_id output
							,@publisher_id = @publisher_id output
							,@subscriber_id = @subscriber_id output
							,@loc_publisher = @loc_publisher
							,@publisher_db = @publisher_db
							,@publication = @publication
							,@subscriber = @subscriber
							,@subscriber_db = @subscriber_db
							,@independent_agent = @independent_agent
							,@frompublisher = 0
		if (@@error != 0)
		select @retcode = 1
		--
		-- return
		--
		return @retcode
	end

	-- database must be distribution db
	IF sys.fn_MSrepl_isdistdb(@dbname) <> 1
	BEGIN
		RAISERROR (21482, 16, -1, 'sp_MSreplagentjobexists', 'distribution')
		RETURN (1)
	END
	
	--
	-- If we are here - this SP is being executed on distributor
	--
	
	-- Note that we do not perform parameter checks here
	-- this is because this procedure should only be called by 
	-- other replication procedures. Here are the rules:
	
	exec sys.sp_MSget_server_portinfo 
		@name = @publisher, 
		@srvname = @publisher OUTPUT

	exec sys.sp_MSget_server_portinfo 
		@name = @subscriber, 
		@srvname = @subscriber OUTPUT

	-- retrieve the publisher server id
	IF @publisher IS NOT NULL
	BEGIN
		SELECT @publisher_id = srvid 
			FROM MSreplservers 
			WHERE UPPER(srvname) = UPPER(@publisher)
		IF @publisher_id IS null
		BEGIN
			-- Publisher @publisher does not exist.
			RAISERROR(21618, 16, -1, @publisher)
			RETURN 1
		END
	END

	-- Distribution Agent
	IF @type = 0
	BEGIN
		-- retrieve the subscriber server id
		IF @subscriber IS NOT NULL
		BEGIN
			SELECT @subscriber_id = srvid 
				FROM MSreplservers 
				WHERE UPPER(srvname) = UPPER(@subscriber)
			IF @subscriber_id IS NULL
			BEGIN
				-- The server '@subscriber' is not a Subscriber.
				RAISERROR(14048, 16, -1, @subscriber)
				RETURN 1
			END
		END
		
		-- this only works for PUSH subscription agents created at the distrib
		SELECT @category_id 	= 10,
				@subsystem		= N'Distribution',
				@exists			= 1,
				@job_name		= msda.name,
				@job_id 		= CAST(msda.job_id as uniqueidentifier),
				@job_step_uid	= msda.job_step_uid,
				@proxy_id		= sjs.proxy_id
			FROM msdb.dbo.sysjobs_view sjv
				JOIN MSdistribution_agents msda
					ON sjv.job_id = CAST(msda.job_id as uniqueidentifier)
				JOIN msdb.dbo.sysjobsteps sjs
					ON sjv.job_id = sjs.job_id
						AND msda.job_step_uid = sjs.step_uid
			WHERE msda.publisher_id = @publisher_id
				AND msda.publisher_db = @publisher_db
				AND ((msda.publication = @publication
						AND @independent_agent = 1)
					OR (msda.publication = N'ALL'
						AND @independent_agent = 0))
				AND msda.subscriber_id = @subscriber_id
				AND msda.subscriber_db = @subscriber_db
	END
	-- Merge Agent
	ELSE IF @type = 1
	BEGIN
		-- this only works for PUSH subscription agents created at the distrib
		SELECT @category_id 	= 14,
				@subsystem		= N'Merge',
				@exists			= 1,
				@job_name		= msma.name,
				@job_id 		= CAST(msma.job_id as uniqueidentifier),
				@job_step_uid	= msma.job_step_uid,
				@proxy_id 		= sjs.proxy_id
			FROM msdb.dbo.sysjobs_view sjv
				JOIN dbo.MSmerge_agents msma
					ON sjv.job_id = CAST(msma.job_id as uniqueidentifier)
				JOIN msdb.dbo.sysjobsteps sjs
					ON sjv.job_id = sjs.job_id
						AND msma.job_step_uid = sjs.step_uid
			WHERE msma.publisher_id = @publisher_id
				AND msma.publisher_db = @publisher_db
				AND msma.publication = @publication
				AND UPPER(msma.subscriber_name) = UPPER(@subscriber)
				AND msma.subscriber_db = @subscriber_db
	END
	-- Logreader Agent
	ELSE IF @type = 2
	BEGIN
		SELECT 	@category_id 	= 13,
				@subsystem		= N'LogReader',
				@exists			= 1,
				@job_name		= msla.name,
				@job_id 		= CAST(msla.job_id as uniqueidentifier),
				@job_step_uid	= msla.job_step_uid,
				@proxy_id		= sjs.proxy_id
			FROM msdb.dbo.sysjobs_view sjv
				JOIN MSlogreader_agents msla
					ON sjv.job_id = CAST(msla.job_id as uniqueidentifier)
				JOIN msdb.dbo.sysjobsteps sjs
					ON sjv.job_id = sjs.job_id
						AND msla.job_step_uid = sjs.step_uid
			WHERE msla.publisher_id = @publisher_id
				AND msla.publisher_db = @publisher_db
	END
	-- Snapshot Agent
	ELSE IF @type = 3
	BEGIN
		SELECT @category_id 	= 15,
				@subsystem		= N'Snapshot',
				@exists			= 1,
				@job_name		= mssa.name,
				@job_id 		= CAST(mssa.job_id as uniqueidentifier),
				@job_step_uid	= mssa.job_step_uid,
				@proxy_id		= sjs.proxy_id
			FROM msdb.dbo.sysjobs_view sjv
				JOIN MSsnapshot_agents mssa
					ON sjv.job_id = CAST(mssa.job_id as uniqueidentifier)
				JOIN msdb.dbo.sysjobsteps sjs
					ON sjv.job_id = sjs.job_id
						AND mssa.job_step_uid = sjs.step_uid
			WHERE mssa.publisher_id = @publisher_id
				AND mssa.publisher_db = @publisher_db
				AND mssa.publication = @publication
	END
	-- Queued Agent
	ELSE IF @type = 4
	BEGIN
		SELECT @category_id 	= 19,
				@subsystem		= N'QueueReader',
				@exists			= 1,
				@job_name		= msqa.name,
				@job_id 		= CAST(msqa.job_id as uniqueidentifier),
				@job_step_uid	= msqa.job_step_uid,
				@proxy_id		= sjs.proxy_id
			FROM msdb.dbo.sysjobs_view sjv
				JOIN MSqreader_agents msqa
					ON sjv.job_id = CAST(msqa.job_id as uniqueidentifier)
				JOIN msdb.dbo.sysjobsteps sjs
					ON sjv.job_id = sjs.job_id
						AND msqa.job_step_uid = sjs.step_uid
	END

	-- if we didn't find a job_step_uid but we did find
	-- a job id then let's try to identify the job_step_uid
	IF @job_id IS NOT NULL
		AND @job_step_uid IS NULL
	BEGIN
		SELECT @job_step_uid 	= sjs.step_uid,
				@proxy_id		= sjs.proxy_id
		FROM msdb.dbo.sysjobs_view as sjv 
			JOIN msdb.dbo.sysjobsteps as sjs 
				ON sjv.job_id = sjs.job_id 
		WHERE sjv.job_id = @job_id
			AND sjv.master_server = 0
			AND UPPER(sjv.originating_server) = @srvname
			AND sjv.category_id = @category_id
			AND sjs.subsystem = @subsystem 
			AND sjs.database_name = @dbname
	END
		
	RETURN 0
END
GO
GRANT EXECUTE ON [sys].[sp_MSreplagentjobexists] TO [public] AS [dbo]
GO
