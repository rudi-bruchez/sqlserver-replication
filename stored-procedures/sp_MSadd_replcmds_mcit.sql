SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSadd_replcmds_mcit]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSadd_replcmds_mcit] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSadd_replcmds_mcit]
	@publisher_database_id [int],
	@publisher_id [smallint],
	@publisher_db [sysname],
	@data [varbinary](1595),
	@1data [varbinary](1595),
	@2data [varbinary](1595),
	@3data [varbinary](1595),
	@4data [varbinary](1595),
	@5data [varbinary](1595),
	@6data [varbinary](1595),
	@7data [varbinary](1595),
	@8data [varbinary](1595),
	@9data [varbinary](1595),
	@10data [varbinary](1595),
	@11data [varbinary](1595),
	@12data [varbinary](1595),
	@13data [varbinary](1595),
	@14data [varbinary](1595),
	@15data [varbinary](1595),
	@16data [varbinary](1595),
	@17data [varbinary](1595),
	@18data [varbinary](1595),
	@19data [varbinary](1595),
	@20data [varbinary](1595),
	@21data [varbinary](1595),
	@22data [varbinary](1595),
	@23data [varbinary](1595),
	@24data [varbinary](1595),
	@25data [varbinary](1595),
	@26data [varbinary](1595)
