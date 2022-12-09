SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSenum_snapshot]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSenum_snapshot] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSenum_snapshot]
	@name [nvarchar](100),
	@show_distdb [bit]
WITH EXECUTE AS CALLER
AS
begin
	set nocount on

	declare @publisher sysname
	declare @publisher_db sysname
	declare @publication sysname
	declare @publication_id int
	declare @snapshot_agent nvarchar(100)
	declare @status int
	declare @start_time nvarchar(24)
	declare @time nvarchar(24)
	declare @duration int
	declare @comments nvarchar(255)
	declare @delivered_transactions int
	declare @delivered_commands int
	declare @delivery_rate int
	declare @publisher_id smallint
	declare @error_id int
	declare @job_id binary(16)
	declare @local_job bit
	declare @profile_id int
	declare @agent_id int
	declare @last_timestamp binary(8)
	declare @suser_sname sysname
	declare @host_name sysname

	--
	-- security check
	-- only replmonitor can execute this
	--
	if not (is_member(N'db_owner') = 1 or isnull(is_member(N'replmonitor'),0) = 1)
	begin
		raiserror(14260, 16, -1)
		return (1)
	end

	create table #snapshot_agent (name nvarchar(100) NOT NULL, status int NOT NULL,
		publisher sysname NOT NULL, publisher_db sysname NOT NULL, publication sysname NOT NULL,
		start_time nvarchar(24)  NULL, time nvarchar(24)  NULL, duration int NULL, 
		comments nvarchar(255) NULL, delivered_transactions int NULL, delivered_commands int NULL,
		delivery_rate float  NULL, error_id int NULL, job_id binary(16) NULL, local_job bit NOT NULL,
		profile_id int NOT NULL, agent_id int NOT NULL, last_timestamp binary(8) NOT NULL,
		dynamic_filter_login sysname NULL, dynamic_filter_hostname sysname NULL)
  

    declare hC  CURSOR LOCAL FAST_FORWARD FOR
         select srvname, sa.publisher_db, sa.publication, sa.name, sa.publisher_id,
            sa.local_job, sa.job_id, sa.profile_id, sa.id, 
            sa.dynamic_filter_login, sa.dynamic_filter_hostname
            from
            MSsnapshot_agents sa, MSreplservers
            where 
            name LIKE @name and
            srvid = sa.publisher_id
        for read only

	OPEN hC
	FETCH hC INTO @publisher, @publisher_db, @publication, @snapshot_agent, @publisher_id,
		@local_job, @job_id, @profile_id, @agent_id, @suser_sname, @host_name
	WHILE (@@fetch_status <> -1)
		begin
	 
		-- Get the publication id
		select @publication_id = isnull(publication_id, 0) from dbo.MSpublications where
			publisher_id = @publisher_id and
			publisher_db = @publisher_db and
			publication = @publication
			
		-- Stuff in the values for no history case 
		select @status = 0, 
			@start_time = NULL,
			@time = NULL, @duration = NULL, @comments = NULL,
			@delivered_commands = NULL, 
			@delivery_rate = NULL, 
			@error_id = NULL,
			@last_timestamp = 0x00000000        
	   
		-- Get the status of the agent
		select @status = runstatus, 
			@start_time = sys.fn_replformatdatetime(start_time), 
			@time = sys.fn_replformatdatetime(time), 
			@duration = duration, 
			@comments = comments,
			@delivered_transactions = delivered_transactions,
			@delivered_commands = delivered_commands,
			@delivery_rate = delivery_rate, 
			@error_id = error_id, 
			@last_timestamp = timestamp
			from MSsnapshot_history with (READPAST)
			where
			agent_id = @agent_id and
			timestamp = (select top 1 timestamp from MSsnapshot_history with (READPAST) where           
				agent_id = @agent_id
				order by timestamp DESC) 
	
		insert into #snapshot_agent values (@snapshot_agent, @status, @publisher,
			@publisher_db, @publication, @start_time, @time, @duration, @comments,
			@delivered_transactions, @delivered_commands, @delivery_rate, @error_id, @job_id, 
			@local_job, @profile_id, @agent_id, @last_timestamp, @suser_sname, @host_name)

		FETCH hC INTO @publisher, @publisher_db, @publication, @snapshot_agent,
			@publisher_id, @local_job, @job_id, @profile_id, @agent_id, @suser_sname, @host_name
		end

	if @show_distdb = 0
		select * from #snapshot_agent 
	else 
		select 'dbname' = DB_NAME(), * from #snapshot_agent

	drop table #snapshot_agent
	close hC
	deallocate hC
end
GO
GRANT EXECUTE ON [sys].[sp_MSenum_snapshot] TO [public] AS [dbo]
GO
