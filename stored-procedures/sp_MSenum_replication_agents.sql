SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSenum_replication_agents]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSenum_replication_agents] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSenum_replication_agents]
	@type [int],
	@exclude_anonymous [bit],
	@check_user [bit]
WITH EXECUTE AS CALLER
AS
begin
	set nocount on
	declare  @retcode int
				,@snapshot int
				,@logreader int
				,@distribution int
				,@sproc sysname
				,@db_name sysname
				,@table_name sysname
				,@cmd nvarchar(4000)
				,@distbit int
				,@merge int
				,@misc int
				,@qreader int
				,@has_pm bit

	--
	-- initialize
	--
	select @retcode = 0
			,@distbit = 16
			,@snapshot = 1
			,@logreader = 2
			,@distribution = 3
			,@merge = 4
			,@misc = 5
			,@qreader = 9
	--
	-- validate @type
	--
	if (@type not in (@snapshot,@logreader,@distribution,@merge,@misc,@qreader))
	begin
		return (1)
	end
	--
	-- more initialization based on agent type
	--
	select @table_name = case when (@type = @snapshot) then '#snapshot'
											when (@type = @logreader) then '#logreader'
											when (@type = @distribution) then '#distribution'
											when (@type = @merge) then '#merge'
											when (@type = @qreader) then '#qreader' end
			,@sproc = case when (@type = @snapshot) then 'sp_MSenum_snapshot'
											when (@type = @logreader) then 'sp_MSenum_logreader'
											when (@type = @distribution) then 'sp_MSenum_distribution'
											when (@type = @merge) then 'sp_MSenum_merge'
											when (@type = @qreader) then 'sp_MSenum_qreader' end
	--
	-- For each distribution database collect meta 
	--
	declare #hCdatabase CURSOR LOCAL FAST_FORWARD FOR
		select name 
		from master.dbo.sysdatabases 
		where category & @distbit <> 0 
			and has_dbaccess(name) = 1
	for read only

	open #hCdatabase
	fetch next from #hCdatabase into @db_name
	while (@@fetch_status <> -1)
	begin
		--
		-- Check to see if the user has permision to monitor the distribution database.
		--
		select @cmd = quotename(@db_name) + '.sys.sp_executesql'
		exec @cmd
			N'if is_member(N''db_owner'') = 1 or isnull(is_member(N''replmonitor''),0) = 1 set @has_pm = 1', 
			N'@has_pm bit output',
			@has_pm output
		if @has_pm = 1
		begin
			--
			-- The current user has permission to access the metadata
			--
			if @check_user = 1
			begin
				--
				-- @check_user option enabled - no need to return agent metadata
				--
				select 'is_replmonitor' = 1
				return (0)
			end
			else
			begin
				--
				-- @check_user option disabled
				-- Process based on agent type
				--
				if @type = @misc
				begin
					--
					--Misc agent type - execute and return
					--
					exec @retcode = sys.sp_MSenum_misc_agents
					return @retcode
				end
				else
				begin
					--
					-- Other agent type
					-- Create temp table if necessary to cache the agent metadata
					--
					if object_id (N'tempdb..' + @table_name) is null
					begin
						--
						-- initialize the temp tables
						--
						if @type = @snapshot
						begin
							create table #snapshot (dbname sysname collate database_default not null, name nvarchar(100) collate database_default not null, 
								status int NOT NULL,
								publisher sysname collate database_default not null, publisher_db sysname collate database_default not null, 
								publication sysname collate database_default not null,
								start_time nvarchar(24) collate database_default null, time nvarchar(24) collate database_default null, duration int NULL,
								comments nvarchar(255) collate database_default null, delivered_transactions int NULL, 
								delivered_commands int NULL, delivery_rate float NULL, error_id INT NULL,
								job_id binary(16) NULL, local_job bit NULL, profile_id int NOT NULL, 
								agent_id int NOT NULL, local_timestamp binary(8) NOT NULL,
								dynamic_filter_login sysname NULL, dynamic_filter_hostname sysname NULL)

							create unique clustered index ucsnapshot ON #snapshot (dbname, agent_id)
						end
						else if @type = @logreader
						begin
							create table #logreader (dbname sysname collate database_default not null, name nvarchar(100) collate database_default not null,  
								status int NOT NULL,
								publisher sysname collate database_default not null, publisher_db sysname collate database_default not null,
								start_time nvarchar(24) collate database_default null, time nvarchar(24) collate database_default null, duration int NULL,
								comments nvarchar(255) collate database_default null, delivery_time int NULL, 
								delivered_transactions int NULL, delivered_commands int NULL, 
								average_commands int NULL, delivery_rate int NULL, delivery_latency int NULL, 
								error_id INT NULL, job_id binary(16) NULL, local_job bit NULL,
								profile_id int NOT NULL, agent_id int NOT NULL, local_timestamp binary(8) NOT NULL)

							create unique clustered index uclogreader ON #logreader (dbname, agent_id)
						end
						else if @type = @distribution
						begin
							create table #distribution (dbname sysname collate database_default not null, 
								name nvarchar(100) collate database_default not null,  
								status int NOT NULL,
								publisher sysname collate database_default not null, publisher_db sysname collate database_default not null, 
								publication sysname collate database_default null,
								subscriber sysname collate database_default null, subscriber_db sysname collate database_default null, subscription_type int NULL,
								start_time nvarchar(24) collate database_default null, time nvarchar(24) collate database_default null, duration int NULL,
								comments nvarchar(4000) NULL, delivery_time int NULL, 
								delivered_transactions int NULL, delivered_commands int NULL, 
								average_commands int NULL, delivery_rate int NULL, 
								delivery_latency int NULL, error_id INT NULL,
								job_id binary(16) NULL, local_job bit NULL, profile_id int NOT NULL, 
								agent_id int NOT NULL, local_timestamp binary(8) NOT NULL, 
								offload_enabled bit NOT NULL, offload_server sysname collate database_default null,
								subscriber_type tinyint NULL)

							create unique clustered index ucdistribution ON #distribution (dbname, agent_id)
						end
						else if @type = @merge
						begin
							create table #merge (dbname sysname collate database_default not null, name nvarchar(100) collate database_default not null, 
								status int NOT NULL,
								publisher sysname collate database_default not null, publisher_db sysname collate database_default not null, publication sysname collate database_default null,
								subscriber sysname collate database_default null, subscriber_db sysname collate database_default null, subscription_type int NULL,
								start_time nvarchar(24) collate database_default null, time nvarchar(24) collate database_default null, duration int NULL, 
								comments nvarchar(255) NULL, delivery_rate int NULL,
								download_inserts int NULL, download_updates int NULL, download_deletes int NULL,
								publisher_conficts int NULL, 
								upload_inserts int NULL, upload_updates int NULL, upload_deletes int NULL,
								subscriber_conficts int NULL, error_id int NULL, job_id binary(16) NULL,
								local_job bit NULL, profile_id int NOT NULL, agent_id int NOT NULL, 
								local_timestamp binary(8) NOT NULL, offload_enabled bit NOT NULL, 
								offload_server sysname collate database_default null, subscriber_type tinyint NULL)

							create unique clustered index ucmerge ON #merge (dbname, agent_id)
						end
						else if @type = @qreader
						begin
							create table #qreader (dbname sysname collate database_default not null, 
								name nvarchar(100) collate database_default not null, status int NOT NULL,
								start_time nvarchar(24) collate database_default null, time nvarchar(24) collate database_default null, duration int NULL,
								comments nvarchar(255) collate database_default null, 
								transactions_processed int NULL, commands_processed int NULL, 
								average_commands int NULL, delivery_rate int NULL, delivery_latency int NULL,
								error_id INT NULL, job_id binary(16) NULL, 
								profile_id int NULL, agent_id int NOT NULL, local_timestamp binary(8) NOT NULL)

							create unique clustered index ucqreader ON #qreader (dbname, agent_id)
						end
						--
						-- Check for errors
						--
						if (@@error != 0)
							return (1)
					end -- if object_id( tempdb table ) is null
					--
					-- script the insert command to cache the agent metadata in temp table 
					-- for this distribution database
					--
					select @cmd = 'insert into ' + @table_name +
						' exec ' + quotename(@db_name) + '.dbo.' + @sproc + ' @show_distdb = 1' 
					--
					-- for distribution and merge agents - add more parameters to command
					--
					if @type in (@distribution, @merge)
						select @cmd = @cmd +
							', @exclude_anonymous = ' + cast(@exclude_anonymous as nvarchar(1))
					--
					-- execute the insert command
					--
					exec (@cmd)
					--
					-- Check errors
					--
					if (@@error != 0)
						return (1)
				end -- other agent type
			end -- @check_user option disabled
		end -- if @has_pm = 1
		--
		-- fetch next distribution database to process
		--
		fetch next from #hCdatabase into @db_name
	end
	close #hCdatabase
	deallocate #hCdatabase
	--
	-- Don't return agents if in check user mode
	-- NOTE - is this codeblock necessary
	--
	if @check_user = 1
		return (0)
	--
	-- Process If the table exists
	--
	if object_id (N'tempdb..' + @table_name) is not null
	begin
		--
		-- All done - select all the metadata
		--
		select @cmd = N'select * from ' + @table_name + N' order by dbname asc, agent_id asc'
		exec (@cmd)
		--
		-- Drop the table
		--
		select @cmd = N'drop table ' + @table_name
		exec (@cmd)
	end
	--
	-- all done
	--
	return (0)
end
GO
GRANT EXECUTE ON [sys].[sp_MSenum_replication_agents] TO [public] AS [dbo]
GO
