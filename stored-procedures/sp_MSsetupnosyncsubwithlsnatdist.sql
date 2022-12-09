SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSsetupnosyncsubwithlsnatdist]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSsetupnosyncsubwithlsnatdist] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSsetupnosyncsubwithlsnatdist]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@article [sysname],
	@subscriber [sysname],
	@destination_db [sysname],
	@subscriptionlsn [binary](10),
	@lsnsource [tinyint],
	@originator_publication_id [int],
	@originator_db_version [int],
	@originator_meta_data [nvarchar](max),
	@nosync_setup_script [nvarchar](max),
	@next_valid_lsn [binary](10)
WITH EXECUTE AS CALLER
AS
begin 
	set nocount on
	declare @retcode int,            
			@publisherid int,
			@subscriberid int,
			@nosyncsnapshotseqno binary(16),
			@transactionopened bit,
			@acquiredapplicationlock bit,
			@lockresource nvarchar(255),
			@transactionentrytime datetime,
			@publisher_database_id int,
			@publication_id int,
			@hasbeforetransactions bit,
			@subscriptionlsntag bigint,
			@nosyncsubscriptionseqno varbinary(16),
			@active tinyint,
			@snapshot_bit int,
			@minartid int,
			@command_id int,
			@command nvarchar(512),
			@lsn_low binary(8),
			@lsn_high binary(2)
	
	-- Security check 
	if (isnull(is_srvrolemember('sysadmin'),0) = 0)
	begin
		raiserror(21089, 16, -1)
		return 1
	end

	-- Initializations
	select @retcode = 0,
		   @transactionopened = 0,
		   @acquiredapplicationlock = 0,
		   @lockresource = db_name() + N'_nosync',
		   @transactionentrytime = null,
		   @hasbeforetransactions = 0,
		   @subscriptionlsntag = null,
		   @active = 2,
		   @snapshot_bit = 0x80000000,
		   @minartid = null

	if @@error<>0 or @retcode <> 0 begin select @retcode = 1 goto Failure end

	exec sys.sp_MSget_server_portinfo 
		@name = @publisher, 
		@srvname = @publisher OUTPUT

	exec sys.sp_MSget_server_portinfo 
		@name = @subscriber, 
		@srvname = @subscriber OUTPUT

    -- Obtain Publisher's server id
    select @publisherid = srvid 
      from MSreplservers
     where upper(srvname) = upper(@publisher) collate database_default
    if @@error<>0 or @retcode <> 0 begin select @retcode = 1 goto Failure end

    -- Obtain Subscriber's server id
    select @subscriberid = srvid
      from MSreplservers
     where upper(srvname) = upper(@subscriber) collate database_default
    if @@error<>0 or @retcode <> 0 begin select @retcode = 1 goto Failure end
            
    -- Find out what the publisher database id is...
    select @publisher_database_id = id
      from dbo.MSpublisher_databases
     where publisher_db = @publisher_db
       and publisher_id = @publisherid
    if @@error<>0 or @retcode <> 0 begin select @retcode = 1 goto Failure end
    -- if @publisher_database_id cannot be populated, it means publication doesn't exists anymore and there is nothing to do here
    if @publisher_database_id is null return 0

	-- Obtain the publication id
	select @publication_id = publication_id
	  from dbo.MSpublications
	 where publisher_id = @publisherid
	   and publisher_db = @publisher_db
	   and publication = @publication
	if @@error<>0 or @retcode <> 0 begin select @retcode = 1 goto Failure end

	-- Obtain artid if this is for an incremental article
	if @article <> N'all'
	begin 
		select @minartid = article_id    
		  from MSarticles
		 where publisher_id = @publisherid
		   and publisher_db = @publisher_db 
		   and publication_id = @publication_id
		   and article = @article
	end
	if @minartid is null
	begin
		-- Obtain the min article id in the subscription for setting
		-- up snapshot commands in MSrepl_commands
		select @minartid = min(article_id)
		  from dbo.MSsubscriptions
		 where publisher_database_id = @publisher_database_id
		   and publisher_id = @publisherid
		   and publisher_db = @publisher_db
		   and publication_id = @publication_id
		   and subscriber_id = @subscriberid
		   and subscriber_db = @destination_db
		if @@error<>0 or @retcode<>0 begin select @retcode=1 goto Failure end
	end
	-- if @minartid cannot be populated, it means subscriber doesn't exists anymore and there is nothing to do here
	if @minartid is null return 0

	begin transaction
	save transaction sp_MSsetupnosyncsubwithlsnatdist
	if @@error<>0 or @retcode<>0 begin select @retcode=1 goto Failure end    
	select @transactionopened = 1

	-- 1) Acquire application lock to prevent interference from the 
	-- distribution cleanup job or a concurrent nosync subscription setup
	-- session.
	exec @retcode = sys.sp_getapplock @Resource = @lockresource, 
									  @LockMode = 'Exclusive', 
									  @LockOwner = 'Transaction',
									  @LockTimeout = 5000, -- Bail out if lock cannot be acquired in 5 seconds
									  @DbPrincipal = N'db_owner'
	if @@error<>0 begin select @retcode = 1 goto Failure end

	if @retcode = -1
	begin
		raiserror(21398, 16, -1)
		select @retcode = 1
		goto Failure
	end

	-- An error message would have been returned in other failure cases
	if @retcode < 0 begin select @retcode = 1 goto Failure end
	select @acquiredapplicationlock = 1, @retcode = 0

	-- Validate the given LSN, make sure that we don't lose any transactions.

	-- Lock both MSrepl_transactions (to prevent insertion of new 
	-- transactions) and dbo.MSsubscriptions (to prevent insertion of new
	-- subscriptions) Only consider non-snapshot transactions with xact_id<>0
	select @retcode = 0  from dbo.MSrepl_transactions with (TABLOCK HOLDLOCK) where 1 = 0
	if @@error<>0 or @retcode<>0 begin select @retcode=1 goto Failure end    
	select @retcode = 0  from dbo.MSsubscriptions with (TABLOCK HOLDLOCK) where 1 = 0
	if @@error<>0 or @retcode<>0 begin select @retcode=1 goto Failure end    

	select @hasbeforetransactions = 
	  case when exists (select * from dbo.MSrepl_transactions rt 
						inner join dbo.MSrepl_commands rc
						   on rt.xact_seqno = rc.xact_seqno -- Make sure that we have commands assoiciated with the transaction
						  and rt.publisher_database_id = rc.publisher_database_id
						 where rt.publisher_database_id = @publisher_database_id
						   and rt.xact_seqno < @subscriptionlsn
						   and rt.xact_id <> 0x000000000000) then 1
		   else 0
	  end -- case
	if @@error<>0 or @retcode<>0 begin select @retcode=1 goto Failure end    

	-- Transactions related to REPL_NOSYNC_SUBSCRIPTION_SETUP_LOG_CMD (54) type should not be included to resultset
	-- thus this query considers all transactions excluding ones which have command with type 54
	select top 1 @transactionentrytime = entry_time 
	  from MSrepl_transactions as rt left outer join MSrepl_commands rc
		on rt.xact_seqno = rc.xact_seqno and rt.publisher_database_id = rc.publisher_database_id
	 where rt.publisher_database_id = @publisher_database_id 
	   and rt.xact_seqno >= @subscriptionlsn 
	   and (rc.xact_seqno is null or (rc.type & 0xFFFFFFF) <> 54)
	   and rt.xact_id <> 0x000000000000 order by rt.xact_seqno asc
	if @@error<>0 or @retcode<>0 begin select @retcode=1 goto Failure end    

	-- If @hasbeforetransactions = 0 and @transactionentrytime is not null, 
	-- the given subscription LSN is probably too old, raise different
	-- error messages depending on the source of the lsn.

	-- Don't raise error for "old" 'replication support only' subscriptions
	if @hasbeforetransactions = 0 and @transactionentrytime is not null and @lsnsource <> 0 
	begin
		if @lsnsource = 2
		begin
			-- we need a new lsn to use ...
			
			--lets not join with MSrepl_commands table, it's possible for cleanup to have cleaned all commands but oldest tran should remain in MSrepl_transactions
			--if we take currentLSN in this case we'd miss any command which happend after peer_lsn (see VSTS# 85182)
			select @subscriptionlsn = min(rt.xact_seqno)
				from dbo.MSrepl_transactions rt
				  where rt.publisher_database_id = @publisher_database_id
					and rt.xact_id <> 0x000000000000

			if @subscriptionlsn is not null
			begin
				-- upper 16 bits
				select @lsn_low = convert(varbinary(8), SUBSTRING(@subscriptionlsn,3,8))
				-- lower 64 bits 
				select @lsn_high = convert(varbinary(2), SUBSTRING(@subscriptionlsn,1,2))
		
				select @lsn_low = cast(cast(@lsn_low as bigint) - 1 as binary(8))
			
				-- Check for underflow
				--  if the lower bits are -1, then we need to subtract from the high bits
				if (@lsn_low = 0xFFFFFFFFFFFFFFFF)
					select @lsn_high = cast(cast(@lsn_high as smallint) - 1 as binary(2))
			
				-- Concat the two LSNs
				select @subscriptionlsn = @lsn_high + @lsn_low
			end
			else
			begin
				select @subscriptionlsn = @next_valid_lsn
			end
		end
		else
		begin
			raiserror(21397, 16, -1)
		
			select @retcode = 1
			goto Failure
		end
	end
	
	--
	-- At this point, the given lsn is assumed to be valid, i.e. we will
	-- not lose any transactions if it is used as the publisher seqno
	-- of the susbcription. This actually encompasses the following
	-- three cases:
	--  i) There is no transaction for the specified publisher database 
	--     either because the logreader hasn't been run or there simply 
	--     aren't any replicated transactions at the Publisher. Note that
	--     the Publisher-side lsn validation logic is supposed to ensure that 
	--     all article objects in the publication are activated prior to 
	--     the given lsn. 
	--     (Addendum: For sync-with-backup support, the distribution
	--     cleanup logic has been modified to leave at least one transaction
	--     (snapshot or transaction) in MSrepl_transactions for each 
	--     publisher database although the commands associated with the 
	--     remaining transaction(s) may have been removed. This ensures that
	--     if there are not any transactions in MSrepl_transactions for
	--     a given publisher database, either the Logreader for the 
	--     publisher database has not been run yet or there has not been
	--     any replicated transactions from the publisher database.) 
	--  ii) There are existing transactions before the given lsn but there
	--      is no transaction following the given lsn.  
	--  iii) There are transactions before and after the subscription lsn.
	--

	--
	-- Choosing the right entry_time for the nosync "snapshot" transaction:
	-- In cases i) and ii) above, the current datetime will be used as the 
	-- entry time of the nosync "snapshot" transaction that we are about to 
	-- insert into MSrepl_transactions. Any further transactions that are 
	-- inserted by the logreader or other sources will have an entry time > 
	-- than the entry time of this nosync "snapshot" transaction including 
	-- those that are logically committed after the nosync lsn. It is, 
	-- however, possible that a transaction with an lsn less than the nosync 
	-- lsn will be inserted after the nosync "snapshot" transaction. The worse
	-- that can happen with this odd scenario is that the "nosync" snapshot
	-- transaction may be cleaned up before some of the (not needed) 
	-- regular transactions with smaller lsns which is totally harmless.  
	-- For case iii), the entry_time of the minimum transaction greater than
	-- or equal to the nosync lsn is used. This will preserve the 
	-- monotonicity of entry time wrt xact_seqno in MSrepl_transactions 
	--

	if @transactionentrytime is null
		select @transactionentrytime = getdate()

	-- Get a uniquefying tag for the nosync subscription seqno, 
	-- this is simply the max tag in MSrepl_transactions + 1
	select @subscriptionlsntag = 
			max(convert(binary(4), substring(xact_seqno,11,4))) + 1
	  from dbo.MSrepl_transactions
	 where substring(xact_seqno, 1, 10) = @subscriptionlsn 
	   -- Note: @publisher_database_id comes from an identity column in 
	   -- MSpublisher_databases so it is unique enough for our purpose here
	   and publisher_database_id = @publisher_database_id  
	   and xact_id = 0x000000000000

	if @@error<>0 or @retcode<>0 begin select @retcode=1 goto Failure end    
	
	-- Boundary condition, @subscriptionlsn is currently unused in 
	-- dbo.MSsubscriptions 
	if @subscriptionlsntag is null
		select @subscriptionlsntag = 1
	-- Insert the nosync "snapshot" transaction into MSrepl_transactions
	
	select @nosyncsubscriptionseqno = @subscriptionlsn + 
									  convert(binary(4), @subscriptionlsntag)
	if @@error<>0 or @retcode<>0 begin select @retcode=1 goto Failure end    

	insert dbo.MSrepl_transactions 
		(publisher_database_id, xact_id, xact_seqno, entry_time) 
	values 
		(@publisher_database_id, 0x000000000000, @nosyncsubscriptionseqno,
		 @transactionentrytime)
	if @@error<>0 or @retcode<>0 begin select @retcode=1 goto Failure end    

	-- Activate subscriptions in dbo.MSsubscriptions with @subscriptionlsn
	-- as the publisher_seqno and @nosyncsubscriptionseqno as the
	-- subscription_seqno & ss_cplt_seqno 
	update dbo.MSsubscriptions
	   set status = @active,
		   subscription_seqno = @nosyncsubscriptionseqno,
		   snapshot_seqno_flag = 1,
		   publisher_seqno = @subscriptionlsn,
		   ss_cplt_seqno = @nosyncsubscriptionseqno,
		   nosync_type = @lsnsource + 1
	 where publisher_database_id = @publisher_database_id
	   and publisher_id = @publisherid
	   and publisher_db = @publisher_db -- Extra insurance
	   and publication_id = @publication_id
	   and subscriber_id = @subscriberid
	   and subscriber_db = @destination_db
	   and (@article = N'all' or article_id = @minartid)
					
	if @@error<>0 or @retcode<>0 begin select @retcode=1 goto Failure end    
		
	-- Setup the snapshot commands in dbo.MSrepl_commands
	
	select @command_id = 1

	declare @current_nosync_script_offset bigint,
			@chunk_size bigint
	select @chunk_size = 512, -- Unicode characters
		   @current_nosync_script_offset = 1
	if @@error<>0 or @retcode<>0 begin select @retcode=1 goto Failure end    

	set @command = substring(@nosync_setup_script, @current_nosync_script_offset, @chunk_size)

	while len(@command) > 0
	begin
		insert dbo.MSrepl_commands 
			(publisher_database_id, xact_seqno, type, article_id, 
			 originator_id, command_id, partial_command, command)
		values
			(@publisher_database_id, @nosyncsubscriptionseqno, 
			@snapshot_bit | 104, @minartid, 0, @command_id, 1, 
			convert(varbinary(1024), @command))
		if @@error<>0 or @retcode<>0 begin select @retcode=1 goto Failure end
		set @command_id = @command_id + 1
		set @current_nosync_script_offset = @current_nosync_script_offset + @chunk_size
		set @command = substring(@nosync_setup_script, @current_nosync_script_offset, @chunk_size)
	end

	if @nosync_setup_script <> N''
	begin
			 -- insert an empty command to finish it    
		insert dbo.MSrepl_commands 
			(publisher_database_id, xact_seqno, type, article_id, 
			 originator_id, command_id, partial_command, command)
		values
			(@publisher_database_id, @nosyncsubscriptionseqno, 
			 @snapshot_bit | 104, @minartid, 0, @command_id, 0, 
			 convert(varbinary(1024), N''))
		if @@error<>0 or @retcode<>0 begin select @retcode=1 goto Failure end
	end
	-- add the sql_cmds for p2p meta-data outside of the snapshot
	if @originator_publication_id is not NULL
		and @originator_db_version is not NULL
		and isnull(ltrim(@originator_meta_data), N'') <> N''
	begin
		-- when posting the nvarchar(max) for p2p meta-data we have to 
		-- make sure that we break it up into varbinary(1024) pieces...
		declare @originator_id	int,
				@xact_seqno		varbinary(16),
				@originator_lsn	varbinary(16),
				@index			bigint
				
		-- check if the originator already exists. if so then use the id
		-- if not then we insert the originator into msrepl_originators
		select @originator_id = id 
			from MSrepl_originators with (readpast)
			where publisher_database_id = @publisher_database_id 
				and UPPER(srvname) = UPPER(@publisher)
				and dbname = @publisher_db
				and publication_id = @originator_publication_id
				and dbversion = @originator_db_version
		if @originator_id is null
		begin
			insert into MSrepl_originators (publisher_database_id, srvname, dbname, publication_id, dbversion) 
				values (@publisher_database_id, UPPER(@publisher), @publisher_db, @originator_publication_id, @originator_db_version)
				
			select @originator_id = @@identity
		end

		-- here we increase the lsn we used for the snapshot by 1 
		select @xact_seqno 		= substring(@nosyncsubscriptionseqno, 1, 10) + convert(varbinary(4), substring(@nosyncsubscriptionseqno, 11, 4) + 1 ),
				@originator_lsn	= substring(@nosyncsubscriptionseqno, 1, 10), -- + convert(varbinary(4), substring(@nosyncsubscriptionseqno, 11, 4) + 1 ),
				@index 			= 1,
				@command 		= substring(@originator_meta_data, @index, 512),
				@command_id 	= 1 

 		-- insert the transaction information first
		insert dbo.MSrepl_transactions (publisher_database_id, xact_id, xact_seqno, entry_time) 
			values (@publisher_database_id, 0x000000000000, @xact_seqno, @transactionentrytime)
		if @@error<>0 or @retcode<>0 begin select @retcode=1 goto Failure end  

		-- now insert the actual commands
		while len(@command) > 0 
		begin
			insert dbo.MSrepl_commands 
				(publisher_database_id, xact_seqno, type, article_id, 
				 originator_id, command_id, partial_command, command,
				 originator_lsn)
			values
				(@publisher_database_id, @xact_seqno, 
				 1, @minartid, @originator_id, @command_id, 1, 
				 convert(varbinary(1024), @command),
				 @originator_lsn)
			if @@error<>0 or @retcode<>0 begin select @retcode=1 goto Failure end

			select @command_id 	= @command_id + 1,
			   		@index 		= @index + len(@command),
					@command 	= substring(@originator_meta_data, @index, 512)
			if @@error<>0 or @retcode<>0 begin select @retcode=1 goto Failure end
		end

		-- insert an empty command to finish it
		insert dbo.MSrepl_commands 
				(publisher_database_id, xact_seqno, type, article_id, 
				 originator_id, command_id, partial_command, command,
				 originator_lsn)
			values
				(@publisher_database_id, @xact_seqno, 
				 1, @minartid, @originator_id, @command_id, 0, 
				 convert(varbinary(1024), N''),
				 @originator_lsn)
	   	if @@error<>0 or @retcode<>0 begin select @retcode=1 goto Failure end
	end
	
	-- Release application lock
	exec @retcode = sys.sp_releaseapplock @Resource = @lockresource, 
										  @LockOwner = 'Transaction',
										  @DbPrincipal = N'db_owner'
	if @@error<>0 or @retcode<>0 begin select @retcode=1 goto Failure end    
	select @acquiredapplicationlock = 0

	commit transaction
	if @@error<>0 or @retcode<>0 begin select @retcode=1 goto Failure end    
	select @transactionopened = 0

Failure:

	if @acquiredapplicationlock = 1
	begin
		-- Ignore errors, nothing can be done at this point if the following
		-- fails
		exec sys.sp_releaseapplock @Resource = @lockresource, 
								   @LockOwner = 'Transaction',
								   @DbPrincipal = N'db_owner' 
	end

	if @transactionopened = 1
	begin
		rollback transaction sp_MSsetupnosyncsubwithlsnatdist
		commit transaction
	end 

	return @retcode
end
GO
GRANT EXECUTE ON [sys].[sp_MSsetupnosyncsubwithlsnatdist] TO [public] AS [dbo]
GO
