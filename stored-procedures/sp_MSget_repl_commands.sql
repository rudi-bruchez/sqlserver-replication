SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSget_repl_commands]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSget_repl_commands] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSget_repl_commands]
	@agent_id [int],
	@last_xact_seqno [varbinary](16),
	@get_count [tinyint],
	@compatibility_level [int],
	@subdb_version [int],
	@read_query_size [int]
WITH EXECUTE AS CALLER
AS
begin
	set nocount on

	declare @active_status tinyint
			,@initiate_status tinyint
			,@snapshot_bit int
			,@postcmd_bit int
			,@synctran_type int
			,@read_only tinyint
			,@retcode int
			,@publisher_database_id int
			,@originator_id int
			,@subscriber sysname
			,@subscriber_db sysname
			,@subscriber_id smallint
			,@publisher sysname
			,@publisher_db sysname
			,@publication sysname
			,@publisher_id smallint
			,@max_xact_seqno varbinary(16)
			,@concurrent int
			,@concurrent_c int
			,@IsP2PAgent bit
			,@undelivered_commands int
			,@undelivered_transactions int

	declare @peer_originator_ids table(id int primary key)

	select @read_only = 0
			,@active_status = 2
			,@initiate_status = 3
			,@snapshot_bit = 0x80000000
			,@postcmd_bit = 0x40000000
			,@concurrent = 3
			,@concurrent_c = 4
			,@undelivered_commands = 0
			,@undelivered_transactions = 0
	select @synctran_type = @snapshot_bit | 9

    -- Security Check
    -- @agent_id might be null when it comes from sp_MSget_repl_cmd_anonymous
    if @agent_id is not null
    begin
        exec @retcode = sys.sp_MScheck_pull_access
            @agent_id = @agent_id,
            @agent_type = 0 -- distribution agent
        if @@error <> 0 or @retcode <> 0
            return (1)
    end
    else
    begin
        return (1)
    end
    -- validate @get_count
    if @get_count not in (0,1,2)
        return (1)
    -- Get publisher database id etc.
    SELECT @publisher_database_id = publisher_database_id,
                @publisher_db = publisher_db,
                @publisher_id = publisher_id,
                @subscriber_id = subscriber_id, 
                @subscriber_db = subscriber_db,
                @publication = publication,
                @publisher = srvname
    from MSdistribution_agents 
        inner join MSreplservers 
            on srvid = publisher_id
    where id = @agent_id

	-- Find out if there are any PeerToPeer publications for this agent
	-- If so, we will generate extra "originator" columns in the resultset
	exec sys.sp_MSispeertopeeragent @agent_id = @agent_id, @is_p2p = @IsP2PAgent output

	-- Get the last xact_seqno on the pub db FIRST. It will
	-- be used as the upper bound for differnt queries. We have to do
	-- this to prevent transactions on new or changed subscriptions or
	-- with new orignator_id being skipped eigher by preselected query or
	-- preselected originator_id.
	-- Have to have readpast here to prevent the query be blocked by logreader
	-- (even before the first row to the dist agent).
	--
	-- Note:  DO NOT consider distcmds inserted for a concurrent snapshot
	-- These represent 'forward in time' xacts.  Skipping past these xacts
	-- can cause lost transactions!
	--
	-- Note2: consider adding new MSrepl_commands idx with keys:  
	-- publisher_database_id, command_id, type, xact_seqno
	--
	-- Note3: might be able to use replpostcmd + a LSN mapping token to 
	-- allow SS agent to post sync cmds to log instead of dist db.
	--
	-- Note4 : The max_xact_seqno is calculated based on the @read_query_size parameter - this parameter
	--         limit the number of commands retrieved by this call.  
	if(@read_query_size <= 0)
	begin
		select @max_xact_seqno = max(xact_seqno) from MSrepl_commands with (READPAST)
		  where 
			 publisher_database_id = @publisher_database_id and
			 command_id = 1 and
			 type <> -2147483611 
	end
	else
	begin
		 -- calculate the @max_xact_seqno from the next @read_query_size commands.
		 declare @GetMaxCommand nvarchar(1024)
		 select @GetMaxCommand = N'select top ' + convert(nvarchar(1024),@read_query_size)+
		 N' @max_xact_seqno = xact_seqno from MSrepl_commands with (READPAST)
		 where 
			 publisher_database_id = @publisher_database_id and
			 type <> -2147483611 and
			 xact_seqno > @last_xact_seqno
			 order by xact_seqno, command_id asc' 

			 exec sys.sp_executesql 
					 @GetMaxCommand,
					 N'@max_xact_seqno varbinary(16) output ,@last_xact_seqno varbinary(16),@publisher_database_id int',
					 @publisher_database_id = @publisher_database_id,
					 @max_xact_seqno = @max_xact_seqno output,
					 @last_xact_seqno=@last_xact_seqno         

			 if(@max_xact_seqno is null)
				select @max_xact_seqno = @last_xact_seqno
	end


	-- If there's nothing to do, return here to avoid more queries.
	if @max_xact_seqno = @last_xact_seqno
	begin
		if @get_count in (1,2)
		begin
			if (@get_count = 2)
			begin
				select N'undelivered_commands' = @undelivered_commands 
			end
			else -- @get_count = 1
			begin
				select 
					N'undelivered_commands' = @undelivered_commands, 
					N'undelivered_transactions' = @undelivered_transactions 
			end
		end
		else -- @get_count = 0
		begin
			select rc.xact_seqno, rc.partial_command, rc.type, 
				rc.command_id, rc.command
				from                
					MSrepl_commands rc
				where 0 = 1
			select @max_xact_seqno
		end
		return 0
	end

    -- Get subscriber name
    select @subscriber = srvname from MSreplservers where
        srvid = @subscriber_id
        
    -- Note: if no originator id in the table, it will be 0, so that no loop back
    -- detection will be done!.
    -- Since the logreader will insert into the MSrepl_originators table,
    -- this query has to be later then get max seqno query!!!!!
    select @originator_id = 0

	if @IsP2PAgent = 0
	begin    
		select @originator_id = ISNULL(id, 0) from MSrepl_originators where
			publisher_database_id = @publisher_database_id and
			UPPER(srvname) = UPPER(@subscriber) and
			dbname = @subscriber_db and
			publication_id is NULL and
			dbversion is NULL
	end
	else
	begin
		-- for the peer to peer case we need to make sure to retrieve the  
		-- originator id based on the dbversion. 
		--
		-- keep in mind that if we don't find a row then the values in @peer_originator_ids
		-- will be 0. This is ok since this can only occur if:
		--		1. No commands have been inserted into the distribution db for the  
		--		   subscriber and we are delivering snapshot commands. This is ok 
		--		   since we do not perform loop-back detection for snapshot commands.
		--		or
		--		2. We just restored the subscriber and we are attempting to reapply
		--		   all missing commands. In this case the query to retrieve all commands
		--		   process correctly since the commands originating from the subscriber
		--		   must be applied and we know that no new commands should be generated
		--		   until all past commands have been delivered.
		insert into @peer_originator_ids (id)
			select distinct id
				from MSrepl_originators 
					where publisher_database_id = @publisher_database_id 
						and UPPER(srvname) = UPPER(@subscriber) 
						and dbname = @subscriber_db
						and dbversion = @subdb_version
						and publication_id is not NULL

		if not exists(select *
						from @peer_originator_ids)
		begin
			insert into @peer_originator_ids(id) values(0)
		end
	end

	if @get_count in (1,2)
	begin
		--
		-- Performance impact
		-- Issue the select for counts separately
		-- Do first select for undelivered commands
		--
		select @undelivered_commands = count(*)
		from MSrepl_commands rc WITH (NOLOCK) 
			JOIN dbo.MSsubscriptions s
				ON (rc.article_id = s.article_id 
					AND rc.publisher_database_id=s.publisher_database_id )
		where

		s.agent_id = @agent_id and
		s.status = @active_status and
		rc.publisher_database_id = @publisher_database_id and
		rc.xact_seqno > @last_xact_seqno and
		rc.xact_seqno <= @max_xact_seqno and
		-- If log based transaction, we do
		-- 1. only select tran later than sub pub seqno
		-- 2. loopback detection
		(((rc.type & @snapshot_bit) <> @snapshot_bit and
		rc.xact_seqno > s.publisher_seqno and
		rc.xact_seqno > s.ss_cplt_seqno and
		--
		-- Loopback detection
		--
		(s.loopback_detection = 0 
			or (@originator_id != 0 
				and rc.originator_id <> @originator_id)
			or @originator_id = 0)) or 
		-- If snapshot transaction, we do
		-- 1. filter out the  snapshot transactions that were inserted later that is not
		-- the subscription's snapshot transaction
		-- 2. filter out trigger generation command for non synctran subscription.
		-- Note: don't do loop back detection.
		((rc.type & @snapshot_bit) = @snapshot_bit and 
		rc.xact_seqno >= s.subscription_seqno and 
		rc.xact_seqno <= s.ss_cplt_seqno and
		(s.update_mode <> @read_only or rc.type <> @synctran_type))) and
		-- Filter out the new command types that we have introduced after 9.0
		(@compatibility_level >= 10000000 or
		(rc.type & ~@snapshot_bit & ~@postcmd_bit) not in 
		(105)) and
		-- Filter out the new command types that we have introduced after 8.0
		(@compatibility_level >= 9000000 or
		(rc.type & ~@snapshot_bit & ~@postcmd_bit) not in 
		(13, 86, 87, 88, 89, 90, 91, 92, 93, 94, 95, 96, 97, 98, 99, 31, 32, 33, 47, 102)) and
		-- Filter out the new command types that we have introduced after 7.0
		(@compatibility_level > 7000000 or
		(rc.type & ~@snapshot_bit) not in 
		(25, 40, 45, 50, 51, 52, 53, 54, 55, 56 ,57, 58, 60, 68, 69))
		--
		-- process undelivered transaction only if @get_count = 1
		-- 
		if (@get_count = 2)
		begin
			select N'undelivered_commands' = @undelivered_commands
		end
		else
		begin
			--
			-- Do second select for undelivered transactions
			-- TBD - see if MSrepl_transactions can be used instead of MSrepl_commands
			--
			select @undelivered_transactions = count(distinct xact_seqno) 
			from MSrepl_commands rc WITH (NOLOCK) 
				JOIN dbo.MSsubscriptions s
					ON (rc.article_id = s.article_id 
						AND rc.publisher_database_id=s.publisher_database_id )        
			where

			s.agent_id = @agent_id and
			s.status = @active_status and
			rc.publisher_database_id = @publisher_database_id and
			rc.xact_seqno > @last_xact_seqno and
			rc.xact_seqno <= @max_xact_seqno and
			-- If log based transaction, we do
			-- 1. only select tran later than sub pub seqno
			-- 2. loopback detection
			(((rc.type & @snapshot_bit) <> @snapshot_bit and
			rc.xact_seqno > s.publisher_seqno and
			rc.xact_seqno > s.ss_cplt_seqno and
			--
			-- Loopback detection
			--
			(s.loopback_detection = 0 
				or (@originator_id != 0 
					and rc.originator_id <> @originator_id)
				or @originator_id = 0)) or 
			-- If snapshot transaction, we do
			-- 1. filter out the  snapshot transactions that were inserted later that is not
			-- the subscription's snapshot transaction
			-- 2. filter out trigger generation command for non synctran subscription.
			-- Note: don't do loop back detection.
			((rc.type & @snapshot_bit) = @snapshot_bit and 
			rc.xact_seqno >= s.subscription_seqno and 
			rc.xact_seqno <= s.ss_cplt_seqno and
			(s.update_mode <> @read_only or rc.type <> @synctran_type))) and
			-- Filter out the new command types that we have introduced after 9.0
			(@compatibility_level >= 10000000 or
			(rc.type & ~@snapshot_bit & ~@postcmd_bit) not in 
			(105)) and
			-- Filter out the new command types that we have introduced after 8.0
			(@compatibility_level >= 9000000 or
			(rc.type & ~@snapshot_bit & ~@postcmd_bit) not in 
			(13, 86, 87, 88, 89, 90, 91, 92, 93, 94, 95, 96, 97, 98, 99, 31, 32, 33, 47, 102)) and
			-- Filter out the new command types that we have introduced after 7.0
			(@compatibility_level > 7000000 or
			(rc.type & ~@snapshot_bit) not in 
			(25, 40, 45, 50, 51, 52, 53, 54, 55, 56 ,57, 58, 60, 68, 69))
			
			select N'undelivered_commands' = @undelivered_commands,
				   N'undelivered_transactions' = @undelivered_transactions 
		end
				
		return(0)
	end

	-- if this agent is servicing any inactive concurrent sync articles
	-- then return no rows.  The concurrent sync article will be activated
	-- when the SYNCDONE token is written to the distribution db by the logreader
	-- at this point, all log records associated with the sync will be present in 
	-- MSrepl_commands

	if exists( SELECT * FROM dbo.MSsubscriptions s JOIN dbo.MSpublications p 
			   ON( 	s.publisher_id = p.publisher_id and
					s.publisher_db = p.publisher_db and
					s.publication_id = p.publication_id )
			   WHERE
				s.agent_id = @agent_id and
				s.status = @initiate_status and
				(p.sync_method = @concurrent or p.sync_method = @concurrent_c) )
	begin
		select rc.xact_seqno, rc.partial_command, rc.type, 
			rc.command_id, rc.command
			from                
				MSrepl_commands rc
			where 0 = 1
		select @last_xact_seqno
		return 0
	end

	-- Decide on a best query method.
	-- Note: The order of the following queries is important and
	-- not abitrary.
	
	-- Get subscription info
	declare @num_non_active int
	declare @num_article int
	declare @num_loopback int
	declare @max_sub_seqno varbinary(16)
	declare @max_pub_seqno varbinary(16)

	select 
		@num_non_active = sum(case when status <> @active_status then 1 else 0 end),
		@num_article 	= count(*),
		@num_loopback   = sum(case when loopback_detection <> 0 then 1 else 0 end),
		@max_sub_seqno  = max(subscription_seqno),
		@max_pub_seqno = max(publisher_seqno)
		from dbo.MSsubscriptions where
			agent_id = @agent_id
			
	if  @last_xact_seqno < @max_sub_seqno or  
		@last_xact_seqno < @max_pub_seqno or 
		@num_non_active <> 0
	-- The agent is still working on snapshot transactions. Need a full join in this case
	begin

		-- Need a work table to remember the set of snapshot transaction 
		-- sequence numbers that need to be applied by this agent, this 
		-- table of subscription sequence numbers can then be used to make 
		-- sure that snapshot control (header/trailer) associated with 
		-- incremental snapshot commands are enumerated
		declare @snapshot_seqnos table (subscription_seqno varbinary(16) primary key)

		insert into @snapshot_seqnos 
			select distinct subscription_seqno
				from dbo.MSsubscriptions
			 	where agent_id = @agent_id
			   		and subscription_seqno > @last_xact_seqno

		 -- in case of @last_xact_seqno = 0x0 we can adjust it to the
		 -- min subscription_seqno of of all articles for this subscriptions minus one.
		 -- This will boost perf.
		 if (@last_xact_seqno = 0x0)
		 begin
				  select @last_xact_seqno = CONVERT(varbinary(16),min(subscription_seqno))
				  from @snapshot_seqnos

				  if(@last_xact_seqno = 0x0 or @last_xact_seqno is null)
					select @last_xact_seqno = 0x0;
				  else -- dec 1
				  begin
					  declare @low as bigint
					  declare @high as bigint
					  select @high = substring(@last_xact_seqno,1,8)
					  select @low = substring(@last_xact_seqno,9,8)
					  if(@low <> 0)
						select @low = @low - 1
					  else
					  begin
						select @high=@high - 1
						select @low = 0xFFFFFFFFFFFFFFFFFFFF
					  end

					  select @last_xact_seqno = convert(varbinary(16),@high) + convert(varbinary(16),@low) 
				  end
		  end 

		-- no loopback and no PeerToPeer publications
		if @originator_id = 0 and @IsP2PAgent = 0
		begin
			-- Join with every thing but no loop back
			select rc.xact_seqno, rc.partial_command, rc.type, 
				rc.command_id, rc.command, rc.hashkey,
				NULL, NULL, NULL, NULL, NULL, NULL, rc.article_id
				from 
					MSrepl_commands rc with (INDEX(ucMSrepl_commands))
					JOIN dbo.MSsubscriptions s with (INDEX(ucMSsubscriptions))
						-- At end, we use the FASTFIRSTROW option which tends to force
						-- a nested inner loop join driven from MSrepl_commands
						ON (rc.article_id = s.article_id AND rc.publisher_database_id=s.publisher_database_id )
				where

				s.agent_id = @agent_id and
				s.status = @active_status and
				rc.publisher_database_id = @publisher_database_id and
				rc.xact_seqno > @last_xact_seqno and
				rc.xact_seqno <= @max_xact_seqno and
				-- If log based transaction, we do
				-- 1. only select tran later than sub pub seqno
				-- 2. only select tran later than ss_cplt_seqno 
				(((rc.type & @snapshot_bit) <> @snapshot_bit and
				rc.xact_seqno > s.publisher_seqno and
				rc.xact_seqno > s.ss_cplt_seqno ) 
				or 
				-- If snapshot transaction, we do
				-- 1. filter out the  snapshot transactions that were inserted later that is not
				-- the subscription's snapshot transaction
				-- 2. filter out trigger generation command for non synctran subscription.
				-- Note: don't do loop back detection.
				((rc.type & @snapshot_bit) = @snapshot_bit and 
				((rc.xact_seqno >= s.subscription_seqno and 
				  rc.xact_seqno <= s.ss_cplt_seqno) or 
				 (rc.xact_seqno in (select subscription_seqno from @snapshot_seqnos) and (rc.type & ~@snapshot_bit) in (25, 50, 51, 52, 53, 54, 55, 56 ,57, 58))) and -- Command type list must match that in sp_MSdrop_article
				(s.update_mode <> @read_only or rc.type <> @synctran_type))) and
				-- Filter out the new command types that we have introduced after 9.0
				(@compatibility_level >= 10000000 or
				(rc.type & ~@snapshot_bit & ~@postcmd_bit) not in 
				(105)) and
				-- Filter out the new command types that we have introduced after 8.0
				(@compatibility_level >= 9000000 or
				(rc.type & ~@snapshot_bit & ~@postcmd_bit) not in 
				(13, 86, 87, 88, 89, 90, 91, 92, 93, 94, 95, 96, 97, 98, 99, 31, 32, 33, 47, 100, 101, 102, 104)) and
				-- Filter out the new command types that we have introduced after 7.0
				(@compatibility_level > 7000000 or
				(rc.type & ~@snapshot_bit) not in 
				(25, 40, 45, 50, 51, 52, 53, 54, 55, 56 ,57, 58, 60, 68, 69))
				order by rc.xact_seqno, rc.command_id asc
				OPTION (FAST 1)
		end
		-- PeerToPeer QUERY (with Snapshot Commands)
		else if @IsP2PAgent = 1
		begin
			select rc.xact_seqno, rc.partial_command, rc.type, 
				rc.command_id, rc.command, rc.hashkey,
				-- extra columns for the PeerToPeer resultset
				msro.id, msro.srvname, msro.dbname, msro.publication_id, msro.dbversion, rc.originator_lsn, rc.article_id
			from 
				MSrepl_commands rc with (INDEX(ucMSrepl_commands))
				join dbo.MSsubscriptions s with (INDEX(ucMSsubscriptions))
					on rc.article_id = s.article_id
				-- needed for PeerToPeer
				left join MSrepl_originators msro with (readpast, INDEX(ucMSrepl_originators))
					on msro.id = rc.originator_id           
				left join MScached_peer_lsns mscpl with (INDEX(ucMScached_peer_lsns))
					on 
					(
						mscpl.agent_id 							= s.agent_id
			   				and mscpl.originator 				= msro.srvname
							and mscpl.originator_db 			= msro.dbname
							and mscpl.originator_publication_id	= msro.publication_id
							and mscpl.originator_db_version		= msro.dbversion
 					)
			where
				s.agent_id = @agent_id and
				s.status = @active_status and
				s.publisher_database_id = @publisher_database_id and
				rc.publisher_database_id = @publisher_database_id and			
				rc.xact_seqno > @last_xact_seqno and
				rc.xact_seqno <= @max_xact_seqno and
				-- If log based transaction, we do
				-- 1. only select tran later than sub pub seqno
				-- 2. perform loop back detection for P2P and
				--    allow all 1073741868 cmds to be replicated
				(((rc.type & @snapshot_bit) <> @snapshot_bit and
				rc.xact_seqno > s.publisher_seqno and
				rc.xact_seqno > s.ss_cplt_seqno
				--
				-- Loopback detection
				--
				-- We send the command for 4 cases:
				-- 
				-- 1. We have the originator information and the lsn of the cmd is
				-- greater than the last one we saw for this originator.
				--
				-- 2. This is a snapshot command and the originator id is NULL. This 
				-- would mean that the command qualified via the left join and thus
				-- the originator_lsn must also be NULL. Note that the only time an
				-- originator_id is NULL in P2P should be for snapshot commands
				-- 
				-- 3. The originator_id of the command is not null, it is not the 
				-- subscriber originator_id (@originator_id) and the lsn is null. This
				-- is the case where the meta-data has not yet been inserted at the sub.
				--
				-- 4.If is a REPL_PEERTOPEERAUTOPROC (1073741868) command type. They  
			   	-- are always sent since we guarantee they only come from one source.
				-- also we must send these for the following case:
				-- 		2 Nodes A and B. DDL occurs on A and sends auto-proc to B
				--		Now B must send the procs back to A as a refresh even though
				--		the AutoProcs are marked as coming from A. The procs will
				--		Not be resent by this node because of @last_xact_seqno. This
				--		does mean however that it is possible that another node may
				--		resend. This is ok since the same definition will be used
				and ((not exists(select * from @peer_originator_ids where id = rc.originator_id)
						 and mscpl.originator_lsn < rc.originator_lsn)
					or (rc.originator_id is NULL
						and mscpl.originator_lsn is NULL)
					or (not exists(select * from @peer_originator_ids where id = rc.originator_id)
						and mscpl.originator_lsn is NULL)
					or rc.type = 1073741868))
				or 
				-- If snapshot transaction, we do
				-- 1. filter out the  snapshot transactions that were inserted later that is not
				-- the subscription's snapshot transaction
				-- 2. filter out trigger generation command for non synctran subscription.
				-- Note: don't do loop back detection.
				((rc.type & @snapshot_bit) = @snapshot_bit and 
				((rc.xact_seqno >= s.subscription_seqno and 
				  rc.xact_seqno <= s.ss_cplt_seqno) or 
				 (rc.xact_seqno in (select subscription_seqno from @snapshot_seqnos) and (rc.type & ~@snapshot_bit) in (25, 50, 51, 52, 53, 54, 55, 56 ,57, 58))) and -- Command type list must match that in sp_MSdrop_article
				(s.update_mode <> @read_only or rc.type <> @synctran_type)))
				-- here we do not require filtering out new commands since this should only
				-- be reached by agents with compatibility levels that are 9.0 or greater
			order by rc.xact_seqno, rc.command_id asc
			OPTION (FAST 1)
		end
		else -- this is loop back detection (NO PeerToPeer)
		begin
			-- Join with every thing with loop back
			select rc.xact_seqno, rc.partial_command, rc.type, 
				rc.command_id, rc.command, rc.hashkey,
				NULL, NULL, NULL, NULL, NULL, NULL, rc.article_id
				from 
					MSrepl_commands rc with (INDEX(ucMSrepl_commands))
					JOIN dbo.MSsubscriptions s with (INDEX(ucMSsubscriptions))
						-- At end, we use the FASTFIRSTROW option which tends to force
						-- a nested inner loop join driven from MSrepl_commands
						ON (rc.article_id = s.article_id AND rc.publisher_database_id=s.publisher_database_id )                
				where

				s.agent_id = @agent_id and
				s.status = @active_status and
				rc.publisher_database_id = @publisher_database_id and
				rc.xact_seqno > @last_xact_seqno and
				rc.xact_seqno <= @max_xact_seqno and
				-- If log based transaction, we do
				-- 1. only select tran later than sub pub seqno
				-- 2. loopback detection
				(((rc.type & @snapshot_bit) <> @snapshot_bit and
				rc.xact_seqno > s.publisher_seqno and
				rc.xact_seqno > s.ss_cplt_seqno and
				--
				-- Loopback detection
				--
				(s.loopback_detection = 0 or
					rc.originator_id <> @originator_id)) or 
				-- If snapshot transaction, we do
				-- 1. filter out the  snapshot transactions that were inserted later that is not
				-- the subscription's snapshot transaction
				-- 2. filter out trigger generation command for non synctran subscription.
				-- Note: don't do loop back detection.
				((rc.type & @snapshot_bit) = @snapshot_bit and 
				((rc.xact_seqno >= s.subscription_seqno and 
				  rc.xact_seqno <= s.ss_cplt_seqno) or 
				 (rc.xact_seqno in (select subscription_seqno from @snapshot_seqnos) and (rc.type & ~@snapshot_bit) in (25, 50, 51, 52, 53, 54, 55, 56 ,57, 58))) and -- Command type list must match that in sp_MSdrop_article
				(s.update_mode <> @read_only or rc.type <> @synctran_type))) and
				-- Filter out the new command types that we have introduced after 9.0
				(@compatibility_level >= 10000000 or
				(rc.type & ~@snapshot_bit & ~@postcmd_bit) not in 
				(105)) and
				-- Filter out the new command types that we have introduced after 8.0
				(@compatibility_level >= 9000000 or
				(rc.type & ~@snapshot_bit & ~@postcmd_bit) not in 
				(13, 86, 87, 88, 89, 90, 91, 92, 93, 94, 95, 96, 97, 98, 99, 31, 32, 33, 47, 100, 101, 102, 104)) and
				-- Filter out the new command types that we have introduced after 7.0
				(@compatibility_level > 7000000 or
				(rc.type & ~@snapshot_bit) not in 
				(25, 40, 45, 50, 51, 52, 53, 54, 55, 56 ,57, 58, 60, 68, 69))
				order by rc.xact_seqno, rc.command_id asc
				OPTION (FAST 1)
			end
	end
   	-- PeerToPeer QUERY (NO Snapshot Commands)
	else if @IsP2PAgent = 1
	begin
		select rc.xact_seqno, rc.partial_command, rc.type, 
			rc.command_id, rc.command, rc.hashkey, 
			--extra columns for the PeerToPeer resultset
			msro.id, msro.srvname, msro.dbname, msro.publication_id, msro.dbversion, rc.originator_lsn, rc.article_id
			from 
				MSrepl_commands rc with (nolock, INDEX(ucMSrepl_commands))
				join dbo.MSsubscriptions s with (INDEX(ucMSsubscriptions))
					on rc.article_id = s.article_id 
				-- needed for PeerToPeer
				left join MSrepl_originators msro with (readpast, INDEX(ucMSrepl_originators))
					on msro.id = rc.originator_id
				left join MScached_peer_lsns mscpl with (INDEX(ucMScached_peer_lsns))
					on 
					(
			   			mscpl.agent_id 							= s.agent_id
			   				and mscpl.originator 				= msro.srvname
							and mscpl.originator_db 			= msro.dbname
							and mscpl.originator_publication_id	= msro.publication_id
							and mscpl.originator_db_version		= msro.dbversion
					)
			where
				s.agent_id = @agent_id and
				s.publisher_database_id = @publisher_database_id and
				rc.publisher_database_id = @publisher_database_id and
				rc.xact_seqno > @last_xact_seqno and
				rc.xact_seqno <= @max_xact_seqno and
				(rc.type & @snapshot_bit) <> @snapshot_bit and
				(rc.type & ~@snapshot_bit) not in ( 37, 38 )
				--
				-- Loopback detection
				--
				-- We send the command for 4 cases:
				-- 
				-- 1. We have the originator information and the lsn of the cmd is
				-- greater than the last one we saw for this originator.
				--
				-- 2. This is a snapshot command and the originator id is NULL. This 
				-- would mean that the command qualified via the left join and thus
				-- the originator_lsn must also be NULL. Note that the only time an
				-- originator_id is NULL in P2P should be for snapshot commands
				-- 
				-- 3. The originator_id of the command is not null, it is not the 
				-- subscriber originator_id (@originator_id) and the lsn is null. This
				-- is the case where the meta-data has not yet been inserted at the sub.
				--
				-- 4.If is a REPL_PEERTOPEERAUTOPROC (1073741868) command type. They  
			   	-- are always sent since we guarantee they only come from one source.
				-- also we must send these for the following case:
				-- 		2 Nodes A and B. DDL occurs on A and sends auto-proc to B
				--		Now B must send the procs back to A as a refresh even though
				--		the AutoProcs are marked as coming from A. The procs will
				--		Not be resent by this node because of @last_xact_seqno. This
				--		does mean however that it is possible that another node may
				--		resend. This is ok since the same definition will be used
				and ((not exists(select * from @peer_originator_ids where id = rc.originator_id)
						 and mscpl.originator_lsn < rc.originator_lsn)
					or (rc.originator_id is NULL
						and mscpl.originator_lsn is NULL)
					or (not exists(select * from @peer_originator_ids where id = rc.originator_id)
						and mscpl.originator_lsn is NULL)
					or rc.type = 1073741868)
				-- here we do not require filtering out new commands since this should only
				-- be reached by agents with compatibility levels that are 9.0 or greater
			order by rc.xact_seqno, rc.command_id asc
			OPTION (FAST 1)
	end
	-- The agent has finished snapshot transactions but it has loopback detection.
	else if @num_loopback <> 0 and @originator_id <> 0
	begin
		-- Join plus loopback
		select rc.xact_seqno, rc.partial_command, rc.type,
			rc.command_id, rc.command, rc.hashkey,
			NULL, NULL, NULL, NULL, NULL, NULL, rc.article_id
			from                
				MSrepl_commands rc with (nolock, INDEX(ucMSrepl_commands))
				JOIN dbo.MSsubscriptions s with (INDEX(ucMSsubscriptions))
				-- At end, we use the FASTFIRSTROW option which tends to force
				-- a nested inner loop join driven from MSrepl_commands
				ON (rc.article_id = s.article_id)
			where

			s.agent_id = @agent_id and
			rc.publisher_database_id = @publisher_database_id and
			rc.xact_seqno > @last_xact_seqno and
			rc.xact_seqno <= @max_xact_seqno and
			(rc.type & @snapshot_bit) <> @snapshot_bit and
			(rc.type & ~@snapshot_bit) not in ( 37, 38 ) and
			--
			-- Loopback detection
			--
			(s.loopback_detection = 0 or
			rc.originator_id <> @originator_id) 
			and (@compatibility_level >= 9000000 
				or (rc.type & ~@postcmd_bit) not in (47))
		order by rc.xact_seqno, rc.command_id asc
		OPTION (FAST 1)
	end
	-- The agent has finished snapshot transactions. It has NO loopback detection.
	else 
	begin
		-- Mini join along. Only agent_id and article_id columns in dbo.MSsubscriptions
		-- are used. So only index pages are needed for the join.
		select rc.xact_seqno, rc.partial_command, rc.type, 
		rc.command_id, rc.command, rc.hashkey,
		-- extra columns for the PeerToPeer resultset
		-- originator_id, srvname, dbname, originator_publication_id, originator_db_version, originator_lsn
		NULL, NULL, NULL, NULL, NULL, NULL, rc.article_id
		from                
			MSrepl_commands rc with (nolock, INDEX(ucMSrepl_commands))
			JOIN dbo.MSsubscriptions s with (INDEX(ucMSsubscriptions))
			-- At end, we use the FASTFIRSTROW option which tends to force
			-- a nested inner loop join driven from MSrepl_commands
			ON (rc.article_id = s.article_id)
		where
		s.agent_id = @agent_id and
		rc.publisher_database_id = @publisher_database_id and
		rc.xact_seqno > @last_xact_seqno and
		rc.xact_seqno <= @max_xact_seqno and
		(rc.type & @snapshot_bit) <> @snapshot_bit and
		(rc.type & ~@snapshot_bit) not in ( 37, 38 )
		and (@compatibility_level >= 9000000 
				or (rc.type & ~@postcmd_bit) not in (47))
		order by rc.xact_seqno, rc.command_id asc
		OPTION (FAST 1)
	end

	-- Return the max seqno of this batch to distribution agent.
	select @max_xact_seqno, @@rowcount
end
GO
GRANT EXECUTE ON [sys].[sp_MSget_repl_commands] TO [public] AS [dbo]
GO
