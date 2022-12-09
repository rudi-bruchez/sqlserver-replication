SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MShelp_replication_status]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MShelp_replication_status] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MShelp_replication_status]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@agent_type [int],
	@exclude_anonymous [bit]
WITH EXECUTE AS CALLER
AS
begin
	set nocount on
	declare @return_code int,
				@return_status int,
				@return_timestamp datetime,
				@alt_return_status int,
				@alt_return_timestamp datetime,
				@cmd varchar(4000),
				@db_name sysname,
				@distbit int,
				@allow_queued_tran bit, 
				@anonymous_mask int,
				@anonymous_hide int,
				@tran_pubtype int,
				@snapshot_agent int,
				@logreader_agent int,
				@distrib_agent int,
				@merge_agent int,
				@queue_agent int
			
	select @return_code = 0, 
			@return_status = 0,
			@return_timestamp = 0,
			@alt_return_status = 0,
			@alt_return_timestamp = 0,
			@cmd = null,
			@db_name = null,
			@distbit = 16,
			@allow_queued_tran = 0,
			@anonymous_mask = 0x80000000,
			@tran_pubtype = 0,
			@snapshot_agent = 1,
			@logreader_agent = 2,
			@distrib_agent = 3,
			@merge_agent = 4,
			@queue_agent = 9

	-- Security check
	if not((is_srvrolemember('sysadmin') = 1)  or (is_member ('db_owner') = 1) or (isnull(is_member('replmonitor'), 0) = 1))
	begin
		goto Err_Handler
	end

	-- do some parameter checking

	-- @agent_type is only supported with all wildcards
	if @agent_type <> 0 and (@publisher <> '%' or @publisher_db <> '%' or @publication <> '%')
	begin
		goto Err_Handler
	end

	-- if no distribution dbs then exit	
	if not exists(select name from master.dbo.sysdatabases where category & @distbit <> 0 and has_dbaccess(name) = 1)
	begin
		goto Done
	end

	select @anonymous_hide = case when (@exclude_anonymous = 0) then 0x00000000 else @anonymous_mask end

	-- drop the temp table 
	if object_id('tempdb.dbo.#tmp_replication_status') is not null
	begin
		drop table #tmp_replication_status
	end

	-- create the temp table	
	create table #tmp_replication_status
	(
		publisher sysname,
		publisher_db sysname, 
		publication sysname, 
		publication_type int,
		agent_type int, 
		status int,
		agent_id int,
		agent_name sysname,
		job_id uniqueidentifier null,
		time_stamp datetime null,
		publisher_srvid int null
	)

	-- load tmp replication_status table
	exec @return_code = sys.sp_MSload_tmp_replication_status @agent_type = @agent_type
	if @@error <> 0 or @return_code <> 0
		goto Err_Handler
	
	-- now lets retrieve the status and timestamp to be returned
	if @publisher = '%'
	begin
		select @return_status = max(status), 
				@return_timestamp = max(time_stamp)
		from #tmp_replication_status
		where agent_type & @anonymous_hide = 0
	end
	else if @publication = '%'
	begin
		select @return_status = max(status), 
				@return_timestamp = max(time_stamp)
		from #tmp_replication_status
		where agent_type & @anonymous_hide = 0 
		and publisher = upper(@publisher)
		-- process queued agents
		select @db_name = distribution_db 
		from msdb.dbo.MSdistpublishers 
		where name = @publisher collate database_default

		select @alt_return_status = max(status), 
				@alt_return_timestamp = max(time_stamp)
		from #tmp_replication_status
		where agent_type = @queue_agent 
		and publisher = upper(@@servername) 
		and publisher_db = @db_name

		if @alt_return_status > @return_status
			select @return_status = @alt_return_status

		if @alt_return_timestamp > @return_timestamp
			select @return_timestamp = @alt_return_timestamp
	end
	else
	begin
		select @return_status = max(status), 
				@return_timestamp = max(time_stamp)
		from #tmp_replication_status
		where agent_type & @anonymous_hide = 0 
		and publisher = upper(@publisher)
		and publisher_db = @publisher_db
		and publication = @publication

		-- if this is a transactional publication then include logreader info
		if exists(select publication_type 
					from #tmp_replication_status
					where agent_type = @snapshot_agent 
					and publisher = UPPER(@publisher)
					and publisher_db = @publisher_db
					and publication = @publication
					and publication_type = @tran_pubtype)
		begin
			select @alt_return_status = status, 
					@alt_return_timestamp = time_stamp
			from #tmp_replication_status
			where agent_type = @logreader_agent
				and publisher = UPPER(@publisher) 
				and publisher_db = @publisher_db 
				and publication = 'ALL'

			if @alt_return_status > @return_status
				select @return_status = @alt_return_status

			if @alt_return_timestamp > @return_timestamp
				select @return_timestamp = @alt_return_timestamp

			-- process the Queue reader entry separately and check if we need to pick them
			select @db_name = distribution_db 
			from msdb.dbo.MSdistpublishers 
			where name = @publisher collate database_default

			select @cmd = quotename(@db_name) + N'.dbo.sp_MSispublicationqueued'
			exec @return_code = @cmd
								@publisher = @publisher,
								@publisher_db = @publisher_db,
								@publication = @publication,
								@allow_queued_tran = @allow_queued_tran output
			if @return_code <> 0 and @@error <> 0
				goto Err_Handler

			if @allow_queued_tran = 1
			begin
				select @alt_return_status = max(status), 
						@alt_return_timestamp = max(time_stamp)
				from #tmp_replication_status
				where agent_type = @queue_agent 
					and publisher = upper(@@servername) 
					and publisher_db = @db_name

				if @alt_return_status > @return_status
					select @return_status = @alt_return_status

				if @alt_return_timestamp > @return_timestamp
					select @return_timestamp = @alt_return_timestamp
			end
		end
	end
	
	-- return result set
	select 'status' = isnull(@return_status, 0), 
	'timestamp' = isnull(left(replace(replace(replace(replace(convert(varchar, @return_timestamp, 121), '-', ''), ' ', ''), ':', ''), '.', ''), 16), '0000000000000000')

Done:
	return 0

Err_Handler:

	return 1
end
GO
GRANT EXECUTE ON [sys].[sp_MShelp_replication_status] TO [public] AS [dbo]
GO
