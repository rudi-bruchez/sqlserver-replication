SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSenum_distribution]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSenum_distribution] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSenum_distribution]
	@name [nvarchar](100),
	@show_distdb [bit],
	@exclude_anonymous [bit]
WITH EXECUTE AS CALLER
AS
begin
	set nocount on

	declare @publisher sysname
	declare @publisher_id smallint
	declare @publisher_db sysname
	declare @publication sysname
	declare @subscriber sysname
	declare @subscriber_id smallint
	declare @subscriber_db sysname
	declare @subscriber_name sysname
	declare @distribution_agent nvarchar(100)
	declare @status int
	declare @start_time nvarchar(24)
	declare @time nvarchar(24)
	declare @duration int
	declare @comments nvarchar(4000)
	declare @delivery_time int
	declare @delivered_transactions int
	declare @delivered_commands int
	declare @average_commands int
	declare @delivery_rate int
	declare @delivery_latency int   
	declare @subscription_type int
	declare @error_id int
	declare @job_id binary(16)
	declare @local_job bit
	declare @agent_id int
	declare @profile_id int
	declare @last_timestamp binary(8)
	declare @offload_enabled bit
	declare @offload_server  sysname
		,@subscriber_type tinyint

	--
	-- security check
	-- only replmonitor can execute this
	--
	if not (is_member(N'db_owner') = 1 or isnull(is_member(N'replmonitor'),0) = 1)
	begin
		raiserror(14260, 16, -1)
		return (1)
	end

	create table #distribution_agent (name nvarchar(100) NOT NULL, status int NOT NULL,
		publisher sysname NOT NULL, publisher_db sysname NOT NULL, publication sysname NULL,
		subscriber sysname NULL, subscriber_db sysname NULL,subscription_type int NULL, 
		start_time nvarchar(24) NULL, time nvarchar(24) NULL, duration int NULL, 
		comments nvarchar(4000) NULL, delivery_time int NULL, 
		delivered_transactions int NULL, delivered_commands int NULL, 
		average_commands int NULL, delivery_rate int NULL, delivery_latency int NULL,
		error_id int NULL, job_id binary(16) NULL, local_job bit NOT NULL,
		profile_id int NOT NULL, agent_id int NOT NULL, last_timestamp binary(8) NOT NULL, 
		offload_enabled BIT NOT NULL, offload_server sysname NULL,
		subscriber_type tinyint NULL)

	/* excluding virtual subscriptions */
	declare hC CURSOR LOCAL FAST_FORWARD FOR
		select id, name, publisher_id, publisher_db, publication, 
			subscriber_id, subscriber_db, subscription_type, local_job, job_id,
			profile_id, subscriber_name, offload_enabled, offload_server
			from
			MSdistribution_agents
			where 
			--No virtual subscription wanted
			name LIKE @name and (subscriber_id is NULL or subscriber_id>=0) and
			(@exclude_anonymous = 0 or anonymous_agent_id is null)
		for read only


	OPEN hC
	FETCH hC INTO @agent_id, @distribution_agent, @publisher_id, @publisher_db, @publication,
		@subscriber_id, @subscriber_db, @subscription_type, @local_job, @job_id, @profile_id, @subscriber_name, @offload_enabled, @offload_server
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

		select @status = isnull(runstatus, 0),
			@start_time = sys.fn_replformatdatetime(start_time),
			@time = sys.fn_replformatdatetime(time), 
			@duration = duration, 
			@comments = comments,
			@delivery_time = 0, @delivered_transactions = delivered_transactions,
			@delivered_commands = delivered_commands, @average_commands = average_commands,
			@delivery_rate = delivery_rate,
			@delivery_latency = delivery_latency,
			@error_id = error_id, @last_timestamp = timestamp   
			from MSdistribution_history with (READPAST)
			where
			agent_id = @agent_id and
			timestamp = (select max(timestamp) from MSdistribution_history with (READPAST)
				where agent_id = @agent_id
			and comments not like N'<stats state%'	
                )
            
            select @publisher = srvname from MSreplservers where srvid = @publisher_id
        IF @subscriber_name is NULL
		begin
                select @subscriber = srvname from MSreplservers where srvid=@subscriber_id 
				select @subscriber_type = type from MSsubscriber_info where
					UPPER(publisher) = UPPER(@publisher) and
					UPPER(subscriber) = UPPER(@subscriber)

		end
		ELSE 
			begin
				select @subscription_type = 2
				select @subscriber = @subscriber_name
				select @subscriber_db = @subscriber_db + '-' + convert(nvarchar(30), @agent_id)
			end
			
		insert into #distribution_agent values (@distribution_agent,
			@status, @publisher,
			@publisher_db, @publication, @subscriber, @subscriber_db, @subscription_type, 
			@start_time, @time, @duration, @comments,
			@delivery_time, @delivered_transactions, @delivered_commands, @average_commands,
			@delivery_rate, @delivery_latency, @error_id, @job_id, 
			@local_job, @profile_id, @agent_id, @last_timestamp, @offload_enabled, 
			@offload_server, @subscriber_type)

		FETCH hC INTO @agent_id, @distribution_agent, @publisher_id, @publisher_db, @publication,
			@subscriber_id, @subscriber_db, @subscription_type, @local_job, @job_id, 
			@profile_id, @subscriber_name, @offload_enabled, @offload_server
		end

	if @show_distdb = 0
		select * from #distribution_agent 
	else 
		select 'dbname' = DB_NAME(), * from #distribution_agent

	drop table #distribution_agent
	close hC
	deallocate hC
end
GO
GRANT EXECUTE ON [sys].[sp_MSenum_distribution] TO [public] AS [dbo]
GO
