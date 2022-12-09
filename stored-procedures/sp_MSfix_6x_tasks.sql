SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSfix_6x_tasks]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSfix_6x_tasks] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSfix_6x_tasks]
	@publisher [sysname],
	@publisher_engine_edition [int]
WITH EXECUTE AS CALLER
AS
BEGIN
	SET NOCOUNT ON
	DECLARE @distributor sysname
				,@distproc nvarchar (255)
				,@retcode int

	-- Security Check: require sysadmin
	if (isnull(is_srvrolemember('sysadmin'),0) = 0)
	begin
		raiserror(21089,16,-1) 
		return (1)
	end

	-- If @publisher is null redirect the call to distributor
	if @publisher is null
	begin
		/*
		** Get distribution server information for remote RPC
		** agent verification.
		*/
		EXEC @retcode = sys.sp_MSrepl_getdistributorinfo @rpcsrvname = @distributor OUTPUT
		IF @@error <> 0 OR @retcode <> 0
		BEGIN
			RAISERROR (14071, 16, -1)
			RETURN (1)
		END
		--
		-- Get the engine edition of the publisher
		--
		select @publisher_engine_edition = sys.fn_MSrepl_editionid()
		/*
		** RPC distributor
		*/
		SELECT @distproc = QUOTENAME(RTRIM(@distributor)) + '.master.sys.sp_MSfix_6x_tasks'
		EXECUTE @retcode = @distproc
			@publisher = @@SERVERNAME
			,@publisher_engine_edition = @publisher_engine_edition
		IF @@ERROR <> 0 or @retcode <> 0
			return (1)
	end
	else
	begin
		--
		-- We are on distributor
		--
		declare @category_id int
					,@category_name sysname
					,@server sysname
					,@databasename sysname
					,@name sysname
					,@distdb sysname
					,@job_id uniqueidentifier
					,@sSubsystem sysname

		-- Drop entry in systasks first.
		--qunguo: removing reference to systasks_view as this is going away in Yukon
		--should be safe to do since this looks to be used only by upgrade from 6.x

		/*DECLARE hCtasks CURSOR LOCAL FAST_FORWARD FOR
			SELECT name FROM msdb.dbo.systasks_view st WHERE 
				
				-- drop distribution agents.
				(st.name LIKE @publisher + '_' + '%' + '_' + '%' AND 
				LOWER(subsystem collate SQL_Latin1_General_CP1_CS_AS) = 'distribution' AND
				server = @@SERVERNAME) OR
								
				(LOWER(subsystem collate SQL_Latin1_General_CP1_CS_AS) = 'logreader' AND
				server = @publisher) OR 
				
				(LOWER(subsystem collate SQL_Latin1_General_CP1_CS_AS) = 'snapshot' AND
				server = @publisher) OR

				(st.name LIKE '%' + '_' + '%' + '_Cleanup' AND 
				st.command LIKE '%' + 'sp_replcleanup' + '%' AND
				LOWER(subsystem collate SQL_Latin1_General_CP1_CS_AS) = 'tsql')
			FOR READ ONLY

		OPEN hCtasks
		FETCH hCtasks INTO @name

		WHILE (@@fetch_status <> -1)
		BEGIN
			
			EXEC @retcode = msdb.dbo.sp_droptask @name = @name
			if @retcode <> 0 or @@error <> 0
				return(1)
			FETCH hCtasks INTO @name
		END
--looks like this code is missing close and deallocate of the cursor hCtasks anyway:)

*/

		-- Now spin through each old replication job and fixup categories names
		declare hcJobsToFix CURSOR LOCAL FAST_FORWARD for 
				select distinct j.job_id, j.name, s.subsystem, 
					s.server, s.database_name
					from msdb.dbo.sysjobs j left join msdb.dbo.sysjobsteps s
						on j.job_id = s.job_id
					where j.category_id = 0 and s.step_id = 1 and lower(s.subsystem collate SQL_Latin1_General_CP1_CS_AS) in ( 'snapshot', 'logreader', 'distribution' )
				for read only

		open hcJobsToFix 
		fetch hcJobsToFix into @job_id, @name, @sSubsystem,
			@server,@databasename

		while (@@fetch_status <> -1 )
		begin
			-- Note, have to make it a transaction, once the category_id is changed,
			-- the task will never be picked up again.
			begin tran 

				-- Get Distribution category name (assumes category_id = 10)
				select @category_id =
					case lower(@sSubsystem collate SQL_Latin1_General_CP1_CS_AS) 
						when 'snapshot' then 15
						when 'distribution' then 10
						when 'logreader' then 13
						else 0
					end

				select @category_name = name FROM msdb.dbo.syscategories where category_id = @category_id
				
				-- raiserror( 'Would update %s to category %d based on subsystem value %s', -1, 10, @nJobName, @iCategory, @sSubsystem )
				exec @retcode = msdb.dbo.sp_update_job @job_id = @job_id, 
					@category_name = @category_name
				if @retcode <> 0 or @@error <> 0
					goto UNDO

				-- Add the replication agent for monitoring
				SELECT @distdb = distribution_db from msdb..MSdistpublishers where UPPER(name collate database_default) = UPPER(@server) collate database_default
				IF (@category_id = 13) -- Logreader
				BEGIN
					SELECT @distproc = QUOTENAME(@distdb) + '.dbo.sp_MSadd_logreader_agent'
					EXECUTE @retcode = @distproc
						@name = @name,
						@publisher = @server,
						@publisher_db = @databasename,
						@publication = '',  
						@local_job = 1,
						@job_existing = 1,
						@job_id = @job_id,
						@internal = N'YUKON',
						@publisher_engine_edition = @publisher_engine_edition

					IF (@retcode <> 0 or @@error<>0)
						goto UNDO
				END
				ELSE 
				IF (@category_id = 15) -- Snapshot
				BEGIN
					DECLARE @publication sysname

					SELECT @publication = NULL
					EXECUTE sys.sp_MSget_publication_from_taskname
											@taskname = @name,
											@publisher = @server,
											@publisherdb = @databasename,
											@publication = @publication OUTPUT

					IF (@publication IS NOT NULL )
					BEGIN               
						SELECT @distproc = QUOTENAME(@distdb) + '.dbo.sp_MSadd_publication'
						EXECUTE @retcode = @distproc
							@publisher = @server,
							@publisher_db = @databasename,
							@publication = @publication,
							@publication_type = 0, -- Transactional
							@publisher_engine_edition = @publisher_engine_edition
						IF (@retcode <> 0 or @@error<>0)
							goto UNDO

						SELECT @distproc = QUOTENAME(@distdb) + '.dbo.sp_MSadd_snapshot_agent'
						EXECUTE @retcode = @distproc
							@name = @name,
							@publisher = @server,
							@publisher_db = @databasename,
							@publication = @publication,
							@local_job = 1,
							@job_existing = 1,
							@snapshot_jobid = @job_id,
							@internal = N'YUKON'
						IF (@retcode <> 0 or @@error<>0)
							goto UNDO
					END
				END
			commit tran
			fetch hcJobsToFix into @job_id, @name, @sSubsystem,
				@server,@databasename
		end         
		close hcJobsToFix
		deallocate hcJobsToFix
	end
	return (0)
UNDO:
	if @@trancount <> 0
		rollback tran
	return (1)
END
GO
GRANT EXECUTE ON [sys].[sp_MSfix_6x_tasks] TO [public] AS [dbo]
GO
