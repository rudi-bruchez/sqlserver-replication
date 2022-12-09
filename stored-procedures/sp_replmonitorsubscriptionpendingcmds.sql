SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_replmonitorsubscriptionpendingcmds]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_replmonitorsubscriptionpendingcmds] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_replmonitorsubscriptionpendingcmds]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@subscriber [sysname],
	@subscriber_db [sysname],
	@subscription_type [int]
WITH EXECUTE AS CALLER
AS
begin
	set nocount on
	declare @retcode int
				,@agent_id int
				,@publisher_id int
				,@subscriber_id int
				,@lastrunts timestamp
				,@avg_rate float
				,@xact_seqno varbinary(16)
				,@inactive int = 1
				,@virtual int = -1

	--
	-- PAL security check done inside sp_MSget_repl_commands
	-- security: Has to be executed from distribution database
	--
	if sys.fn_MSrepl_isdistdb (db_name()) != 1
	begin
		raiserror (21482, 16, -1, 'sp_replmonitorsubscriptionpendingcmds', 'distribution')
		return 1
	end
	--
	-- validate @subscription_type
	--
	if (@subscription_type not in (0,1))
	begin
		raiserror(14200, 16, 3, '@subscription_type')
		return 1
	end

	 -- Get publisher without port number
	exec sys.sp_MSget_server_portinfo 
		@name = @publisher, 
		@srvname = @publisher OUTPUT

	exec sys.sp_MSget_server_portinfo 
		@name = @subscriber, 
		@srvname = @subscriber OUTPUT

	--
	-- get the server ids for publisher and subscriber
	--
    select @publisher_id = srvid from MSreplservers where upper(srvname) = upper(@publisher)
	if (@publisher_id is null)
	begin
		raiserror(21618, 16, -1, @publisher)
		return 1
	end
    select @subscriber_id = srvid from MSreplservers where upper(srvname) = upper(@subscriber)
	if (@subscriber_id is null)
	begin
		raiserror(20032, 16, -1, @subscriber, @publisher)
		return 1
	end
	--
	-- get the agent id
	--
	select @agent_id = id
	from dbo.MSdistribution_agents 
	where publisher_id = @publisher_id 
		and publisher_db = @publisher_db
		and publication in (@publication, 'ALL')
		and subscriber_id = @subscriber_id
		and subscriber_db = @subscriber_db
		and subscription_type = @subscription_type
	if (@agent_id is null)
	begin
		raiserror(14055, 16, -1)
		return (1)
	end;
	--
	-- Compute timestamp for latest run
	--
	with dist_sessions (start_time, runstatus, timestamp)
	as
	(
		select start_time, max(runstatus), max(timestamp) 
		from dbo.MSdistribution_history
		where agent_id = @agent_id
		and runstatus in (2,3,4)
		group by start_time 
	)
	select @lastrunts = max(timestamp)
	from dist_sessions;
	if (@lastrunts is null)
	begin
		--
		-- Distribution agent has not run successfully even once
		-- and virtual subscription of immediate sync publication is inactive (snapshot has not run), no point of returning any counts
		-- see SQLBU#320752, orig fix SD#881433, and regression bug VSTS# 140179 before you attempt to fix it differently :)
		if exists (select *
					from dbo.MSpublications p join dbo.MSsubscriptions s on p.publication_id = s.publication_id
					where p.publisher_id = @publisher_id 
						and p.publisher_db = @publisher_db
						and p.publication = @publication
						and p.immediate_sync = 1
							and s.status = @inactive and s.subscriber_id = @virtual) 
		begin
			select 'pendingcmdcount' = 0, N'estimatedprocesstime' = 0
			return 0
		end
		--
		-- Grab the max timestamp
		--
		select @lastrunts = max(timestamp)
		from dbo.MSdistribution_history
		where agent_id = @agent_id
	end
	--
	-- get delivery rate for the latest completed run
	-- get the latest sequence number
	--
	select @xact_seqno = xact_seqno
			,@avg_rate = delivery_rate
	from dbo.MSdistribution_history
	where agent_id = @agent_id
		and timestamp = @lastrunts
	--
	-- if no rows are selected in last query
	-- explicitly initialize these variables
	--
	select @xact_seqno = isnull(@xact_seqno, 0x0)
			,@avg_rate = isnull(@avg_rate, 0.0)
	--
	-- if we do not have completed run
	-- get the average for the agent in all runs
	--
	if (@avg_rate = 0.0)
	begin
		select @avg_rate = isnull(avg(delivery_rate),0.0)
		from dbo.MSdistribution_history
		where agent_id = @agent_id
	end
	--
	-- get the count of undelivered commands
	-- PAL check done inside
	--
	DECLARE @countab TABLE ( pendingcmdcount int )
	insert into @countab (pendingcmdcount)
		exec @retcode = sys.sp_MSget_repl_commands 
									@agent_id = @agent_id
									,@last_xact_seqno = @xact_seqno
									,@get_count = 2
									,@compatibility_level = 9000000
	if (@retcode != 0 or @@error != 0)
		return 1
	--
	-- compute the time to process
	-- return the resultset
	--
	select 
		pendingcmdcount  
		,N'estimatedprocesstime' = case when (@avg_rate != 0.0) 
								then cast((cast(pendingcmdcount as float) / @avg_rate) as int)
								else pendingcmdcount end
	from @countab
	--
	-- all done
	--
	return 0
end
GO
GRANT EXECUTE ON [sys].[sp_replmonitorsubscriptionpendingcmds] TO [public] AS [dbo]
GO