WITH EXECUTE AS CALLER
AS
SET NOCOUNT ON

	DECLARE @maxOffset  binary(4)
			,@maxSeqNo  varbinary(16)
			,@date datetime
			,@x int
			,@tempdata varbinary(1595)
			,@prevdata varbinary(1595)

	DECLARE @xactId			varbinary(16),
			@xactSeqNo		varbinary(16),
			@artId			int,
			@cmdId			int,
			@cmdType		int,
			@fIncomplete	bit,
			@cmdLen			int,
			@originator_id	int,
			@origSrvLen		int,
			@origDbLen		int,
			@hashKey		int,
			-- @origPublId		int,
			-- @origDbVersion	int,
			-- @origLSN		varbinary(10),
			@cmdText		varbinary(1595),
			@originator		sysname,
			@originatorDb	sysname,
			@originalXactSeqNo varbinary(10)

	--
    -- security check
    -- only db_owner can execute this
    --
    if (is_member ('db_owner') != 1) 
    begin
        raiserror(14260, 16, -1)
        return (1)
    end
	-- @publisher_id is always from master..sysservers, so we need to fetch from MSreplservers
	select @publisher_id = sys.fn_MSrepl_getsrvidfromdistdb(@publisher_id)

	select @date 		= GETDATE(),
			@maxOffset 	= 0,
			@xactSeqNo 	= substring( @data, 11, 10 ),
			@cmdId		= substring( @data, 25, 4)

	select @originalXactSeqNo = @xactSeqNo

	-- Look for the first insert into MS_repl_transactions
   	select @maxSeqNo = max(xact_seqno) 
   		from MSrepl_transactions 
		where publisher_database_id = @publisher_database_id 

	-- hotfix#844587, if the current xactSeqNo is less than the maxSeqNo,
	-- it could be snapshot agent inserts records while the splitting on going.
	-- So we need to find the our own xact_seqno.
	-- 
	if @xactSeqNo < substring( @maxSeqNo, 1, 10 )
	begin
		-- find the largest xact_seqno for the MaxCmdsInTran LSN
		select @maxSeqNo = max(xact_seqno) 
			from MSrepl_transactions 
			where publisher_database_id = @publisher_database_id 
			and xact_seqno >= @xactSeqNo
			and substring( xact_seqno, 1, 10 ) = @xactSeqNo
	end

	 -- Check if it is the same transaction
	if @xactSeqNo = substring( @maxSeqNo, 1, 10 )
	begin
		IF @cmdId = 1 
			select @maxOffset = substring(@maxSeqNo, 11, 4) + 1
		else
			select @maxOffset = substring(@maxSeqNo, 11, 4)
			
		if (@maxOffset > 0)
			select @xactSeqNo = @xactSeqNo + @maxOffset
	end

	if @maxOffset is NULL
		select @maxOffset = 0
		
	select @maxOffset = @maxOffset + 1

	select @x = 0
	select @tempdata = @data
	while @x <= 26
	begin
		select @prevdata = @tempdata	
		select @tempdata = CASE @x
			when 0 then @data
			when 1 then @1data
			when 2 then @2data
			when 3 then @3data
			when 4 then @4data
			when 5 then @5data
			when 6 then @6data
			when 7 then @7data
			when 8 then @8data
			when 9 then @9data
			when 10 then @10data
			when 11 then @11data
			when 12 then @12data
			when 13 then @13data
			when 14 then @14data
			when 15 then @15data
			when 16 then @16data
			when 17 then @17data
			when 18 then @18data
			when 19 then @19data
			when 20 then @20data
			when 21 then @21data
			when 22 then @22data
			when 23 then @23data
			when 24 then @24data
			when 25 then @25data
			when 26 then @26data
		end
		
		IF @tempdata is null
	  		goto END_CMDS

		-- We will now breakup the binary data. Check HP_FIXED_DATA 
		-- in publish.cpp for all of the offsets listed below...
		select @xactId 			= substring( @tempdata, 1, 10),
				-- @xactSeqNo   = see directly below for the setting of this value : usually = substring( @tempdata, 11, 10),
				@artId			= substring( @tempdata, 21, 4),
				@cmdId			= substring( @tempdata, 25, 4),
				@cmdType		= substring( @tempdata, 29, 4),
				@fIncomplete	= convert(bit, substring( @tempdata, 33, 1)),
				@cmdLen			= substring( @tempdata, 34, 2),
				@origSrvLen		= substring( @tempdata, 36, 2),
				@origDbLen		= substring( @tempdata, 38, 2),
				@hashKey		= substring( @tempdata, 40, 2),
				-- @origPublId		= Not used since MaxCMDsInTran is not supported in PeerToPeer. Usually would be : substring( @tempdata, 42, 4),
				-- @origDbVersion	= Not used since MaxCMDsInTran is not supported in PeerToPeer. Usually would be : substring( @tempdata, 46, 4),
				-- @origLSN			= Not used since MaxCMDsInTran is not supported in PeerToPeer. Usually would be : substring( @tempdata, 50, 10),
				@cmdText		= substring( @tempdata, 60, @cmdLen)
				-- @originator  = only done below if an originator len is detected : usually = substring( @tempdata, 60 + @cmdLen, @origSrvLen)
				-- @originatorDb= only done below if an originator len is detected : usually = substring( @tempdata, 60 + @cmdLen + @origSrvLen, @origDbLen)
			
		if @x != 0
		begin
			if(substring( @tempdata, 11, 10 ) = substring( @prevdata, 11, 10 )) --same tran
			begin
				IF @cmdId = 1
				begin
					select @xactSeqNo = substring( @tempdata, 11, 10 ) + @maxOffset
					select @maxOffset  = @maxOffset + 1
				end
			end
			else
				select @xactSeqNo = substring( @tempdata, 11, 10 ) 
		end

		-- first command in tran
		IF @cmdId = 1  
		begin
			INSERT INTO MSrepl_transactions 
				VALUES (@publisher_database_id, @xactId, @xactSeqNo, @date)
		end

		-- Now insert into MSrepl_commands
		if( @cmdType in( 37,38 ) )
		begin
			select @cmdType = 38 - @cmdType
			exec sp_MSset_syncstate @publisher_id, @publisher_db, @artId, @cmdType, @xactSeqNo
			select @cmdType = (38 - @cmdType) | 0x80000000
		end
		-- Check all posted cmds of SQLCMD type to see if they are tracer records
		-- sql cmd type is (47 | 0x40000000 ) or 1073741871
		else if @cmdType = 1073741871
		begin
			declare @tracer_id 	int,
					@retcode	int
			
			select @tracer_id = cast(cast(@cmdText as nvarchar) as int)

			exec @retcode = sys.sp_MSupdate_tracer_history @tracer_id = @tracer_id
			if @retcode <> 0 or @@error <> 0
				return 1
		end
		
		-- only add it if the command is not empty
	   	if @cmdLen > 0
		begin
			--handle nonsync subscription setup when command type is 
			-- REPL_NOSYNC_SUBSCRIPTION_SETUP_LOG_CMD (54)
			if ((@cmdType & 0xFFFFFFF) = 54)
			begin
				-- When logreader gets a log record with this type,
				-- the MSnosyncsubsetup table should already exist,
				-- report the failure if it does not exist.
				if (object_id(N'dbo.MSnosyncsubsetup', 'U')) is NULL 
				begin
					goto Failure
				end
				else
				begin
					declare @nosyncCommandStr	nvarchar(max),
						@publisher				sysname,
						@publication				sysname,
						@article					sysname,
						@subscriber 			sysname,
						@destination_db 		sysname,
						@subscriptionlsn			binary(10),
						@lsnsource				tinyint,
						@originator_publication_id	int,
						@originator_db_version		int,
						@originator_meta_data		nvarchar(max),
						@nosync_setup_script		nvarchar(max),
						@next_valid_lsn 		binary(10),
						@next_valid_lsn_from_log	binary(10)
			
					-- if most high bit is set to 1 then interprete buffer as a new format 99 <= 0xFFFFFF9D (supports 2^32 ids), otherwise it's a backward compatibility for 99 <= 0x39003900 (this is max id)
					select @originator_publication_id = CASE WHEN CAST(substring(@cmdText, 1, 4) AS int) <= 0 THEN -CAST(substring(@cmdText, 1, 4) AS int) ELSE CAST(CAST(substring(@cmdText, 1, 4) AS nvarchar) AS int) END,
						@next_valid_lsn_from_log = CAST(substring(@cmdText, 5, 10) AS binary(10))
					if @@error <> 0 goto Failure
			
					-- Verify that the number of parameters is correct before using 
					-- these parameters in sp_MSsetupnosyncsubwithlsnatdist
					if ((select count(*) from dbo.MSnosyncsubsetup
						where publisher_database_id = @publisher_database_id
						and publication_id = @originator_publication_id
						and artid = @artId
						and next_valid_lsn = @next_valid_lsn_from_log) <> 13) goto Failure
					if @@error <> 0 goto Failure
			
					select @publisher = cast((select parameterValue 
									from dbo.MSnosyncsubsetup
									where publisher_database_id = @publisher_database_id
										and publication_id = @originator_publication_id
										and artid = @artId
										and next_valid_lsn = @next_valid_lsn_from_log
										and parameterName = N'publisher') as sysname),
					@publisher_db = cast((select parameterValue 
									from dbo.MSnosyncsubsetup
									where publisher_database_id = @publisher_database_id
										and publication_id = @originator_publication_id
										and artid = @artId
										and next_valid_lsn = @next_valid_lsn_from_log
										and parameterName = N'publisher_db') as sysname),
					@publication = cast((select parameterValue 
									from dbo.MSnosyncsubsetup
									where publisher_database_id = @publisher_database_id
										and publication_id = @originator_publication_id
										and artid = @artId
										and next_valid_lsn = @next_valid_lsn_from_log
										and parameterName = N'publication') as sysname),
					@article = cast((select parameterValue 
									from dbo.MSnosyncsubsetup
									where publisher_database_id = @publisher_database_id
										and publication_id = @originator_publication_id
										and artid = @artId
										and next_valid_lsn = @next_valid_lsn_from_log
										and parameterName = N'article') as sysname),
					@subscriber = cast((select parameterValue 
									from dbo.MSnosyncsubsetup
									where publisher_database_id = @publisher_database_id
										and publication_id = @originator_publication_id
										and artid = @artId
										and next_valid_lsn = @next_valid_lsn_from_log
										and parameterName = N'subscriber') as sysname),
					@destination_db = cast((select parameterValue 
										from dbo.MSnosyncsubsetup
										where publisher_database_id = @publisher_database_id
											and publication_id = @originator_publication_id
											and artid = @artId
											and next_valid_lsn = @next_valid_lsn_from_log
											and parameterName = N'destination_db') as sysname),
					@subscriptionlsn = cast((select parameterValue 
										from dbo.MSnosyncsubsetup
										where publisher_database_id = @publisher_database_id
											and publication_id = @originator_publication_id
											and artid = @artId
											and next_valid_lsn = @next_valid_lsn_from_log
											and parameterName = N'subscriptionlsn') as binary(10)),
					@lsnsource = cast((select parameterValue 
									from dbo.MSnosyncsubsetup
									where publisher_database_id = @publisher_database_id
										and publication_id = @originator_publication_id
										and artid = @artId
										and next_valid_lsn = @next_valid_lsn_from_log
										and parameterName = N'lsnsource') as tinyint),
					@originator_publication_id = cast((select parameterValue 
												from dbo.MSnosyncsubsetup
												where publisher_database_id = @publisher_database_id
													and publication_id = @originator_publication_id
													and artid = @artId
													and next_valid_lsn = @next_valid_lsn_from_log
													and parameterName = N'originator_publication_id') as int),
					@originator_db_version = cast((select parameterValue 
											from dbo.MSnosyncsubsetup
											where publisher_database_id = @publisher_database_id
												and publication_id = @originator_publication_id
												and artid = @artId
												and next_valid_lsn = @next_valid_lsn_from_log
												and parameterName = N'originator_db_version') as int),
					@originator_meta_data = (select parameterValue 
											from dbo.MSnosyncsubsetup
											where publisher_database_id = @publisher_database_id
												and publication_id = @originator_publication_id
												and artid = @artId
												and next_valid_lsn = @next_valid_lsn_from_log
												and parameterName = N'originator_meta_data'),
					@nosync_setup_script = (select parameterValue 
											from dbo.MSnosyncsubsetup
											where publisher_database_id = @publisher_database_id
												and publication_id = @originator_publication_id
												and artid = @artId
												and next_valid_lsn = @next_valid_lsn_from_log
												and parameterName = N'nosync_setup_script'),
					@next_valid_lsn = cast((select parameterValue 
										from dbo.MSnosyncsubsetup
										where publisher_database_id = @publisher_database_id
											and publication_id = @originator_publication_id
											and artid = @artId
											and next_valid_lsn = @next_valid_lsn_from_log
											and parameterName = N'next_valid_lsn') as binary(10))
					if @@error <> 0 goto Failure
			
					select @nosyncCommandStr = N'exec sp_MSsetupnosyncsubwithlsnatdist 
						@publisher = @publisher,
						@publisher_db = @publisher_db,
						@publication = @publication,
						@article = @article,
						@subscriber = @subscriber,
						@destination_db = @destination_db,
						@subscriptionlsn = @subscriptionlsn,
						@lsnsource = @lsnsource,
						@originator_publication_id = @originator_publication_id,
						@originator_db_version = @originator_db_version,
						@originator_meta_data = @originator_meta_data,
						@nosync_setup_script = @nosync_setup_script,
						@next_valid_lsn = @next_valid_lsn'
			
					exec sp_executesql
						@stmt = @nosyncCommandStr,
						@params = N'@publisher				sysname,
									@publisher_db			sysname,
									@publication				sysname,
									@article					sysname,
									@subscriber 			sysname,
									@destination_db 		sysname,
									@subscriptionlsn			binary(10),
									@lsnsource				tinyint,
									@originator_publication_id	int,
									@originator_db_version		int,
									@originator_meta_data		nvarchar(max),
									@nosync_setup_script		nvarchar(max),
									@next_valid_lsn 		binary(10)',
						@publisher = @publisher,
						@publisher_db = @publisher_db,
						@publication = @publication,
						@article = @article,
						@subscriber = @subscriber,
						@destination_db = @destination_db,
						@subscriptionlsn = @subscriptionlsn,
						@lsnsource = @lsnsource,
						@originator_publication_id = @originator_publication_id,
						@originator_db_version = @originator_db_version,
						@originator_meta_data = @originator_meta_data,
						@nosync_setup_script = @nosync_setup_script,
						@next_valid_lsn = @next_valid_lsn
			
					if @@error <> 0 goto Failure
			
				end --end of if (object_id(N'dbo.MSnosyncsubsetup, 'U')) is NOT NULL
			
				-- Upon success of the execution of sp_MSsetupnosyncsubwithlsnatdist,
				-- clean up the MSnosyncsubsetup table by deleting the parameters
				-- regarding this specified nonsync subscription
				delete dbo.MSnosyncsubsetup 
				where publisher_database_id = @publisher_database_id
				  and publication_id = @originator_publication_id
				  and artid = @artId
				  and next_valid_lsn = @next_valid_lsn_from_log
			
				if @@error <> 0 goto Failure
			
				goto Continue_next_command
Failure:
				return 1
Continue_next_command:
			end
				else   --i.e., when (@cmdType & 0xFFFFFFF) is NOT 54
					begin
			-- Get the originator_id for the first command
			if @origSrvLen <> 0 and @origDbLen <> 0 
			begin 
				select @originator_id 	= null,
		   				@originator		= substring( @tempdata, 60 + @cmdLen, @origSrvLen),
						@originatorDb	= substring( @tempdata, 60 + @cmdLen + @origSrvLen, @origDbLen)
				
				select @originator_id = id 
					from MSrepl_originators 
					where publisher_database_id = @publisher_database_id 
						and UPPER(srvname) = UPPER(@originator)
						and dbname = @originatorDb
						and publication_id is NULL		-- @origPublId
						and dbversion is NULL			-- @origDbVersion

				if @originator_id is null
				begin
					insert into MSrepl_originators (publisher_database_id, srvname, dbname, publication_id, dbversion) 
						values (@publisher_database_id, UPPER(@originator), @originatorDb, NULL, NULL)

					select @originator_id = @@identity
				end
			end
			else
				select @originator_id = 0
		
			INSERT INTO MSrepl_commands 
			(
				publisher_database_id, 
				xact_seqno, 
				type, 
				article_id, 
				originator_id, 
				command_id, 
				partial_command, 
				hashkey,
				originator_lsn,
				command
			)
			VALUES 
			(
				@publisher_database_id,
				@xactSeqNo,
				@cmdType,
				@artId, 					
				@originator_id,
				@cmdId,
				@fIncomplete,
				@hashKey,					
				NULL,		-- @origLSN
				@cmdText
			)
		end    --end of i.e., when (@cmdType & 0xFFFFFFF)  in (54, 55, 56)
		end    --end of if @cmdLen > 0

		select @x = @x + 1

	end

END_CMDS:
	IF @@ERROR <> 0
		return (1)
GO
GRANT EXECUTE ON [sys].[sp_MSadd_replcmds_mcit] TO [public] AS [dbo]
GO
