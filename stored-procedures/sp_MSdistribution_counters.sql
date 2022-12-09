SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSdistribution_counters]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSdistribution_counters] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSdistribution_counters]
	@publisher [sysname]
WITH EXECUTE AS CALLER
AS
begin
	set nocount on

	declare @publisher_id smallint
	declare @subscriber_id smallint
	declare @active_status tinyint
	declare @snapshot_bit int
	declare @undelivered_commands int
	declare @delivered_commands int
	declare @delivery_rate float
	declare @delivery_latency int
	declare @xact_seqno varbinary(16)
	declare @agent_id int
	
	--
	-- security check
	-- only db_owner can execute this
	--
	if (is_member ('db_owner') != 1) 
	begin
		raiserror(14260, 16, -1)
		return (1)
	end

	select @active_status = 2
	select @snapshot_bit = 0x80000000

    -- Make sure publisher is defined on distributor
    --
    select @publisher_id = srvid from MSreplservers where UPPER(srvname) = UPPER(@publisher)
    if @publisher_id is null
       return (1)

	create table #dist_trans (subscriber_id smallint NOT NULL, undelivered_commands int NOT NULL, 
		delivered_commands int NOT NULL, delivery_rate float NOT NULL, 
		delivery_latency int NOT NULL)

	declare hc CURSOR LOCAL FAST_FORWARD FOR select distinct agent_id
		from dbo.MSsubscriptions
		where
		publisher_id = @publisher_id and
		subscriber_id >= 0 and
		status = 2
		for read only

	open hc
	fetch hc into  @agent_id
	while (@@fetch_status <> -1)
	begin
		-- Get the lastest numbers from distribution_history
		select  @xact_seqno = NULL

		-- Get latest seqno, rate and latency
		select TOP(1) @xact_seqno = xact_seqno,
--              @delivered_commands = delivered_commands,
				@delivery_rate = current_delivery_rate,
				@delivery_latency = current_delivery_latency
			-- from MSdistribution_history with (READPAST)
			from MSdistribution_history 
			where
			agent_id = @agent_id and
			xact_seqno <> 0x0
			order by timestamp DESC


		if @xact_seqno IS NULL
			select  @xact_seqno = 0x00,
					@delivery_rate = 0,
					@delivery_latency = 0



		select TOP(1) @subscriber_id = subscriber_id FROM dbo.MSsubscriptions
			where agent_id = @agent_id
		
		-- Get the delivered trans number
		select @delivered_commands = 0
		select @delivered_commands = isnull(count(*), 0)
			from
			-- MSrepl_commands rc with (READPAST), dbo.MSsubscriptions s
			MSrepl_commands rc, dbo.MSsubscriptions s
			where
			/*
			** Query from sp_MSget_repl_commands
			*/
			s.agent_id = @agent_id and
			s.status = @active_status and
			rc.publisher_database_id = s.publisher_database_id and
--          rc.publisher_id = s.publisher_id and
--          rc.publisher_db = s.publisher_db and
			rc.xact_seqno <= @xact_seqno and
			rc.article_id = s.article_id and
			rc.partial_command = 0
			and
			((rc.xact_seqno >= s.subscription_seqno and (rc.type & @snapshot_bit) <> @snapshot_bit) or
			rc.xact_seqno = s.subscription_seqno)

		-- Get the undelivered trans number
		select @undelivered_commands = 0
		select @undelivered_commands = isnull(count(*), 0)
			from
			-- MSrepl_commands rc with (READPAST), dbo.MSsubscriptions s
			MSrepl_commands rc , dbo.MSsubscriptions s
			where
			/*
			** Query from sp_MSget_repl_commands
			*/
			s.agent_id = @agent_id and
			s.status = @active_status and
			rc.publisher_database_id = s.publisher_database_id and
			rc.xact_seqno > @xact_seqno and
			rc.article_id = s.article_id and
			rc.partial_command = 0
			and
			((rc.xact_seqno >= s.subscription_seqno and (rc.type & @snapshot_bit) <> @snapshot_bit) or
			rc.xact_seqno = s.subscription_seqno)

		insert into #dist_trans values (@subscriber_id, @undelivered_commands,
			@delivered_commands, @delivery_rate, @delivery_latency)
		
		fetch hc into  @agent_id
	end

	close hc
	deallocate hc

    select 'subscriber' = srvname, 
            'delivered commands' = sum(delivered_commands),
            'undelivered_commands' = sum(undelivered_commands),
            'delivery_rate' = sum(delivery_rate),
            'delivery_latency' = (select isnull(avg(delivery_latency), 0) from #dist_trans, master.dbo.sysservers where
                srvname = s1.srvname and delivery_latency > 0)
        from #dist_trans, MSreplservers s1
        where subscriber_id = srvid
        group by srvname

	drop table #dist_trans
end        
GO
GRANT EXECUTE ON [sys].[sp_MSdistribution_counters] TO [public] AS [dbo]
GO
