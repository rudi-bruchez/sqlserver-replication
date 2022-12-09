SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSadd_publication]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSadd_publication] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSadd_publication]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@publication_id [int],
	@publication_type [int],
	@independent_agent [bit],
	@immediate_sync [bit],
	@allow_push [bit],
	@allow_pull [bit],
	@allow_anonymous [bit],
	@snapshot_agent [nvarchar](100),
	@logreader_agent [nvarchar](100),
	@description [nvarchar](255),
	@retention [int],
	@vendor_name [nvarchar](100),
	@sync_method [int],
	@allow_subscription_copy [bit],
	@thirdparty_options [int],
	@allow_queued_tran [bit],
	@queue_type [int],
	@publisher_type [sysname],
	@options [int],
	@retention_period_unit [tinyint],
	@publisher_engine_edition [int],
	@allow_initialize_from_backup [bit]
WITH EXECUTE AS CALLER
AS
BEGIN
	set nocount on

	DECLARE @thirdparty_flag bit                    -- 0 = SQL Server 1 = Third Party
				,@publisher_id smallint
				,@retcode int
				,@platform int
				,@platform_nt int
				,@platform_desktop int
				,@agentname nvarchar(100)
				,@dbname sysname

	select @platform = platform()
			,@platform_nt = 0x1
			,@platform_desktop = 0x100
			,@dbname = db_name()

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
	-- Has to be executed from distribution database (sp_MSvalidate_distpublisher
	-- does this check implicitly)
	--
	/*
	if (sys.fn_MSrepl_isdistdb (@dbname) != 1)
	begin
		raiserror(21482, 16, -1, 'sp_MSadd_publication', 'distribution')
		return (1)
	end
	*/
	-- Check if publisher is a defined as a distribution publisher in the current database
	exec @retcode = sys.sp_MSvalidate_distpublisher @publisher, @publisher_id OUTPUT
	if @retcode <> 0
		return(1)

	-- Get third party flag
	select @thirdparty_flag = thirdparty_flag from msdb.dbo.MSdistpublishers
		where name = UPPER(@publisher)
	
	/*
	** Parameter Check: @publication. (For 3rd party publications.)
	** The @publication name must conform to the rules for identifiers,
	** and must not be the keyword 'all'.
	*/

	exec @retcode = sys.sp_MSreplcheck_name @publication, '@publication', 'sp_MSadd_publication'
	if @@ERROR <> 0 or @retcode <> 0
		return(1)

	IF LOWER (@publication) = N'all'
	BEGIN
		RAISERROR (14034, 16, -1)
		RETURN (1)
	END

	-- Parameter Check: @publication_type
	-- Make sure that the publication type is one of the following:
	-- 0  transactional
	-- 1  snapshot
	-- 2  merge
	if @publication_type not in (0,1,2)
	begin
		raiserror(20033, 16, -1)
		return (1)
	end

	-- disable tran/queued publishing on Win9x
	if (@publication_type = 0 or @allow_queued_tran = 1) and (@platform & @platform_nt != @platform_nt)
	begin
		raiserror(21764, 16, 1)
		return (1)
	end

	if (@publication_type = 0) and (@platform & @platform_desktop = @platform_desktop)
	begin
		raiserror(21108, 16, -1)
		return (1)
	end

	-- Parameter Check: @immediate_sync
	-- The publication must support independent_agent to support immediate_sync
	if @immediate_sync = 1 and @independent_agent != 1
	begin
		raiserror(21022, 16, -1)
		return (1)
	end

	-- Parameter Check: @allow_anonymous
	-- The publication must support immediate_sync to support anonymous.
	if @allow_anonymous = 1 and @immediate_sync != 1
	begin
		raiserror(20011, 16, -1)
		return (1)
	end
	
	-- Make sure publication does not already exist
	if exists (select * from dbo.MSpublications where publication = @publication and
		publisher_id = @publisher_id and publisher_db = @publisher_db)
	begin
		if @thirdparty_flag = 1
		begin
			raiserror(14016, 16, -1, @publication)
			return (1)
		end
		else
		begin
			--
			-- clean up orphans if necessary
			--
			exec @retcode = sys.sp_MSdrop_publication 
				@publisher = @publisher,
				@publisher_db = @publisher_db,
				@publication = @publication,
				@cleanup_orphans = 1
			if @@error <> 0 or @retcode <> 0
				return (1)
		end
	end
 
	--
	-- For MSMQ queue type - Distributor needs to support MSMQ 2.0
	-- in case we support a pre-Yukon publisher.
	-- Post Yukon - this block can be removed
	--
	if (@queue_type = 1 and @allow_queued_tran = 1)
	begin
		--
		-- Now we use xp_MSver to detect NT OS version
		-- MSMQ subscription only allowed for platforms that support MSMQ 2.0
		-- version 5.0.2195 or higher
		--
		create table #tosversion ( propid int, propname sysname collate database_default, value int, charvalue nvarchar(255) collate database_default)
		insert into #tosversion (propid, propname, value, charvalue)
			exec master.dbo.xp_msver N'WindowsVersion'

		declare @vervalue int
				,@lobyte tinyint
				,@hibyte tinyint
				,@loword smallint
				,@hiword smallint

		--
		-- low order byte of low order word = OSmajor, high order byte of low order word = OSminor
		-- high order word = OSbuild
		--
		select @vervalue = value from #tosversion where propname = N'WindowsVersion'
		select @loword = (@vervalue & 0xffff)
				,@hiword = (@vervalue / 0x10000) & 0xffff
		select @lobyte = @loword & 0xff
				,@hibyte = (@loword / 100) & 0xff
		drop table #tosversion

		--
		-- check for OS major version
		--
		if (@lobyte < 5)
		begin
			raiserror(21334, 16, 4, '2.0')
			return (1)
		end

		--
		-- check for OS build version
		--
		if (@lobyte = 5 and @hiword < 2195)
		begin
			raiserror(21334, 16, 5, '2.0')
			return (1)
		end
	end

	begin tran
	save tran MSadd_publication

	insert into dbo.MSpublications (publisher_id, publisher_db, publication, publication_type, thirdparty_flag,
		independent_agent, immediate_sync, allow_push, allow_pull, allow_anonymous, description,
		vendor_name, retention, sync_method, allow_subscription_copy, thirdparty_options, 
		allow_queued_tran, options, retention_period_unit, allow_initialize_from_backup)
	values (@publisher_id, @publisher_db, @publication, @publication_type, @thirdparty_flag, 
		@independent_agent, @immediate_sync, @allow_push, @allow_pull, @allow_anonymous, @description, 
		@vendor_name, @retention, @sync_method, @allow_subscription_copy, @thirdparty_options, 
		@allow_queued_tran, @options, @retention_period_unit, @allow_initialize_from_backup)
	if @@error <> 0
		goto UNDO
	select @publication_id = @@identity

	-- Enable the distribution cleanup agent if transactional or snapshot publicational
	if @publication_type = 0 or @publication_type = 1
	begin
		select @agentname = name 
		from msdb.dbo.sysjobs as j
			join msdb.dbo.sysjobsteps as s 
				on j.job_id = s.job_id
		where j.category_id = 11 
			and s.database_name = @dbname

		if @agentname is not NULL
		begin
			exec @retcode = msdb.dbo.sp_update_job @job_name=@agentname, @enabled=1
			if @@error <> 0 or @retcode <> 0
				goto UNDO
		end
	end

	-- Add snapshot and logreader agent

	-- Always add a non local snapshot agent. This is to cover the case
	-- when there's no SQLServerAgent job for the snapshot agent (For example, in Access).
	-- The agent entry is needed for initance check.
	-- sp_addpublication_snapshot will drop the entry and recreat it.
	exec @retcode = sys.sp_MSadd_snapshot_agent
		@name = NULL,
		@publisher = @publisher,
		@publisher_db = @publisher_db,
		@publication = @publication,
		@publication_type = @publication_type,
		@publisher_type = @publisher_type,
		@local_job = 0,
		@internal = N'YUKON'
	if @@error <> 0 or @retcode <> 0
		goto UNDO

	-- If publisher_id, publisher_db pair is not in MSpublisher_databases then add it.  This will be used
	-- to store a publisher_database_id in the MSrepl_transactions and MSrepl_commands table.
	if not exists (select * from dbo.MSpublisher_databases where publisher_id = @publisher_id and
		publisher_db = @publisher_db)
	begin
		insert into dbo.MSpublisher_databases (publisher_id, publisher_db, publisher_engine_edition) 
			values (@publisher_id, @publisher_db, @publisher_engine_edition)
		if @@error <> 0
			goto UNDO
		insert into dbo.MSrepl_backup_lsns (publisher_database_id) values (@@identity)
		if @@error <> 0
			goto UNDO
	end
	--
	-- Add entries in publication threshold for this publication
	-- @publication_type int   -- 0 = Transactional 1 = Snapshot  2 = Merge
	--
	if (@publication_type in (0,1))
	begin
		-- Snapshot or transactional publication
		-- warnings are enabled by default
		insert into dbo.MSpublicationthresholds (publication_id,metric_id,value, isenabled)
			select @publication_id, metric_id, default_value, 1 
			from msdb.dbo.MSreplmonthresholdmetrics
			where metric_id = 1
		if (@publication_type = 0)
		begin
			insert into dbo.MSpublicationthresholds (publication_id,metric_id,value, isenabled)
				select @publication_id, metric_id, default_value, 1 
				from msdb.dbo.MSreplmonthresholdmetrics
				where metric_id = 2
		end
	end
	else
	begin
		-- Merge publication
		insert into dbo.MSpublicationthresholds (publication_id,metric_id,value)
			select @publication_id, metric_id, default_value 
			from msdb.dbo.MSreplmonthresholdmetrics
			where metric_id in (4,5,6,7,8)
	end
	-- Check for error in insert
	if @@error <> 0
		goto UNDO
	--
	-- Commit the transaction
	--
	commit tran
	--
	-- All done
	--
	return(0)

UNDO:
	if @@TRANCOUNT > 0
	begin
		ROLLBACK TRAN MSadd_publication
		COMMIT TRAN
	end
	return(1)
END
GO
GRANT EXECUTE ON [sys].[sp_MSadd_publication] TO [public] AS [dbo]
GO
