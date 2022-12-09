SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSenum_subscriptions]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSenum_subscriptions] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSenum_subscriptions]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@exclude_anonymous [bit]
WITH EXECUTE AS CALLER
AS
begin
	declare @subscriber sysname
	declare @subscriber_id smallint
	declare @subscriber_db sysname
	declare @subscriber_name sysname
	declare @type int
	declare @status int
	declare @distribution_agent nvarchar(100)
	declare @publisher_id smallint
	declare @independent_agent bit
	declare @offload_enabled bit
	declare @offload_server sysname 

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
	declare @error_id int
	declare @publication_id int
	declare @job_id binary(16)
	declare @agent_id int
	declare @local_job bit
	declare @profile_id int
	declare @last_timestamp binary(8)
			,@subscriber_type tinyint

	set nocount on
	--
	-- security check
	-- only replmonitor can execute this
	--
	if not (is_member(N'db_owner') = 1 or isnull(is_member(N'replmonitor'),0) = 1)
	begin
		raiserror(14260, 16, -1)
		return (1)
	end

    select @publisher_id = srvid from MSreplservers where
       UPPER(srvname) = UPPER(@publisher)

	select @publication_id = publication_id from dbo.MSpublications where 
			publisher_id = @publisher_id and
			publisher_db = @publisher_db and
			publication = @publication and
			(publication_type = 0 or publication_type = 1)

	create table #subscriptions (subscriber sysname NOT NULL,  status int NOT NULL, 
		subscriber_db sysname NOT NULL,
		type tinyint NOT NULL, distribution_agent nvarchar(100) NOT NULL, last_action nvarchar(4000) NULL, 
		action_time nvarchar(24) NULL, start_time nvarchar(24) NULL, duration int NULL, 
		delivery_rate float NULL,
		delivery_latency int NULL, delivered_transactions int NULL, 
		delivered_commands int NULL,
		delivery_time int NULL, average_commands int NULL, 
		error_id int NULL, 
		job_id binary(16) NULL, local_job bit NULL, profile_id int NOT NULL,
		agent_id int NOT NULL, last_timestamp binary(8) NOT NULL, offload_enabled bit NOT NULL, 
		offload_server sysname NULL, subscriber_type tinyint NULL)
	
	-- This is to force all queries to return rows ordered by job_id
	-- Note: There might be dist agents left for cleaning up sub, in this case
	-- they are not in sub table and we don't want to show them
	create unique clustered index ucsubscriptions ON #subscriptions (agent_id)
	declare hC CURSOR LOCAL FAST_FORWARD FOR select id, name, subscriber_id, subscriber_db,
		job_id, local_job, subscription_type, profile_id, subscriber_name, offload_enabled,
		offload_server 
		from MSdistribution_agents a
		where exists (select * from dbo.MSsubscriptions s where
			(a.id = s.agent_id or a.anonymous_agent_id = s.agent_id) and
			s.publisher_id = @publisher_id and
			s.publisher_db = @publisher_db and
			-- For 6.x publisher, we don't know the association between the publication
			-- and subscriptions. Show every dist agent under each publication.
			(s.publication_id = @publication_id or s.publication_id = 0 ) and
			(a.subscriber_id >= 0  or a.subscriber_id is NULL)) and 
			(@exclude_anonymous = 0 or a.anonymous_agent_id is null)
		for read only

	-- declare hC CURSOR LOCAL FAST_FORWARD FOR select a.id, a.name, a.subscriber_id, ms.subscriber_db,
	--  a.job_id, a.local_job, ms.subscription_type, a.profile_id, a.subscriber_name
	--    from MSdistribution_agents a, master.dbo.sysservers s, dbo.MSsubscriptions ms
	--    where
	--    a.publisher_id = @publisher_id and
	--    a.publisher_db = @publisher_db and
	--  (a.publication = @publication or a.publication = 'ALL') and
	--  a.subscriber_id >= 0 and
	--  ms.publisher_db = @publisher_db and
	--  ms.publication_id = @publication_id and
	--  ms.subscriber_id = a.subscriber_id and
	--  ms.subscriber_db = a.subscriber_db and
	--  s.srvid = ms.subscriber_id
	--  for read only

	open hC
	fetch hC into  @agent_id, @distribution_agent, @subscriber_id, @subscriber_db,
		@job_id, @local_job, @type, @profile_id, @subscriber_name, @offload_enabled, 
		@offload_server
	while (@@fetch_status <> -1)
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
		select @status = runstatus, 
			@start_time = sys.fn_replformatdatetime(start_time),
			@time = sys.fn_replformatdatetime(time),
			@duration = duration, 
			@comments = comments,
			@delivery_time = 0, @delivered_transactions = delivered_transactions,
			@delivered_commands = delivered_commands, @average_commands = average_commands,
			-- Note: return average rate here !!! delivery_rate column is current rate
			@delivery_rate = delivery_rate,
			@delivery_latency = delivery_latency,
			@error_id = error_id, @last_timestamp = timestamp
			from MSdistribution_history with (READPAST)
			where
				agent_id = @agent_id and
				timestamp = (select max(timestamp) from MSdistribution_history with (READPAST) 
					where 
					agent_id = @agent_id)

		-- For anonymous subscriptions, @subscriber_name is not NULL
		 if @subscriber_name is NULL
		 begin
            select @subscriber = srvname from MSreplservers where srvid=@subscriber_id
			select @subscriber_type = type from MSsubscriber_info where
				UPPER(publisher) = UPPER(@publisher) and
				UPPER(subscriber) = UPPER(@subscriber)
		 end
		 else 
		 begin
			select @subscriber = @subscriber_name
			select @subscriber_db = @subscriber_db + '-' + convert(nvarchar(30), @agent_id)
			-- Don't know the subscriber type for anonymous
		 end

		insert into #subscriptions values ( @subscriber, @status, @subscriber_db,
			@type, @distribution_agent, @comments, @time, @start_time, @duration,
			@delivery_rate, @delivery_latency, @delivered_transactions, 
			@delivered_commands,  @delivery_time, @average_commands,
			@error_id, @job_id, @local_job, @profile_id, @agent_id, @last_timestamp,
			@offload_enabled, @offload_server, @subscriber_type)

		fetch hC into  @agent_id, @distribution_agent, @subscriber_id, @subscriber_db,
			@job_id, @local_job, @type, @profile_id, @subscriber_name, @offload_enabled,
			@offload_server
	  end

	select * from #subscriptions order by job_id asc 

	drop table #subscriptions
	close hC
	deallocate hC
end
GO
GRANT EXECUTE ON [sys].[sp_MSenum_subscriptions] TO [public] AS [dbo]
GO
