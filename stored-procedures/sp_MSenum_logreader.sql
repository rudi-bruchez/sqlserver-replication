SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSenum_logreader]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSenum_logreader] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSenum_logreader]
	@name [nvarchar](100),
	@show_distdb [bit]
WITH EXECUTE AS CALLER
AS
begin
	set nocount on

	declare @publisher sysname
	declare @publisher_db sysname
	declare @logreader_agent nvarchar(100)
	declare @status int
	declare @start_time nvarchar(24)
	declare @time nvarchar(24)
	declare @duration int
	declare @comments nvarchar(255)
	declare @delivery_time int
	declare @delivered_transactions int
	declare @delivered_commands int
	declare @average_commands int
	declare @delivery_rate int
	declare @delivery_latency int
	declare @error_id int
	declare @job_id binary(16)
	declare @local_job bit
	declare @profile_id int
	declare @agent_id int
	declare @last_timestamp binary(8)

	--
	-- security check
	-- only replmonitor can execute this
	--
	if not (is_member(N'db_owner') = 1 or isnull(is_member(N'replmonitor'),0) = 1)
	begin
		raiserror(14260, 16, -1)
		return (1)
	end

	create table #logreader_agent (name nvarchar(100) NOT NULL, status int NOT NULL,
		publisher sysname NOT NULL, publisher_db sysname NOT NULL,
		start_time nvarchar(24)  NULL, time nvarchar(24)  NULL, duration int  NULL, 
		comments nvarchar(255) NULL, delivery_time int NULL, 
		delivered_transactions int  NULL, delivered_commands int NULL, 
		average_commands int  NULL, delivery_rate int NULL, 
		delivery_latency int NULL, error_id int NULL, job_id binary(16) NULL,
		local_job bit NULL, profile_id int NOT NULL, agent_id int NOT NULL, last_timestamp binary(8) NOT NULL)  
   
    declare hC  CURSOR LOCAL FAST_FORWARD FOR
         select server.srvname, agent.publisher_db, name, 
            local_job, job_id, agent.profile_id, agent.id
            from
            MSlogreader_agents agent, MSreplservers server
            where 
            name LIKE @name and
            server.srvid = agent.publisher_id
        
        for read only

	OPEN hC
	FETCH hC INTO @publisher, @publisher_db, @logreader_agent, 
		@local_job, @job_id, @profile_id, @agent_id
	WHILE (@@fetch_status <> -1)
		begin

		/* Stuff in the values for no history case */
		select @status = 0, 
			@start_time = NULL,
			@time = NULL, @duration = NULL, @comments = NULL,
			@delivery_time = NULL, @delivered_transactions = NULL,
			@delivered_commands = NULL, @average_commands = NULL,
			@delivery_rate = NULL, @delivery_latency = NULL,
			@error_id = NULL,
			@last_timestamp = 0x00000000

		-- Get the status of the agent
		select @status = lh.runstatus, 
			@start_time = sys.fn_replformatdatetime(start_time),
			@time = sys.fn_replformatdatetime(time), 
			@duration = duration, 
			@comments = comments,
			@delivery_time = delivery_time, @delivered_transactions = delivered_transactions,
			@delivered_commands = delivered_commands, @average_commands = average_commands,
			@delivery_rate = delivery_rate, @delivery_latency = delivery_latency,
			@error_id = error_id, @last_timestamp = timestamp
			from MSlogreader_history lh with (READPAST) 
			where
			lh.agent_id = @agent_id and
			lh.timestamp = (select max(timestamp) from MSlogreader_history with (READPAST)
				where
				agent_id = lh.agent_id
			and comments not like N'<stats state%'	
				)

		insert into #logreader_agent values (@logreader_agent, @status, @publisher,
			@publisher_db, @start_time, @time, @duration, @comments,
			@delivery_time, @delivered_transactions, @delivered_commands, @average_commands,
			@delivery_rate, @delivery_latency, @error_id, @job_id, @local_job,
			@profile_id, @agent_id, @last_timestamp)

		FETCH hC INTO @publisher, @publisher_db, @logreader_agent, 
			@local_job, @job_id, @profile_id, @agent_id
		end

	if @show_distdb = 0
		select * from #logreader_agent 
	else 
		select 'dbname' = DB_NAME(), * from #logreader_agent

	drop table #logreader_agent
	close hC
	deallocate hC
end
GO
GRANT EXECUTE ON [sys].[sp_MSenum_logreader] TO [public] AS [dbo]
GO
