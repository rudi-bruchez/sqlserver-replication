SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSadd_repl_commands27hp]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSadd_repl_commands27hp] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSadd_repl_commands27hp]
	@publisher_id [smallint],
	@publisher_db [sysname],
	@data [varbinary](1575),
	@1data [varbinary](1575),
	@2data [varbinary](1575),
	@3data [varbinary](1575),
	@4data [varbinary](1575),
	@5data [varbinary](1575),
	@6data [varbinary](1575),
	@7data [varbinary](1575),
	@8data [varbinary](1575),
	@9data [varbinary](1575),
	@10data [varbinary](1575),
	@11data [varbinary](1575),
	@12data [varbinary](1575),
	@13data [varbinary](1575),
	@14data [varbinary](1575),
	@15data [varbinary](1575),
	@16data [varbinary](1575),
	@17data [varbinary](1575),
	@18data [varbinary](1575),
	@19data [varbinary](1575),
	@20data [varbinary](1575),
	@21data [varbinary](1575),
	@22data [varbinary](1575),
	@23data [varbinary](1575),
	@24data [varbinary](1575),
	@25data [varbinary](1575),
	@26data [varbinary](1575)
WITH EXECUTE AS CALLER
AS
begin
	SET NOCOUNT ON

	DECLARE @xact_id    varbinary(10)
	DECLARE @xact_seqno varbinary(10)
	DECLARE @artid      int
	DECLARE @command_id int
	DECLARE @cmd_type   int
	DECLARE @partial_command bit
	DECLARE @command    varbinary(1024)

	DECLARE @max_offset  binary(4)
	DECLARE @seqno  varbinary(16)
	DECLARE @1seqno  varbinary(16)
	DECLARE @2seqno  varbinary(16)
	DECLARE @3seqno  varbinary(16)
	DECLARE @4seqno  varbinary(16)
	DECLARE @5seqno  varbinary(16)
	DECLARE @6seqno  varbinary(16)
	DECLARE @7seqno  varbinary(16)
	DECLARE @8seqno  varbinary(16)
	DECLARE @9seqno  varbinary(16)
	DECLARE @10seqno  varbinary(16)
	DECLARE @11seqno  varbinary(16)
	DECLARE @12seqno  varbinary(16)
	DECLARE @13seqno  varbinary(16)
	DECLARE @14seqno  varbinary(16)
	DECLARE @15seqno  varbinary(16)
	DECLARE @16seqno  varbinary(16)
	DECLARE @17seqno  varbinary(16)
	DECLARE @18seqno  varbinary(16)
	DECLARE @19seqno  varbinary(16)
	DECLARE @20seqno  varbinary(16)
	DECLARE @21seqno  varbinary(16)
	DECLARE @22seqno  varbinary(16)
	DECLARE @23seqno  varbinary(16)
	DECLARE @24seqno  varbinary(16)
	DECLARE @25seqno  varbinary(16)
	DECLARE @26seqno  varbinary(16)
	DECLARE @max_seqno  varbinary(16)

	DECLARE @originator sysname
	DECLARE @originator_db sysname

	DECLARE @publisher_database_id int
	DECLARE @date datetime
	declare @originator_id int

	DECLARE @cmd_data_len  smallint
	DECLARE @orig_srv_len smallint
	DECLARE @orig_db_len  smallint
	DECLARE @MaxCmdsInTranOn int

	--
	-- security check
	-- only db_owner can execute this
	--
	if (is_member ('db_owner') != 1) 
	begin
		raiserror(14260, 16, -1)
		return (1)
	end

	SELECT @date = GETDATE()
	SELECT @MaxCmdsInTranOn = 0
	-- Get publisher database id.
	SELECT @publisher_database_id = id from MSpublisher_databases where publisher_id = @publisher_id and 
		publisher_db = @publisher_db
	
	SELECT @MaxCmdsInTranOn = category & 0x40 from master.dbo.sysdatabases where dbid = db_id()

	select @max_offset = 0
	-- First insert into MS_repl_transactions
	if(@MaxCmdsInTranOn > 0 )
	begin
		select @max_seqno = max(xact_seqno) from MSrepl_transactions 
				where publisher_database_id = @publisher_database_id 
		if substring( @data, 11, 10 ) = substring( @max_seqno, 1, 10 ) -- same tran
		begin
			IF convert( int, substring( @data, 25, 4 ) ) = 1 
				select @max_offset = substring(@max_seqno, 11, 4) + 1 -- increment offset
			else
				select @max_offset = substring(@max_seqno, 11, 4) -- keep the same offset
			if (@max_offset > 0)
				select @seqno = substring( @data, 11, 10 ) + @max_offset
			else
				select @seqno = substring( @data, 11, 10 )
		end
		else
			select @seqno = substring( @data, 11, 10 )
	end
	else
		select @seqno = substring( @data, 11, 10 )
	IF convert( int, substring( @data, 25, 4 ) ) = 1  --first command in tran
		INSERT INTO MSrepl_transactions VALUES (@publisher_database_id,
				 substring( @data, 1, 10 ), @seqno, @date)

	if @max_offset is NULL
		select @max_offset  = 0
	select @max_offset  = @max_offset + 1

	IF @1data is null
	  goto INSERT_CMDS

	if(substring( @1data, 11, 10 ) = substring( @data, 11, 10 )) --same tran
	begin
		IF convert( int, substring( @1data, 25, 4 ) ) = 1  --only happens with -MaxCmdsInTran 
		begin
			select @1seqno = substring( @1data, 11, 10 ) + @max_offset
			INSERT INTO MSrepl_transactions VALUES (@publisher_database_id,
				 substring( @1data, 1, 10 ), @1seqno, @date)
			select @max_offset  = @max_offset + 1
		end
		else
			select @1seqno = @seqno 
	end
	else
	begin
		select @1seqno = substring( @1data, 11, 10 ) 
		IF convert( int, substring( @1data, 25, 4 ) ) = 1  
			INSERT INTO MSrepl_transactions VALUES (@publisher_database_id,
				 substring( @1data, 1, 10 ), @1seqno, @date)
	end

	IF @2data is null
	  goto INSERT_CMDS

	if(substring( @2data, 11, 10 ) = substring( @1data, 11, 10 )) --same tran
	begin
		IF convert( int, substring( @2data, 25, 4 ) ) = 1  --only happens with -MaxCmdsInTran 
		begin
			select @2seqno = substring( @2data, 11, 10 )+ @max_offset
			INSERT INTO MSrepl_transactions VALUES (@publisher_database_id,
				 substring( @2data, 1, 10 ), @2seqno, @date)
			select @max_offset  = @max_offset + 1
		end
		else
			select @2seqno = @1seqno 
	end
	else
	begin
		select @2seqno = substring( @2data, 11, 10 ) 
		IF convert( int, substring( @2data, 25, 4 ) ) = 1  
			INSERT INTO MSrepl_transactions VALUES (@publisher_database_id,
				 substring( @2data, 1, 10 ), @2seqno, @date)
	end
	
	IF @3data is null
	  goto INSERT_CMDS

	if(substring( @3data, 11, 10 ) = substring( @2data, 11, 10 )) --same tran
	begin
		IF convert( int, substring( @3data, 25, 4 ) ) = 1  --only happens with -MaxCmdsInTran 
		begin
			select @3seqno = substring( @3data, 11, 10 ) + @max_offset 
			INSERT INTO MSrepl_transactions VALUES (@publisher_database_id,
				 substring( @3data, 1, 10 ), @3seqno, @date)
			select @max_offset  = @max_offset + 1
		end
		else
			select @3seqno = @2seqno 
	end
	else
	begin
		select @3seqno = substring( @3data, 11, 10 ) 
		IF convert( int, substring( @3data, 25, 4 ) ) = 1  
			INSERT INTO MSrepl_transactions VALUES (@publisher_database_id,
				 substring( @3data, 1, 10 ), @3seqno, @date)
	end

	IF @4data is null
	  goto INSERT_CMDS

	if(substring( @4data, 11, 10 ) = substring( @3data, 11, 10 )) --same tran
	begin
		IF convert( int, substring( @4data, 25, 4 ) ) = 1  --only happens with -MaxCmdsInTran 
		begin
			select @4seqno = substring( @4data, 11, 10 ) + @max_offset
			INSERT INTO MSrepl_transactions VALUES (@publisher_database_id,
				 substring( @4data, 1, 10 ), @4seqno, @date)
			select @max_offset  = @max_offset + 1
		end
		else
			select @4seqno = @3seqno 
	end
	else
	begin
		select @4seqno = substring( @4data, 11, 10 ) 
		IF convert( int, substring( @4data, 25, 4 ) ) = 1  
			INSERT INTO MSrepl_transactions VALUES (@publisher_database_id,
				 substring( @4data, 1, 10 ), @4seqno, @date)
	end

	IF @5data is null
	  goto INSERT_CMDS
	if(substring( @5data, 11, 10 ) = substring( @4data, 11, 10 )) --same tran
	begin
		IF convert( int, substring( @5data, 25, 4 ) ) = 1  --only happens with -MaxCmdsInTran 
		begin
			select @5seqno = substring( @5data, 11, 10 ) + @max_offset
			INSERT INTO MSrepl_transactions VALUES (@publisher_database_id,
				 substring( @5data, 1, 10 ), @5seqno, @date)
			select @max_offset  = @max_offset + 1
		end
		else
			select @5seqno = @4seqno 
	end
	else
	begin
		select @5seqno = substring( @5data, 11, 10 ) 
		IF convert( int, substring( @5data, 25, 4 ) ) = 1  
			INSERT INTO MSrepl_transactions VALUES (@publisher_database_id,
				 substring( @5data, 1, 10 ), @5seqno, @date)
	end

	IF @6data is null
	  goto INSERT_CMDS
	if(substring( @6data, 11, 10 ) = substring( @5data, 11, 10 )) --same tran
	begin
		IF convert( int, substring( @6data, 25, 4 ) ) = 1  --only happens with -MaxCmdsInTran 
		begin
			select @6seqno = substring( @6data, 11, 10 ) + @max_offset
			INSERT INTO MSrepl_transactions VALUES (@publisher_database_id,
				 substring( @6data, 1, 10 ), @6seqno, @date)
			select @max_offset  = @max_offset + 1
		end
		else
			select @6seqno = @5seqno 
	end
	else
	begin
		select @6seqno = substring( @6data, 11, 10 ) 
		IF convert( int, substring( @6data, 25, 4 ) ) = 1  
			INSERT INTO MSrepl_transactions VALUES (@publisher_database_id,
				 substring( @6data, 1, 10 ), @6seqno, @date)
	end

	IF @7data is null
	  goto INSERT_CMDS
	if(substring( @7data, 11, 10 ) = substring( @6data, 11, 10 )) --same tran
	begin
		IF convert( int, substring( @7data, 25, 4 ) ) = 1  --only happens with -MaxCmdsInTran 
		begin
			select @7seqno = substring( @7data, 11, 10 ) + @max_offset
			INSERT INTO MSrepl_transactions VALUES (@publisher_database_id,
				 substring( @7data, 1, 10 ), @7seqno, @date)
			select @max_offset  = @max_offset + 1
		end
		else
			select @7seqno = @6seqno 
	end
	else
	begin
		select @7seqno = substring( @7data, 11, 10 ) 
		IF convert( int, substring( @7data, 25, 4 ) ) = 1  
			INSERT INTO MSrepl_transactions VALUES (@publisher_database_id,
				 substring( @7data, 1, 10 ), @7seqno, @date)
	end

	IF @8data is null
	  goto INSERT_CMDS
	if(substring( @8data, 11, 10 ) = substring( @7data, 11, 10 )) --same tran
	begin
		IF convert( int, substring( @8data, 25, 4 ) ) = 1  --only happens with -MaxCmdsInTran 
		begin
			select @8seqno = substring( @8data, 11, 10 ) + @max_offset
			INSERT INTO MSrepl_transactions VALUES (@publisher_database_id,
				 substring( @8data, 1, 10 ), @8seqno, @date)
			select @max_offset  = @max_offset + 1
		end
		else
			select @8seqno = @7seqno 
	end
	else
	begin
		select @8seqno = substring( @8data, 11, 10 ) 
		IF convert( int, substring( @8data, 25, 4 ) ) = 1  
			INSERT INTO MSrepl_transactions VALUES (@publisher_database_id,
				 substring( @8data, 1, 10 ), @8seqno, @date)
	end

	IF @9data is null
	  goto INSERT_CMDS
	if(substring( @9data, 11, 10 ) = substring( @8data, 11, 10 )) --same tran
	begin
		IF convert( int, substring( @9data, 25, 4 ) ) = 1  --only happens with -MaxCmdsInTran 
		begin
			select @9seqno = substring( @9data, 11, 10 ) + @max_offset
			INSERT INTO MSrepl_transactions VALUES (@publisher_database_id,
				 substring( @9data, 1, 10 ), @9seqno, @date)
			select @max_offset  = @max_offset + 1
		end
		else
			select @9seqno = @8seqno 
	end
	else
	begin
		select @9seqno = substring( @9data, 11, 10 ) 
		IF convert( int, substring( @9data, 25, 4 ) ) = 1  
			INSERT INTO MSrepl_transactions VALUES (@publisher_database_id,
				 substring( @9data, 1, 10 ), @9seqno, @date)
	end

	IF @10data is null
	  goto INSERT_CMDS
	if(substring( @10data, 11, 10 ) = substring( @9data, 11, 10 )) --same tran
	begin
		IF convert( int, substring( @10data, 25, 4 ) ) = 1  --only happens with -MaxCmdsInTran 
		begin
			select @10seqno = substring( @10data, 11, 10 ) + @max_offset
			INSERT INTO MSrepl_transactions VALUES (@publisher_database_id,
				 substring( @10data, 1, 10 ), @10seqno, @date)
			select @max_offset  = @max_offset + 1
		end
		else
			select @10seqno = @9seqno 
	end
	else
	begin
		select @10seqno = substring( @10data, 11, 10 ) 
		IF convert( int, substring( @10data, 25, 4 ) ) = 1  
			INSERT INTO MSrepl_transactions VALUES (@publisher_database_id,
				 substring( @10data, 1, 10 ), @10seqno, @date)
	end

	IF @11data is null
	  goto INSERT_CMDS
	if(substring( @11data, 11, 10 ) = substring( @10data, 11, 10 )) --same tran
	begin
		IF convert( int, substring( @11data, 25, 4 ) ) = 1  --only happens with -MaxCmdsInTran 
		begin
			select @11seqno = substring( @11data, 11, 10 )+ @max_offset
			INSERT INTO MSrepl_transactions VALUES (@publisher_database_id,
				 substring( @11data, 1, 10 ), @11seqno, @date)
			select @max_offset  = @max_offset + 1
		end
		else
			select @11seqno = @10seqno 
	end
	else
	begin
		select @11seqno = substring( @11data, 11, 10 ) 
		IF convert( int, substring( @11data, 25, 4 ) ) = 1  
			INSERT INTO MSrepl_transactions VALUES (@publisher_database_id,
				 substring( @11data, 1, 10 ), @11seqno, @date)
	end

	IF @12data is null
	  goto INSERT_CMDS
	if(substring( @12data, 11, 10 ) = substring( @11data, 11, 10 )) --same tran
	begin
		IF convert( int, substring( @12data, 25, 4 ) ) = 1  --only happens with -MaxCmdsInTran 
		begin
			select @12seqno = substring( @12data, 11, 10 ) + @max_offset
			INSERT INTO MSrepl_transactions VALUES (@publisher_database_id,
				 substring( @12data, 1, 10 ), @12seqno, @date)
			select @max_offset  = @max_offset + 1
		end
		else
			select @12seqno = @11seqno 
	end
	else
	begin
		select @12seqno = substring( @12data, 11, 10 ) 
		IF convert( int, substring( @12data, 25, 4 ) ) = 1  
			INSERT INTO MSrepl_transactions VALUES (@publisher_database_id,
				 substring( @12data, 1, 10 ), @12seqno, @date)
	end
	
	IF @13data is null
	  goto INSERT_CMDS
if(substring( @13data, 11, 10 ) = substring( @12data, 11, 10 )) --same tran
	begin
		IF convert( int, substring( @13data, 25, 4 ) ) = 1  --only happens with -MaxCmdsInTran 
		begin
			select @13seqno = substring( @13data, 11, 10 ) + @max_offset
			INSERT INTO MSrepl_transactions VALUES (@publisher_database_id,
				 substring( @13data, 1, 10 ), @13seqno, @date)
			select @max_offset  = @max_offset + 1
		end
		else
			select @13seqno = @12seqno 
	end
	else
	begin
		select @13seqno = substring( @13data, 11, 10 ) 
		IF convert( int, substring( @13data, 25, 4 ) ) = 1  --only happens with -MaxCmdsInTran 
			INSERT INTO MSrepl_transactions VALUES (@publisher_database_id,
				 substring( @13data, 1, 10 ), @13seqno, @date)
	end

	IF @14data is null
	  goto INSERT_CMDS
if(substring( @14data, 11, 10 ) = substring( @13data, 11, 10 )) --same tran
	begin
		IF convert( int, substring( @14data, 25, 4 ) ) = 1  --only happens with -MaxCmdsInTran 
		begin
			select @14seqno = substring( @14data, 11, 10 ) + @max_offset
			INSERT INTO MSrepl_transactions VALUES (@publisher_database_id,
				 substring( @14data, 1, 10 ), @14seqno, @date)
			select @max_offset  = @max_offset + 1
		end
		else
			select @14seqno = @13seqno 
	end
	else
	begin
		select @14seqno = substring( @14data, 11, 10 ) 
		IF convert( int, substring( @14data, 25, 4 ) ) = 1  
			INSERT INTO MSrepl_transactions VALUES (@publisher_database_id,
				 substring( @14data, 1, 10 ), @14seqno, @date)
	end

	IF @15data is null
	  goto INSERT_CMDS
if(substring( @15data, 11, 10 ) = substring( @14data, 11, 10 )) --same tran
	begin
		IF convert( int, substring( @15data, 25, 4 ) ) = 1  --only happens with -MaxCmdsInTran 
		begin
			select @15seqno = substring( @15data, 11, 10 ) + @max_offset
			INSERT INTO MSrepl_transactions VALUES (@publisher_database_id,
				 substring( @15data, 1, 10 ), @15seqno, @date)
			select @max_offset  = @max_offset + 1
		end
		else
			select @15seqno = @14seqno 
	end
	else
	begin
		select @15seqno = substring( @15data, 11, 10 ) 
		IF convert( int, substring( @15data, 25, 4 ) ) = 1  
			INSERT INTO MSrepl_transactions VALUES (@publisher_database_id,
				 substring( @15data, 1, 10 ), @15seqno, @date)
	end

	IF @16data is null
	  goto INSERT_CMDS
if(substring( @16data, 11, 10 ) = substring( @15data, 11, 10 )) --same tran
	begin
		IF convert( int, substring( @16data, 25, 4 ) ) = 1  --only happens with -MaxCmdsInTran 
		begin
			select @16seqno = substring( @16data, 11, 10 ) + @max_offset
			INSERT INTO MSrepl_transactions VALUES (@publisher_database_id,
				 substring( @16data, 1, 10 ), @16seqno, @date)
			select @max_offset  = @max_offset + 1
		end
		else
			select @16seqno = @15seqno 
	end
	else
	begin
		select @16seqno = substring( @16data, 11, 10 ) 
		IF convert( int, substring( @16data, 25, 4 ) ) = 1  
			INSERT INTO MSrepl_transactions VALUES (@publisher_database_id,
				 substring( @16data, 1, 10 ), @16seqno, @date)
	end

	IF @17data is null
	  goto INSERT_CMDS
if(substring( @17data, 11, 10 ) = substring( @16data, 11, 10 )) --same tran
	begin
		IF convert( int, substring( @17data, 25, 4 ) ) = 1  --only happens with -MaxCmdsInTran 
		begin
			select @17seqno = substring( @17data, 11, 10 ) + @max_offset
			INSERT INTO MSrepl_transactions VALUES (@publisher_database_id,
				 substring( @17data, 1, 10 ), @17seqno, @date)
			select @max_offset  = @max_offset + 1
		end
		else
			select @17seqno = @16seqno 
	end
	else
	begin
		select @17seqno = substring( @17data, 11, 10 ) 
		IF convert( int, substring( @17data, 25, 4 ) ) = 1  
			INSERT INTO MSrepl_transactions VALUES (@publisher_database_id,
				 substring( @17data, 1, 10 ), @17seqno, @date)
	end

	IF @18data is null
	  goto INSERT_CMDS
	if(substring( @18data, 11, 10 ) = substring( @17data, 11, 10 )) --same tran
	begin
		IF convert( int, substring( @18data, 25, 4 ) ) = 1  --only happens with -MaxCmdsInTran 
		begin
			select @18seqno = substring( @18data, 11, 10 )+ @max_offset
			INSERT INTO MSrepl_transactions VALUES (@publisher_database_id,
				 substring( @18data, 1, 10 ), @18seqno, @date)
			select @max_offset  = @max_offset + 1
		end
		else
			select @18seqno = @17seqno 
	end
	else
	begin
		select @18seqno = substring( @18data, 11, 10 ) 
		IF convert( int, substring( @18data, 25, 4 ) ) = 1  
			INSERT INTO MSrepl_transactions VALUES (@publisher_database_id,
				 substring( @18data, 1, 10 ), @18seqno, @date)
	end

	IF @19data is null
	  goto INSERT_CMDS
	if(substring( @19data, 11, 10 ) = substring( @18data, 11, 10 )) --same tran
	begin
		IF convert( int, substring( @19data, 25, 4 ) ) = 1  --only happens with -MaxCmdsInTran 
		begin
			select @19seqno = substring( @19data, 11, 10 ) + @max_offset
			INSERT INTO MSrepl_transactions VALUES (@publisher_database_id,
				 substring( @19data, 1, 10 ), @19seqno, @date)
			select @max_offset  = @max_offset + 1
		end
		else
			select @19seqno = @18seqno 
	end
	else
	begin
		select @19seqno = substring( @19data, 11, 10 ) 
		IF convert( int, substring( @19data, 25, 4 ) ) = 1  
			INSERT INTO MSrepl_transactions VALUES (@publisher_database_id,
				 substring( @19data, 1, 10 ), @19seqno, @date)
	end

	IF @20data is null
	  goto INSERT_CMDS
	if(substring( @20data, 11, 10 ) = substring( @19data, 11, 10 )) --same tran
	begin
		IF convert( int, substring( @20data, 25, 4 ) ) = 1  --only happens with -MaxCmdsInTran 
		begin
			select @20seqno = substring( @20data, 11, 10 ) + @max_offset
			INSERT INTO MSrepl_transactions VALUES (@publisher_database_id,
				 substring( @20data, 1, 10 ), @20seqno, @date)
			select @max_offset  = @max_offset + 1
		end
		else
			select @20seqno = @19seqno 
	end
	else
	begin
		select @20seqno = substring( @20data, 11, 10 ) 
		IF convert( int, substring( @20data, 25, 4 ) ) = 1  
			INSERT INTO MSrepl_transactions VALUES (@publisher_database_id,
				 substring( @20data, 1, 10 ), @20seqno, @date)
	end

	IF @21data is null
	  goto INSERT_CMDS
	if(substring( @21data, 11, 10 ) = substring( @20data, 11, 10 )) --same tran
	begin
		IF convert( int, substring( @21data, 25, 4 ) ) = 1  --only happens with -MaxCmdsInTran 
		begin
			select @21seqno = substring( @21data, 11, 10 ) + @max_offset
			INSERT INTO MSrepl_transactions VALUES (@publisher_database_id,
				 substring( @21data, 1, 10 ), @21seqno, @date)
			select @max_offset  = @max_offset + 1
		end
		else
			select @21seqno = @20seqno 
	end
	else
	begin
		select @21seqno = substring( @21data, 11, 10 ) 
		IF convert( int, substring( @21data, 25, 4 ) ) = 1  
			INSERT INTO MSrepl_transactions VALUES (@publisher_database_id,
				 substring( @21data, 1, 10 ), @21seqno, @date)
	end

	IF @22data is null
	  goto INSERT_CMDS
	if(substring( @22data, 11, 10 ) = substring( @21data, 11, 10 )) --same tran
	begin
		IF convert( int, substring( @22data, 25, 4 ) ) = 1  --only happens with -MaxCmdsInTran 
		begin
			select @22seqno = substring( @22data, 11, 10 ) + @max_offset
			INSERT INTO MSrepl_transactions VALUES (@publisher_database_id,
				 substring( @22data, 1, 10 ), @22seqno, @date)
			select @max_offset  = @max_offset + 1
		end
		else
			select @22seqno = @21seqno 
	end
	else
	begin
		select @22seqno = substring( @22data, 11, 10 ) 
		IF convert( int, substring( @22data, 25, 4 ) ) = 1  
			INSERT INTO MSrepl_transactions VALUES (@publisher_database_id,
				 substring( @22data, 1, 10 ), @22seqno, @date)
	end

	IF @23data is null
	  goto INSERT_CMDS
	if(substring( @23data, 11, 10 ) = substring( @22data, 11, 10 )) --same tran
	begin
		IF convert( int, substring( @23data, 25, 4 ) ) = 1  --only happens with -MaxCmdsInTran 
		begin
			select @23seqno = substring( @23data, 11, 10 ) + @max_offset
			INSERT INTO MSrepl_transactions VALUES (@publisher_database_id,
				 substring( @23data, 1, 10 ), @23seqno, @date)
			select @max_offset  = @max_offset + 1
		end
		else
			select @23seqno = @22seqno 
	end
	else
	begin
		select @23seqno = substring( @23data, 11, 10 ) 
		IF convert( int, substring( @23data, 25, 4 ) ) = 1  
			INSERT INTO MSrepl_transactions VALUES (@publisher_database_id,
				 substring( @23data, 1, 10 ), @23seqno, @date)
	end

	IF @24data is null
	  goto INSERT_CMDS
	if(substring( @24data, 11, 10 ) = substring( @23data, 11, 10 )) --same tran
	begin
		IF convert( int, substring( @24data, 25, 4 ) ) = 1  --only happens with -MaxCmdsInTran 
		begin
			select @24seqno = substring( @24data, 11, 10 ) + @max_offset
			INSERT INTO MSrepl_transactions VALUES (@publisher_database_id,
				 substring( @24data, 1, 10 ), @24seqno, @date)
			select @max_offset  = @max_offset + 1
		end
		else
			select @24seqno = @23seqno 
	end
	else
	begin
		select @24seqno = substring( @24data, 11, 10 ) 
		IF convert( int, substring( @24data, 25, 4 ) ) = 1  
			INSERT INTO MSrepl_transactions VALUES (@publisher_database_id,
				 substring( @24data, 1, 10 ), @24seqno, @date)
	end

	IF @25data is null
	  goto INSERT_CMDS
	if(substring( @25data, 11, 10 ) = substring( @24data, 11, 10 )) --same tran
	begin
		IF convert( int, substring( @25data, 25, 4 ) ) = 1  --only happens with -MaxCmdsInTran 
		begin
			select @25seqno = substring( @25data, 11, 10 ) + @max_offset
			INSERT INTO MSrepl_transactions VALUES (@publisher_database_id,
				 substring( @25data, 1, 10 ), @25seqno, @date)
			select @max_offset  = @max_offset + 1
		end
		else
			select @25seqno = @24seqno 
	end
	else
	begin
		select @25seqno = substring( @25data, 11, 10 ) 
		IF convert( int, substring( @25data, 25, 4 ) ) = 1  
			INSERT INTO MSrepl_transactions VALUES (@publisher_database_id,
				 substring( @25data, 1, 10 ), @25seqno, @date)
	end

	IF @26data is null
	  goto INSERT_CMDS
	if(substring( @26data, 11, 10 ) = substring( @25data, 11, 10 )) --same tran
	begin
		IF convert( int, substring( @26data, 25, 4 ) ) = 1  --only happens with -MaxCmdsInTran 
		begin
			select @26seqno = substring( @26data, 11, 10 ) + @max_offset
			INSERT INTO MSrepl_transactions VALUES (@publisher_database_id,
				 substring( @26data, 1, 10 ), @26seqno, @date)
			select @max_offset  = @max_offset + 1
		end
		else
			select @26seqno = @25seqno 
	end
	else
	begin
		select @26seqno = substring( @26data, 11, 10 ) 
		IF convert( int, substring( @26data, 25, 4 ) ) = 1  
			INSERT INTO MSrepl_transactions VALUES (@publisher_database_id,
				 substring( @26data, 1, 10 ), @26seqno, @date)
	end

INSERT_CMDS:

	if datalength( @data ) > 39
	begin
		-- Get the originator_id for the first command 
		select @cmd_data_len = substring( @data, 34, 2 )
		select @orig_srv_len = substring( @data, 36, 2 )
		select @orig_db_len = substring( @data, 38, 2 )

		if @orig_srv_len <> 0 and @orig_db_len <> 0 
		begin 
			set @originator_id = null 
			select @originator_id = id from MSrepl_originators where
				publisher_database_id = @publisher_database_id 
				and UPPER(srvname) = upper(convert(sysname, substring( @data, 40 + @cmd_data_len, @orig_srv_len )))
				and dbname = substring( @data, 40 + @cmd_data_len + @orig_srv_len, @orig_db_len )
			if @originator_id is null
			begin
				insert into MSrepl_originators (publisher_database_id, srvname, dbname) values
					(@publisher_database_id, UPPER(substring( @data, 40 + @cmd_data_len, @orig_srv_len )), substring( @data, 40 + @cmd_data_len + @orig_srv_len, @orig_db_len ))
				select @originator_id = @@identity
			end
		end
		else
			select @originator_id = 0

		select @cmd_type = substring(@data,29,4) 
		if( @cmd_type in( 37,38 ) )
		begin
			select @artid = substring(@data,21,4)
			select @cmd_type = 38 - @cmd_type
			exec sp_MSset_syncstate @publisher_id, @publisher_db, @artid, @cmd_type, @seqno
			select @cmd_type = (38 - @cmd_type) | 0x80000000
		end

		INSERT INTO MSrepl_commands (publisher_database_id, xact_seqno, type, article_id, originator_id, command_id, partial_command, command)
			VALUES (@publisher_database_id, 
			@seqno,
			@cmd_type, 
			substring(@data,21,4), 
			@originator_id, 
			substring(@data,25,4), 
			convert(bit,substring(@data,33,1)), 
			substring(@data,40,@cmd_data_len) )

	end
	
	IF @1data is null
	  return
	IF datalength( @1data ) > 39
	begin
		-- Get the originator_id for the first command 
		select @cmd_data_len = substring( @1data, 34, 2 )
		select @orig_srv_len = substring( @1data, 36, 2 )
		select @orig_db_len = substring( @1data, 38, 2 )
		if @orig_srv_len <> 0 and @orig_db_len <> 0 
		begin 
			set @originator_id = null 
			select @originator_id = id from MSrepl_originators where
				publisher_database_id = @publisher_database_id 
				and UPPER(srvname) = upper(convert(sysname, substring( @1data, 40 + @cmd_data_len, @orig_srv_len )))
				and dbname = substring( @1data, 40 + @cmd_data_len + @orig_srv_len, @orig_db_len )
			if @originator_id is null
			begin
				insert into MSrepl_originators (publisher_database_id, srvname, dbname) values
					(@publisher_database_id, UPPER(substring( @1data, 40 + @cmd_data_len, @orig_srv_len )), substring( @1data, 40 + @cmd_data_len + @orig_srv_len, @orig_db_len ))
				select @originator_id = @@identity
			end
		end
		else
			select @originator_id = 0

		-- Now insert into MSrepl_commands
		select @cmd_type = substring(@1data,29,4)
		if( @cmd_type in( 37,38 ) )
		begin
			select @artid = substring(@1data,21,4)
			select @cmd_type = 38 - @cmd_type
			exec sp_MSset_syncstate @publisher_id, @publisher_db, @artid, @cmd_type, @1seqno
			select @cmd_type = (38 - @cmd_type) | 0x80000000
		end

		INSERT INTO MSrepl_commands (publisher_database_id, xact_seqno, type, article_id, originator_id, command_id, partial_command, command)
			VALUES (@publisher_database_id, 
			@1seqno, 
			@cmd_type, 
			substring(@1data,21,4), 
			@originator_id, 
			substring(@1data,25,4), 
			convert(bit,substring(@1data,33,1)), 
			substring(@1data,40,@cmd_data_len) )
	end

	IF @2data is null
	  return
	IF datalength( @2data ) > 39
	begin
		-- Get the originator_id for the first command 
		select @cmd_data_len = substring( @2data, 34, 2 )
		select @orig_srv_len = substring( @2data, 36, 2 )
		select @orig_db_len = substring( @2data, 38, 2 )
		if @orig_srv_len <> 0 and @orig_db_len <> 0 
		begin 
			set @originator_id = null 
			select @originator_id = id from MSrepl_originators where
				publisher_database_id = @publisher_database_id 
				and UPPER(srvname) = upper(convert(sysname, substring( @2data, 40 + @cmd_data_len, @orig_srv_len )))
				and dbname = substring( @2data, 40 + @cmd_data_len + @orig_srv_len, @orig_db_len )
			if @originator_id is null
			begin
				insert into MSrepl_originators (publisher_database_id, srvname, dbname) values
					(@publisher_database_id, UPPER(substring( @2data, 40 + @cmd_data_len, @orig_srv_len )), substring( @2data, 40 + @cmd_data_len + @orig_srv_len, @orig_db_len ))
				select @originator_id = @@identity
			end
		end
		else
			select @originator_id = 0

		-- Now insert into MSrepl_commands
		select @cmd_type = substring(@2data,29,4)
		if( @cmd_type in( 37,38 ) )
		begin
			select @artid = substring(@2data,21,4)
			select @cmd_type = 38 - @cmd_type
			exec sp_MSset_syncstate @publisher_id, @publisher_db, @artid, @cmd_type, @2seqno
			select @cmd_type = (38 - @cmd_type) | 0x80000000
		end

		INSERT INTO MSrepl_commands (publisher_database_id, xact_seqno, type, article_id, originator_id, command_id, partial_command, command)
			VALUES (@publisher_database_id, 
			@2seqno,
			@cmd_type, 
			substring(@2data,21 ,4), 
			@originator_id, 
			substring(@2data,25 ,4), 
			convert(bit,substring(@2data,33 ,1)), 
			substring(@2data,40,@cmd_data_len) )

	end

	IF @3data is null
	  return
	IF datalength( @3data ) > 39
	begin
		-- Get the originator_id for the first command 
		select @cmd_data_len = substring( @3data, 34, 2 )
		select @orig_srv_len = substring( @3data, 36, 2 )
		select @orig_db_len = substring( @3data, 38, 2 )
		if @orig_srv_len <> 0 and @orig_db_len <> 0 
		begin 
			set @originator_id = null 
			select @originator_id = id from MSrepl_originators where
				publisher_database_id = @publisher_database_id 
				and UPPER(srvname) = upper(convert(sysname, substring( @3data, 40 + @cmd_data_len, @orig_srv_len )))
				and dbname = substring( @3data, 40 + @cmd_data_len + @orig_srv_len, @orig_db_len )
			if @originator_id is null
			begin
				insert into MSrepl_originators (publisher_database_id, srvname, dbname) values
					(@publisher_database_id, UPPER(substring( @3data, 40 + @cmd_data_len, @orig_srv_len )), substring( @3data, 40 + @cmd_data_len + @orig_srv_len, @orig_db_len ))
				select @originator_id = @@identity
			end
		end
		else
			select @originator_id = 0

		-- Now insert into MSrepl_commands
		select @cmd_type = substring(@3data,29,4)
		if( @cmd_type in( 37,38 ) )
		begin
			select @artid = substring(@3data,21,4)
			select @cmd_type = 38 - @cmd_type
			select @xact_seqno = substring( @3data, 11, 10 )
			exec sp_MSset_syncstate @publisher_id, @publisher_db, @artid, @cmd_type, @3seqno
			select @cmd_type = (38 - @cmd_type) | 0x80000000
		end

		INSERT INTO MSrepl_commands (publisher_database_id, xact_seqno, type, article_id, originator_id, command_id, partial_command, command)
			VALUES (@publisher_database_id, 
			@3seqno,
			@cmd_type, 
			substring(@3data,21 ,4), 
			@originator_id, 
			substring(@3data,25 ,4), 
			convert(bit,substring(@3data,33 ,1)), 
			substring(@3data,40,@cmd_data_len) )

	end

	IF @4data is null
	  return
	IF datalength( @4data ) > 39
	begin
		-- Get the originator_id for the first command 
		select @cmd_data_len = substring( @4data, 34, 2 )
		select @orig_srv_len = substring( @4data, 36, 2 )
		select @orig_db_len = substring( @4data, 38, 2 )
		if @orig_srv_len <> 0 and @orig_db_len <> 0 
		begin 
			set @originator_id = null 
			select @originator_id = id from MSrepl_originators where
				publisher_database_id = @publisher_database_id 
				and UPPER(srvname) = upper(convert(sysname, substring( @4data, 40 + @cmd_data_len, @orig_srv_len )))
				and dbname = substring( @4data, 40 + @cmd_data_len + @orig_srv_len, @orig_db_len )
			if @originator_id is null
			begin
				insert into MSrepl_originators (publisher_database_id, srvname, dbname) values
					(@publisher_database_id, UPPER(substring( @4data, 40 + @cmd_data_len, @orig_srv_len )), substring( @4data, 40 + @cmd_data_len + @orig_srv_len, @orig_db_len ))
				select @originator_id = @@identity
			end
		end
		else
			select @originator_id = 0

		-- Now insert into MSrepl_commands
		select @cmd_type = substring(@4data,29,4)
		if( @cmd_type in( 37,38 ) )
		begin
			select @artid = substring(@4data,21,4)
			select @cmd_type = 38 - @cmd_type
			exec sp_MSset_syncstate @publisher_id, @publisher_db, @artid, @cmd_type, @4seqno
			select @cmd_type = (38 - @cmd_type) | 0x80000000
		end

		INSERT INTO MSrepl_commands (publisher_database_id, xact_seqno, type, article_id, originator_id, command_id, partial_command, command)
			VALUES (@publisher_database_id, 
			@4seqno,
			@cmd_type, 
			substring(@4data,21 ,4), 
			@originator_id, 
			substring(@4data,25 ,4), 
			convert(bit,substring(@4data,33 ,1)), 
			substring(@4data,40,@cmd_data_len) )

	end

	IF @5data is null
	  return
	IF datalength( @5data ) > 39
	begin
		-- Get the originator_id for the first command 
		select @cmd_data_len = substring( @5data, 34, 2 )
		select @orig_srv_len = substring( @5data, 36, 2 )
		select @orig_db_len = substring( @5data, 38, 2 )
		if @orig_srv_len <> 0 and @orig_db_len <> 0 
		begin 
			set @originator_id = null 
			select @originator_id = id from MSrepl_originators where
				publisher_database_id = @publisher_database_id 
				and UPPER(srvname) = upper(convert(sysname, substring( @5data, 40 + @cmd_data_len, @orig_srv_len )))
				and dbname = substring( @5data, 40 + @cmd_data_len + @orig_srv_len, @orig_db_len )
			if @originator_id is null
			begin
				insert into MSrepl_originators (publisher_database_id, srvname, dbname) values
					(@publisher_database_id, UPPER(substring( @5data, 40 + @cmd_data_len, @orig_srv_len )), substring( @5data, 40 + @cmd_data_len + @orig_srv_len, @orig_db_len ))
				select @originator_id = @@identity
			end
		end
		else
			select @originator_id = 0

		-- Now insert into MSrepl_commands
		select @cmd_type = substring(@5data,29,4)
		if( @cmd_type in( 37,38 ) )
		begin
			select @artid = substring(@5data,21,4)
			select @cmd_type = 38 - @cmd_type
			exec sp_MSset_syncstate @publisher_id, @publisher_db, @artid, @cmd_type, @5seqno
			select @cmd_type = (38 - @cmd_type) | 0x80000000
		end

		INSERT INTO MSrepl_commands (publisher_database_id, xact_seqno, type, article_id, originator_id, command_id, partial_command, command)
			VALUES (@publisher_database_id, 
			@5seqno,
			@cmd_type, 
			substring(@5data,21 ,4), 
			@originator_id, 
			substring(@5data,25 ,4), 
			convert(bit,substring(@5data,33 ,1)), 
			substring(@5data,40,@cmd_data_len) )

	end

	IF @6data is null
	  return
	IF datalength( @6data ) > 39
	begin
		-- Get the originator_id for the first command 
		select @cmd_data_len = substring( @6data, 34, 2 )
		select @orig_srv_len = substring( @6data, 36, 2 )
		select @orig_db_len = substring( @6data, 38, 2 )
		if @orig_srv_len <> 0 and @orig_db_len <> 0 
		begin 
			set @originator_id = null 
			select @originator_id = id from MSrepl_originators where
				publisher_database_id = @publisher_database_id 
				and UPPER(srvname) = upper(convert(sysname, substring( @6data, 40 + @cmd_data_len, @orig_srv_len )))
				and dbname = substring( @6data, 40 + @cmd_data_len + @orig_srv_len, @orig_db_len )
			if @originator_id is null
			begin
				insert into MSrepl_originators (publisher_database_id, srvname, dbname) values
					(@publisher_database_id, UPPER(substring( @6data, 40 + @cmd_data_len, @orig_srv_len )), substring( @6data, 40 + @cmd_data_len + @orig_srv_len, @orig_db_len ))
				select @originator_id = @@identity
			end
		end
		else
			select @originator_id = 0

		-- Now insert into MSrepl_commands
		select @cmd_type = substring(@6data,29,4)
		if( @cmd_type in( 37,38 ) )
		begin
			select @artid = substring(@6data,21,4)
			select @cmd_type = 38 - @cmd_type
			exec sp_MSset_syncstate @publisher_id, @publisher_db, @artid, @cmd_type, @6seqno  
			select @cmd_type = (38 - @cmd_type) | 0x80000000
		end

		INSERT INTO MSrepl_commands (publisher_database_id, xact_seqno, type, article_id, originator_id, command_id, partial_command, command)
			VALUES (@publisher_database_id, 
			@6seqno,
			@cmd_type, 
			substring(@6data,21 ,4), 
			@originator_id, 
			substring(@6data,25 ,4), 
			convert(bit,substring(@6data,33 ,1)), 
			substring(@6data,40,@cmd_data_len) )

	end

	IF @7data is null
	  return
	IF datalength( @7data ) > 39
	begin
		-- Get the originator_id for the first command 
		select @cmd_data_len = substring( @7data, 34, 2 )
		select @orig_srv_len = substring( @7data, 36, 2 )
		select @orig_db_len = substring( @7data, 38, 2 )
		if @orig_srv_len <> 0 and @orig_db_len <> 0 
		begin 
			set @originator_id = null 
			select @originator_id = id from MSrepl_originators where
				publisher_database_id = @publisher_database_id 
				and UPPER(srvname) = upper(convert(sysname, substring( @7data, 40 + @cmd_data_len, @orig_srv_len )))
				and dbname = substring( @7data, 40 + @cmd_data_len + @orig_srv_len, @orig_db_len )
			if @originator_id is null
			begin
				insert into MSrepl_originators (publisher_database_id, srvname, dbname) values
					(@publisher_database_id, UPPER(substring( @7data, 40 + @cmd_data_len, @orig_srv_len )), substring( @7data, 40 + @cmd_data_len + @orig_srv_len, @orig_db_len ))
				select @originator_id = @@identity
			end
		end
		else
			select @originator_id = 0

		-- Now insert into MSrepl_commands
		select @cmd_type = substring(@7data,29,4)
		if( @cmd_type in( 37,38 ) )
		begin
			select @artid = substring(@7data,21,4)
			select @cmd_type = 38 - @cmd_type
			exec sp_MSset_syncstate @publisher_id, @publisher_db, @artid, @cmd_type, @7seqno  
			select @cmd_type = (38 - @cmd_type) | 0x80000000
		end

		INSERT INTO MSrepl_commands (publisher_database_id, xact_seqno, type, article_id, originator_id, command_id, partial_command, command)
			VALUES (@publisher_database_id, 
			@7seqno,
			@cmd_type, 
			substring(@7data,21 ,4), 
			@originator_id, 
			substring(@7data,25 ,4), 
			convert(bit,substring(@7data,33 ,1)), 
			substring(@7data,40,@cmd_data_len) )

	end

	IF @8data is null
	  return
	IF datalength( @8data ) > 39
	begin
		-- Get the originator_id for the first command 
		select @cmd_data_len = substring( @8data, 34, 2 )
		select @orig_srv_len = substring( @8data, 36, 2 )
		select @orig_db_len = substring( @8data, 38, 2 )
		if @orig_srv_len <> 0 and @orig_db_len <> 0 
		begin 
			set @originator_id = null 
			select @originator_id = id from MSrepl_originators where
				publisher_database_id = @publisher_database_id 
				and UPPER(srvname) = upper(convert(sysname, substring( @8data, 40 + @cmd_data_len, @orig_srv_len )))
				and dbname = substring( @8data, 40 + @cmd_data_len + @orig_srv_len, @orig_db_len )
			if @originator_id is null
			begin
				insert into MSrepl_originators (publisher_database_id, srvname, dbname) values
					(@publisher_database_id, UPPER(substring( @8data, 40 + @cmd_data_len, @orig_srv_len )), substring( @8data, 40 + @cmd_data_len + @orig_srv_len, @orig_db_len ))
				select @originator_id = @@identity
			end
		end
		else
			select @originator_id = 0

		-- Now insert into MSrepl_commands
		select @cmd_type = substring(@8data,29,4)
		if( @cmd_type in( 37,38 ) )
		begin
			select @artid = substring(@8data,21,4)
			select @cmd_type = 38 - @cmd_type
			exec sp_MSset_syncstate @publisher_id, @publisher_db, @artid, @cmd_type, @8seqno  
			select @cmd_type = (38 - @cmd_type) | 0x80000000
		end

		INSERT INTO MSrepl_commands (publisher_database_id, xact_seqno, type, article_id, originator_id, command_id, partial_command, command)
			VALUES (@publisher_database_id, 
			@8seqno,
			@cmd_type, 
			substring(@8data,21 ,4), 
			@originator_id, 
			substring(@8data,25 ,4), 
			convert(bit,substring(@8data,33 ,1)), 
			substring(@8data,40,@cmd_data_len) )
	end

	IF @9data is null
	  return
	IF datalength( @9data ) > 39
	begin
		-- Get the originator_id for the first command 
		select @cmd_data_len = substring( @9data, 34, 2 )
		select @orig_srv_len = substring( @9data, 36, 2 )
		select @orig_db_len = substring( @9data, 38, 2 )
		if @orig_srv_len <> 0 and @orig_db_len <> 0 
		begin 
			set @originator_id = null 
			select @originator_id = id from MSrepl_originators where
				publisher_database_id = @publisher_database_id 
				and upper(srvname) = upper(convert(sysname, substring( @9data, 40 + @cmd_data_len, @orig_srv_len )))
				and dbname = substring( @9data, 40 + @cmd_data_len + @orig_srv_len, @orig_db_len )
			if @originator_id is null
			begin
				insert into MSrepl_originators (publisher_database_id, srvname, dbname) values
					(@publisher_database_id, UPPER(substring( @9data, 40 + @cmd_data_len, @orig_srv_len )), substring( @9data, 40 + @cmd_data_len + @orig_srv_len, @orig_db_len ))
				select @originator_id = @@identity
			end
		end
		else
			select @originator_id = 0

		-- Now insert into MSrepl_commands
		select @cmd_type = substring(@9data,29,4)
		if( @cmd_type in( 37,38 ) )
		begin
			select @artid = substring(@9data,21,4)
			select @cmd_type = 38 - @cmd_type
			exec sp_MSset_syncstate @publisher_id, @publisher_db, @artid, @cmd_type, @9seqno  
			select @cmd_type = (38 - @cmd_type) | 0x80000000
		end

		INSERT INTO MSrepl_commands (publisher_database_id, xact_seqno, type, article_id, originator_id, command_id, partial_command, command)
			VALUES (@publisher_database_id, 
			@9seqno,
			@cmd_type, 
			substring(@9data,21 ,4), 
			@originator_id, 
			substring(@9data,25 ,4), 
			convert(bit,substring(@9data,33 ,1)), 
			substring(@9data,40,@cmd_data_len) )
	end

	IF @10data is null
	  return
	IF datalength( @10data ) > 39
	begin
		-- Get the originator_id for the first command 
		select @cmd_data_len = substring( @10data, 34, 2 )
		select @orig_srv_len = substring( @10data, 36, 2 )
		select @orig_db_len = substring( @10data, 38, 2 )
		if @orig_srv_len <> 0 and @orig_db_len <> 0 
		begin 
			set @originator_id = null 
			select @originator_id = id from MSrepl_originators where
				publisher_database_id = @publisher_database_id 
				and UPPER(srvname) = upper(convert(sysname, substring( @10data, 40 + @cmd_data_len, @orig_srv_len )))
				and dbname = substring( @10data, 40 + @cmd_data_len + @orig_srv_len, @orig_db_len )
			if @originator_id is null
			begin
				insert into MSrepl_originators (publisher_database_id, srvname, dbname) values
					(@publisher_database_id, UPPER(substring( @10data, 40 + @cmd_data_len, @orig_srv_len )), substring( @10data, 40 + @cmd_data_len + @orig_srv_len, @orig_db_len ))
				select @originator_id = @@identity
			end
		end
		else
			select @originator_id = 0

		-- Now insert into MSrepl_commands
		select @cmd_type = substring(@10data,29,4)
		if( @cmd_type in( 37,38 ) )
		begin
			select @artid = substring(@10data,21,4)
			select @cmd_type = 38 - @cmd_type
			exec sp_MSset_syncstate @publisher_id, @publisher_db, @artid, @cmd_type, @10seqno  
			select @cmd_type = (38 - @cmd_type) | 0x80000000
		end

		INSERT INTO MSrepl_commands (publisher_database_id, xact_seqno, type, article_id, originator_id, command_id, partial_command, command)
			VALUES (@publisher_database_id, 
			@10seqno,
			@cmd_type, 
			substring(@10data,21 ,4), 
			@originator_id, 
			substring(@10data,25 ,4), 
			convert(bit,substring(@10data,33 ,1)), 
			substring(@10data,40,@cmd_data_len) )

	end

	IF @11data is null
	  return
	IF datalength( @11data ) > 39
	begin
		-- Get the originator_id for the first command 
		select @cmd_data_len = substring( @11data, 34, 2 )
		select @orig_srv_len = substring( @11data, 36, 2 )
		select @orig_db_len = substring( @11data, 38, 2 )
		if @orig_srv_len <> 0 and @orig_db_len <> 0 
		begin 
			set @originator_id = null 
			select @originator_id = id from MSrepl_originators where
				publisher_database_id = @publisher_database_id 
				and UPPER(srvname) = upper(convert(sysname, substring( @11data, 40 + @cmd_data_len, @orig_srv_len )))
				and dbname = substring( @11data, 40 + @cmd_data_len + @orig_srv_len, @orig_db_len )
			if @originator_id is null
			begin
				insert into MSrepl_originators (publisher_database_id, srvname, dbname) values
					(@publisher_database_id, UPPER(substring( @11data, 40 + @cmd_data_len, @orig_srv_len )), substring( @11data, 40 + @cmd_data_len + @orig_srv_len, @orig_db_len ))
				select @originator_id = @@identity
			end
		end
		else
			select @originator_id = 0

		-- Now insert into MSrepl_commands
		select @cmd_type = substring(@11data,29,4)
		if( @cmd_type in( 37,38 ) )
		begin
			select @artid = substring(@11data,21,4)
			select @cmd_type = 38 - @cmd_type
			exec sp_MSset_syncstate @publisher_id, @publisher_db, @artid, @cmd_type, @11seqno  
			select @cmd_type = (38 - @cmd_type) | 0x80000000
		end

		INSERT INTO MSrepl_commands (publisher_database_id, xact_seqno, type, article_id, originator_id, command_id, partial_command, command)
			VALUES (@publisher_database_id, 
			@11seqno,
			@cmd_type, 
			substring(@11data,21 ,4), 
			@originator_id, 
			substring(@11data,25 ,4), 
			convert(bit,substring(@11data,33 ,1)), 
			substring(@11data,40,@cmd_data_len) )
	end

	IF @12data is null
	  return
	IF datalength( @12data ) > 39
	begin
		-- Get the originator_id for the first command 
		select @cmd_data_len = substring( @12data, 34, 2 )
		select @orig_srv_len = substring( @12data, 36, 2 )
		select @orig_db_len = substring( @12data, 38, 2 )
		if @orig_srv_len <> 0 and @orig_db_len <> 0 
		begin 
			set @originator_id = null 
			select @originator_id = id from MSrepl_originators where
				publisher_database_id = @publisher_database_id 
				and UPPER(srvname) = upper(convert(sysname, substring( @12data, 40 + @cmd_data_len, @orig_srv_len )))
				and dbname = substring( @12data, 40 + @cmd_data_len + @orig_srv_len, @orig_db_len )
			if @originator_id is null
			begin
				insert into MSrepl_originators (publisher_database_id, srvname, dbname) values
					(@publisher_database_id, UPPER(substring( @12data, 40 + @cmd_data_len, @orig_srv_len )), substring( @12data, 40 + @cmd_data_len + @orig_srv_len, @orig_db_len ))
				select @originator_id = @@identity
			end
		end
		else
			select @originator_id = 0

		-- Now insert into MSrepl_commands
		select @cmd_type = substring(@12data,29,4)
		if( @cmd_type in( 37,38 ) )
		begin
			select @artid = substring(@12data,21,4)
			select @cmd_type = 38 - @cmd_type
			exec sp_MSset_syncstate @publisher_id, @publisher_db, @artid, @cmd_type, @12seqno  
			select @cmd_type = (38 - @cmd_type) | 0x80000000
		end

		INSERT INTO MSrepl_commands (publisher_database_id, xact_seqno, type, article_id, originator_id, command_id, partial_command, command)
			VALUES (@publisher_database_id, 
			@12seqno,
			@cmd_type, 
			substring(@12data,21 ,4), 
			@originator_id, 
			substring(@12data,25 ,4), 
			convert(bit,substring(@12data,33 ,1)), 
			substring(@12data,40,@cmd_data_len) )
	end


	IF @13data is null
	  return
	IF datalength( @13data ) > 39
	begin
		-- Get the originator_id for the first command 
		select @cmd_data_len = substring( @13data, 34, 2 )
		select @orig_srv_len = substring( @13data, 36, 2 )
		select @orig_db_len = substring( @13data, 38, 2 )
		if @orig_srv_len <> 0 and @orig_db_len <> 0 
		begin 
			set @originator_id = null 
			select @originator_id = id from MSrepl_originators where
				publisher_database_id = @publisher_database_id 
				and UPPER(srvname) = upper(convert(sysname, substring( @13data, 40 + @cmd_data_len, @orig_srv_len )))
				and dbname = substring( @13data, 40 + @cmd_data_len + @orig_srv_len, @orig_db_len )
			if @originator_id is null
			begin
				insert into MSrepl_originators (publisher_database_id, srvname, dbname) values
					(@publisher_database_id, UPPER(substring( @13data, 40 + @cmd_data_len, @orig_srv_len )), substring( @13data, 40 + @cmd_data_len + @orig_srv_len, @orig_db_len ))
				select @originator_id = @@identity
			end
		end
		else
			select @originator_id = 0

		-- Now insert into MSrepl_commands
		select @cmd_type = substring(@13data,29,4)
		if( @cmd_type in( 37,38 ) )
		begin
			select @artid = substring(@13data,21,4)
			select @cmd_type = 38 - @cmd_type
			exec sp_MSset_syncstate @publisher_id, @publisher_db, @artid, @cmd_type, @13seqno  
			select @cmd_type = (38 - @cmd_type) | 0x80000000
		end

		INSERT INTO MSrepl_commands (publisher_database_id, xact_seqno, type, article_id, originator_id, command_id, partial_command, command)
			VALUES (@publisher_database_id, 
			@13seqno,
			@cmd_type, 
			substring(@13data,21 ,4), 
			@originator_id, 
			substring(@13data,25 ,4), 
			convert(bit,substring(@13data,33 ,1)), 
			substring(@13data,40,@cmd_data_len) )
	end

	IF @14data is null
	  return
	IF datalength( @14data ) > 39
	begin
		-- Get the originator_id for the first command 
		select @cmd_data_len = substring( @14data, 34, 2 )
		select @orig_srv_len = substring( @14data, 36, 2 )
		select @orig_db_len = substring( @14data, 38, 2 )
		if @orig_srv_len <> 0 and @orig_db_len <> 0 
		begin 
			set @originator_id = null 
			select @originator_id = id from MSrepl_originators where
				publisher_database_id = @publisher_database_id 
				and UPPER(srvname) = upper(convert(sysname, substring( @14data, 40 + @cmd_data_len, @orig_srv_len )))
				and dbname = substring( @14data, 40 + @cmd_data_len + @orig_srv_len, @orig_db_len )
			if @originator_id is null
			begin
				insert into MSrepl_originators (publisher_database_id, srvname, dbname) values
					(@publisher_database_id, UPPER(substring( @14data, 40 + @cmd_data_len, @orig_srv_len )), substring( @14data, 40 + @cmd_data_len + @orig_srv_len, @orig_db_len ))
				select @originator_id = @@identity
			end
		end
		else
			select @originator_id = 0

		-- Now insert into MSrepl_commands
		select @cmd_type = substring(@14data,29,4)
		if( @cmd_type in( 37,38 ) )
		begin
			select @artid = substring(@14data,21,4)
			select @cmd_type = 38 - @cmd_type
			exec sp_MSset_syncstate @publisher_id, @publisher_db, @artid, @cmd_type, @14seqno  
			select @cmd_type = (38 - @cmd_type) | 0x80000000
		end

		INSERT INTO MSrepl_commands (publisher_database_id, xact_seqno, type, article_id, originator_id, command_id, partial_command, command)
			VALUES (@publisher_database_id, 
			@14seqno,
			@cmd_type, 
			substring(@14data,21 ,4), 
			@originator_id, 
			substring(@14data,25 ,4), 
			convert(bit,substring(@14data,33 ,1)), 
			substring(@14data,40,@cmd_data_len) )
	end


	IF @15data is null
	  return
	IF datalength( @15data ) > 39
	begin
		-- Get the originator_id for the first command 
		select @cmd_data_len = substring( @15data, 34, 2 )
		select @orig_srv_len = substring( @15data, 36, 2 )
		select @orig_db_len = substring( @15data, 38, 2 )
		if @orig_srv_len <> 0 and @orig_db_len <> 0 
		begin 
			set @originator_id = null 
			select @originator_id = id from MSrepl_originators where
				publisher_database_id = @publisher_database_id 
				and UPPER(srvname) = upper(convert(sysname, substring( @15data, 40 + @cmd_data_len, @orig_srv_len )))
				and dbname = substring( @15data, 40 + @cmd_data_len + @orig_srv_len, @orig_db_len )
			if @originator_id is null
			begin
				insert into MSrepl_originators (publisher_database_id, srvname, dbname) values
					(@publisher_database_id, UPPER(substring( @15data, 40 + @cmd_data_len, @orig_srv_len )), substring( @15data, 40 + @cmd_data_len + @orig_srv_len, @orig_db_len ))
				select @originator_id = @@identity
			end
		end
		else
			select @originator_id = 0

		-- Now insert into MSrepl_commands
		select @cmd_type = substring(@15data,29,4)
		if( @cmd_type in( 37,38 ) )
		begin
			select @artid = substring(@15data,21,4)
			select @cmd_type = 38 - @cmd_type
			exec sp_MSset_syncstate @publisher_id, @publisher_db, @artid, @cmd_type, @15seqno  
			select @cmd_type = (38 - @cmd_type) | 0x80000000
		end

		INSERT INTO MSrepl_commands (publisher_database_id, xact_seqno, type, article_id, originator_id, command_id, partial_command, command)
			VALUES (@publisher_database_id, 
			@15seqno,
			@cmd_type, 
			substring(@15data,21 ,4), 
			@originator_id, 
			substring(@15data,25 ,4), 
			convert(bit,substring(@15data,33 ,1)), 
			substring(@15data,40,@cmd_data_len) )
	end

	IF @16data is null
	  return
	IF datalength( @16data ) > 39
	begin
		-- Get the originator_id for the first command 
		select @cmd_data_len = substring( @16data, 34, 2 )
		select @orig_srv_len = substring( @16data, 36, 2 )
		select @orig_db_len = substring( @16data, 38, 2 )
		if @orig_srv_len <> 0 and @orig_db_len <> 0 
		begin 
			set @originator_id = null 
			select @originator_id = id from MSrepl_originators where
				publisher_database_id = @publisher_database_id 
				and UPPER(srvname) = upper(convert(sysname, substring( @16data, 40 + @cmd_data_len, @orig_srv_len )))
				and dbname = substring( @16data, 40 + @cmd_data_len + @orig_srv_len, @orig_db_len )
			if @originator_id is null
			begin
				insert into MSrepl_originators (publisher_database_id, srvname, dbname) values
					(@publisher_database_id, UPPER(substring( @16data, 40 + @cmd_data_len, @orig_srv_len )), substring( @16data, 40 + @cmd_data_len + @orig_srv_len, @orig_db_len ))
				select @originator_id = @@identity
			end
		end
		else
			select @originator_id = 0

		-- Now insert into MSrepl_commands
		select @cmd_type = substring(@16data,29,4)
		if( @cmd_type in( 37,38 ) )
		begin
			select @artid = substring(@16data,21,4)
			select @cmd_type = 38 - @cmd_type
			exec sp_MSset_syncstate @publisher_id, @publisher_db, @artid, @cmd_type, @16seqno  
			select @cmd_type = (38 - @cmd_type) | 0x80000000
		end

		INSERT INTO MSrepl_commands (publisher_database_id, xact_seqno, type, article_id, originator_id, command_id, partial_command, command)
			VALUES (@publisher_database_id, 
			@16seqno,
			@cmd_type, 
			substring(@16data,21 ,4), 
			@originator_id, 
			substring(@16data,25 ,4), 
			convert(bit,substring(@16data,33 ,1)), 
			substring(@16data,40,@cmd_data_len) )
	end


	IF @17data is null
	  return
	IF datalength( @17data ) > 39
	begin
		-- Get the originator_id for the first command 
		select @cmd_data_len = substring( @17data, 34, 2 )
		select @orig_srv_len = substring( @17data, 36, 2 )
		select @orig_db_len = substring( @17data, 38, 2 )
		if @orig_srv_len <> 0 and @orig_db_len <> 0 
		begin 
			set @originator_id = null 
			select @originator_id = id from MSrepl_originators where
				publisher_database_id = @publisher_database_id 
				and UPPER(srvname) = upper(convert(sysname, substring( @17data, 40 + @cmd_data_len, @orig_srv_len )))
				and dbname = substring( @17data, 40 + @cmd_data_len + @orig_srv_len, @orig_db_len )
			if @originator_id is null
			begin
				insert into MSrepl_originators (publisher_database_id, srvname, dbname) values
					(@publisher_database_id, UPPER(substring( @17data, 40 + @cmd_data_len, @orig_srv_len )), substring( @17data, 40 + @cmd_data_len + @orig_srv_len, @orig_db_len ))
				select @originator_id = @@identity
			end
		end
		else
			select @originator_id = 0

		-- Now insert into MSrepl_commands
		select @cmd_type = substring(@17data,29,4)
		if( @cmd_type in( 37,38 ) )
		begin
			select @artid = substring(@17data,21,4)
			select @cmd_type = 38 - @cmd_type
			exec sp_MSset_syncstate @publisher_id, @publisher_db, @artid, @cmd_type, @17seqno  
			select @cmd_type = (38 - @cmd_type) | 0x80000000
		end

		INSERT INTO MSrepl_commands (publisher_database_id, xact_seqno, type, article_id, originator_id, command_id, partial_command, command)
			VALUES (@publisher_database_id, 
			@17seqno,
			@cmd_type, 
			substring(@17data,21 ,4), 
			@originator_id, 
			substring(@17data,25 ,4), 
			convert(bit,substring(@17data,33 ,1)), 
			substring(@17data,40,@cmd_data_len) )
	end


	IF @18data is null
	  return
	IF datalength( @18data ) > 39
	begin
		-- Get the originator_id for the first command 
		select @cmd_data_len = substring( @18data, 34, 2 )
		select @orig_srv_len = substring( @18data, 36, 2 )
		select @orig_db_len = substring( @18data, 38, 2 )
		if @orig_srv_len <> 0 and @orig_db_len <> 0 
		begin 
			set @originator_id = null 
			select @originator_id = id from MSrepl_originators where
				publisher_database_id = @publisher_database_id 
				and UPPER(srvname) = upper(convert(sysname, substring( @18data, 40 + @cmd_data_len, @orig_srv_len )))
				and dbname = substring( @18data, 40 + @cmd_data_len + @orig_srv_len, @orig_db_len )
			if @originator_id is null
			begin
				insert into MSrepl_originators (publisher_database_id, srvname, dbname) values
					(@publisher_database_id, UPPER(substring( @18data, 40 + @cmd_data_len, @orig_srv_len )), substring( @18data, 40 + @cmd_data_len + @orig_srv_len, @orig_db_len ))
				select @originator_id = @@identity
			end
		end
		else
			select @originator_id = 0

		-- Now insert into MSrepl_commands
		select @cmd_type = substring(@18data,29,4)
		if( @cmd_type in( 37,38 ) )
		begin
			select @artid = substring(@18data,21,4)
			select @cmd_type = 38 - @cmd_type
			exec sp_MSset_syncstate @publisher_id, @publisher_db, @artid, @cmd_type, @18seqno  
			select @cmd_type = (38 - @cmd_type) | 0x80000000
		end

		INSERT INTO MSrepl_commands (publisher_database_id, xact_seqno, type, article_id, originator_id, command_id, partial_command, command)
			VALUES (@publisher_database_id, 
			@18seqno,
			@cmd_type, 
			substring(@18data,21 ,4), 
			@originator_id, 
			substring(@18data,25 ,4), 
			convert(bit,substring(@18data,33 ,1)), 
			substring(@18data,40,@cmd_data_len) )
	end


	IF @19data is null
	  return
	IF datalength( @19data ) > 39
	begin
		-- Get the originator_id for the first command 
		select @cmd_data_len = substring( @19data, 34, 2 )
		select @orig_srv_len = substring( @19data, 36, 2 )
		select @orig_db_len = substring( @19data, 38, 2 )
		if @orig_srv_len <> 0 and @orig_db_len <> 0 
		begin 
			set @originator_id = null 
			select @originator_id = id from MSrepl_originators where
				publisher_database_id = @publisher_database_id 
				and UPPER(srvname) = upper(convert(sysname, substring( @19data, 40 + @cmd_data_len, @orig_srv_len )))
				and dbname = substring( @19data, 40 + @cmd_data_len + @orig_srv_len, @orig_db_len )
			if @originator_id is null
			begin
				insert into MSrepl_originators (publisher_database_id, srvname, dbname) values
					(@publisher_database_id, UPPER(substring( @19data, 40 + @cmd_data_len, @orig_srv_len )), substring( @19data, 40 + @cmd_data_len + @orig_srv_len, @orig_db_len ))
				select @originator_id = @@identity
			end
		end
		else
			select @originator_id = 0

		-- Now insert into MSrepl_commands
		select @cmd_type = substring(@19data,29,4)
		if( @cmd_type in( 37,38 ) )
		begin
			select @artid = substring(@19data,21,4)
			select @cmd_type = 38 - @cmd_type
			exec sp_MSset_syncstate @publisher_id, @publisher_db, @artid, @cmd_type, @19seqno  
			select @cmd_type = (38 - @cmd_type) | 0x80000000
		end

		INSERT INTO MSrepl_commands (publisher_database_id, xact_seqno, type, article_id, originator_id, command_id, partial_command, command)
			VALUES (@publisher_database_id, 
			@19seqno,
			@cmd_type, 
			substring(@19data,21 ,4), 
			@originator_id, 
			substring(@19data,25 ,4), 
			convert(bit,substring(@19data,33 ,1)), 
			substring(@19data,40,@cmd_data_len) )
	end


	IF @20data is null
	  return
	IF datalength( @20data ) > 39
	begin
		-- Get the originator_id for the first command 
		select @cmd_data_len = substring( @20data, 34, 2 )
		select @orig_srv_len = substring( @20data, 36, 2 )
		select @orig_db_len = substring( @20data, 38, 2 )
		if @orig_srv_len <> 0 and @orig_db_len <> 0 
		begin 
			set @originator_id = null 
			select @originator_id = id from MSrepl_originators where
				publisher_database_id = @publisher_database_id 
				and UPPER(srvname) = upper(convert(sysname, substring( @20data, 40 + @cmd_data_len, @orig_srv_len )))
				and dbname = substring( @20data, 40 + @cmd_data_len + @orig_srv_len, @orig_db_len )
			if @originator_id is null
			begin
				insert into MSrepl_originators (publisher_database_id, srvname, dbname) values
					(@publisher_database_id, UPPER(substring( @20data, 40 + @cmd_data_len, @orig_srv_len )), substring( @20data, 40 + @cmd_data_len + @orig_srv_len, @orig_db_len ))
				select @originator_id = @@identity
			end
		end
		else
			select @originator_id = 0

		-- Now insert into MSrepl_commands
		select @cmd_type = substring(@20data,29,4)
		if( @cmd_type in( 37,38 ) )
		begin
			select @artid = substring(@20data,21,4)
			select @cmd_type = 38 - @cmd_type
			exec sp_MSset_syncstate @publisher_id, @publisher_db, @artid, @cmd_type, @20seqno  
			select @cmd_type = (38 - @cmd_type) | 0x80000000
		end

		INSERT INTO MSrepl_commands (publisher_database_id, xact_seqno, type, article_id, originator_id, command_id, partial_command, command)
			VALUES (@publisher_database_id, 
			@20seqno,
			@cmd_type, 
			substring(@20data,21 ,4), 
			@originator_id, 
			substring(@20data,25 ,4), 
			convert(bit,substring(@20data,33 ,1)), 
			substring(@20data,40,@cmd_data_len) )
	end

	IF @21data is null
	  return
	IF datalength( @21data ) > 39
	begin
		-- Get the originator_id for the first command 
		select @cmd_data_len = substring( @21data, 34, 2 )
		select @orig_srv_len = substring( @21data, 36, 2 )
		select @orig_db_len = substring( @21data, 38, 2 )
		if @orig_srv_len <> 0 and @orig_db_len <> 0 
		begin 
			set @originator_id = null 
			select @originator_id = id from MSrepl_originators where
				publisher_database_id = @publisher_database_id 
				and UPPER(srvname) = upper(convert(sysname, substring( @21data, 40 + @cmd_data_len, @orig_srv_len )))
				and dbname = substring( @21data, 40 + @cmd_data_len + @orig_srv_len, @orig_db_len )
			if @originator_id is null
			begin
				insert into MSrepl_originators (publisher_database_id, srvname, dbname) values
					(@publisher_database_id, UPPER(substring( @21data, 40 + @cmd_data_len, @orig_srv_len )), substring( @21data, 40 + @cmd_data_len + @orig_srv_len, @orig_db_len ))
				select @originator_id = @@identity
			end
		end
		else
			select @originator_id = 0

		-- Now insert into MSrepl_commands
		select @cmd_type = substring(@21data,29,4)
		if( @cmd_type in( 37,38 ) )
		begin
			select @artid = substring(@21data,21,4)
			select @cmd_type = 38 - @cmd_type
			exec sp_MSset_syncstate @publisher_id, @publisher_db, @artid, @cmd_type, @21seqno  
			select @cmd_type = (38 - @cmd_type) | 0x80000000
		end

		INSERT INTO MSrepl_commands (publisher_database_id, xact_seqno, type, article_id, originator_id, command_id, partial_command, command)
			VALUES (@publisher_database_id, 
			@21seqno,
			@cmd_type, 
			substring(@21data,21 ,4), 
			@originator_id, 
			substring(@21data,25 ,4), 
			convert(bit,substring(@21data,33 ,1)), 
			substring(@21data,40,@cmd_data_len) )
	end

	IF @22data is null
	  return
	IF datalength( @22data ) > 39
	begin
		-- Get the originator_id for the first command 
		select @cmd_data_len = substring( @22data, 34, 2 )
		select @orig_srv_len = substring( @22data, 36, 2 )
		select @orig_db_len = substring( @22data, 38, 2 )
		if @orig_srv_len <> 0 and @orig_db_len <> 0 
		begin 
			set @originator_id = null 
			select @originator_id = id from MSrepl_originators where
				publisher_database_id = @publisher_database_id 
				and UPPER(srvname) = upper(convert(sysname, substring( @22data, 40 + @cmd_data_len, @orig_srv_len )))
				and dbname = substring( @22data, 40 + @cmd_data_len + @orig_srv_len, @orig_db_len )
			if @originator_id is null
			begin
				insert into MSrepl_originators (publisher_database_id, srvname, dbname) values
					(@publisher_database_id, UPPER(substring( @22data, 40 + @cmd_data_len, @orig_srv_len )), substring( @22data, 40 + @cmd_data_len + @orig_srv_len, @orig_db_len ))
				select @originator_id = @@identity
			end
		end
		else
			select @originator_id = 0

		-- Now insert into MSrepl_commands
		select @cmd_type = substring(@22data,29,4)
		if( @cmd_type in( 37,38 ) )
		begin
			select @artid = substring(@22data,21,4)
			select @cmd_type = 38 - @cmd_type
			exec sp_MSset_syncstate @publisher_id, @publisher_db, @artid, @cmd_type, @22seqno  
			select @cmd_type = (38 - @cmd_type) | 0x80000000
		end

		INSERT INTO MSrepl_commands (publisher_database_id, xact_seqno, type, article_id, originator_id, command_id, partial_command, command)
			VALUES (@publisher_database_id, 
			@22seqno,
			@cmd_type, 
			substring(@22data,21 ,4), 
			@originator_id, 
			substring(@22data,25 ,4), 
			convert(bit,substring(@22data,33 ,1)), 
			substring(@22data,40,@cmd_data_len) )
	end

	IF @23data is null
	  return
	IF datalength( @23data ) > 39
	begin
		-- Get the originator_id for the first command 
		select @cmd_data_len = substring( @23data, 34, 2 )
		select @orig_srv_len = substring( @23data, 36, 2 )
		select @orig_db_len = substring( @23data, 38, 2 )
		if @orig_srv_len <> 0 and @orig_db_len <> 0 
		begin 
			set @originator_id = null 
			select @originator_id = id from MSrepl_originators where
				publisher_database_id = @publisher_database_id 
				and UPPER(srvname) = upper(convert(sysname, substring( @23data, 40 + @cmd_data_len, @orig_srv_len )))
				and dbname = substring( @23data, 40 + @cmd_data_len + @orig_srv_len, @orig_db_len )
			if @originator_id is null
			begin
				insert into MSrepl_originators (publisher_database_id, srvname, dbname) values
					(@publisher_database_id, UPPER(substring( @23data, 40 + @cmd_data_len, @orig_srv_len )), substring( @23data, 40 + @cmd_data_len + @orig_srv_len, @orig_db_len ))
				select @originator_id = @@identity
			end
		end
		else
			select @originator_id = 0

		-- Now insert into MSrepl_commands
		select @cmd_type = substring(@23data,29,4)
		if( @cmd_type in( 37,38 ) )
		begin
			select @artid = substring(@23data,21,4)
			select @cmd_type = 38 - @cmd_type
			exec sp_MSset_syncstate @publisher_id, @publisher_db, @artid, @cmd_type, @23seqno  
			select @cmd_type = (38 - @cmd_type) | 0x80000000
		end

		INSERT INTO MSrepl_commands (publisher_database_id, xact_seqno, type, article_id, originator_id, command_id, partial_command, command)
			VALUES (@publisher_database_id, 
			@23seqno,
			@cmd_type, 
			substring(@23data,21 ,4), 
			@originator_id, 
			substring(@23data,25 ,4), 
			convert(bit,substring(@23data,33 ,1)), 
			substring(@23data,40,@cmd_data_len) )
	end

	IF @24data is null
	  return
	IF datalength( @24data ) > 39
	begin
		-- Get the originator_id for the first command 
		select @cmd_data_len = substring( @24data, 34, 2 )
		select @orig_srv_len = substring( @24data, 36, 2 )
		select @orig_db_len = substring( @24data, 38, 2 )
		if @orig_srv_len <> 0 and @orig_db_len <> 0 
		begin 
			set @originator_id = null 
			select @originator_id = id from MSrepl_originators where
				publisher_database_id = @publisher_database_id 
				and UPPER(srvname) = upper(convert(sysname, substring( @24data, 40 + @cmd_data_len, @orig_srv_len )))
				and dbname = substring( @24data, 40 + @cmd_data_len + @orig_srv_len, @orig_db_len )
			if @originator_id is null
			begin
				insert into MSrepl_originators (publisher_database_id, srvname, dbname) values
					(@publisher_database_id, UPPER(substring( @24data, 40 + @cmd_data_len, @orig_srv_len )), substring( @24data, 40 + @cmd_data_len + @orig_srv_len, @orig_db_len ))
				select @originator_id = @@identity
			end
		end
		else
			select @originator_id = 0

		-- Now insert into MSrepl_commands
		select @cmd_type = substring(@24data,29,4)
		if( @cmd_type in( 37,38 ) )
		begin
			select @artid = substring(@24data,21,4)
			select @cmd_type = 38 - @cmd_type
			exec sp_MSset_syncstate @publisher_id, @publisher_db, @artid, @cmd_type, @24seqno  
			select @cmd_type = (38 - @cmd_type) | 0x80000000
		end

		INSERT INTO MSrepl_commands (publisher_database_id, xact_seqno, type, article_id, originator_id, command_id, partial_command, command)
			VALUES (@publisher_database_id, 
			@24seqno,
			@cmd_type, 
			substring(@24data,21 ,4), 
			@originator_id, 
			substring(@24data,25 ,4), 
			convert(bit,substring(@24data,33 ,1)), 
			substring(@24data,40,@cmd_data_len) )
	end


	IF @25data is null
	  return
	IF datalength( @25data ) > 39
	begin
		-- Get the originator_id for the first command 
		select @cmd_data_len = substring( @25data, 34, 2 )
		select @orig_srv_len = substring( @25data, 36, 2 )
		select @orig_db_len = substring( @25data, 38, 2 )
		if @orig_srv_len <> 0 and @orig_db_len <> 0 
		begin 
			set @originator_id = null 
			select @originator_id = id from MSrepl_originators where
				publisher_database_id = @publisher_database_id 
				and UPPER(srvname) = upper(convert(sysname, substring( @25data, 40 + @cmd_data_len, @orig_srv_len )))
				and dbname = substring( @25data, 40 + @cmd_data_len + @orig_srv_len, @orig_db_len )
			if @originator_id is null
			begin
				insert into MSrepl_originators (publisher_database_id, srvname, dbname) values
					(@publisher_database_id, UPPER(substring( @25data, 40 + @cmd_data_len, @orig_srv_len )), substring( @25data, 40 + @cmd_data_len + @orig_srv_len, @orig_db_len ))
				select @originator_id = @@identity
			end
		end
		else
			select @originator_id = 0

		-- Now insert into MSrepl_commands
		select @cmd_type = substring(@25data,29,4)
		if( @cmd_type in( 37,38 ) )
		begin
			select @artid = substring(@25data,21,4)
			select @cmd_type = 38 - @cmd_type
			exec sp_MSset_syncstate @publisher_id, @publisher_db, @artid, @cmd_type, @25seqno  
			select @cmd_type = (38 - @cmd_type) | 0x80000000
		end

		INSERT INTO MSrepl_commands (publisher_database_id, xact_seqno, type, article_id, originator_id, command_id, partial_command, command)
			VALUES (@publisher_database_id, 
			@25seqno,
			@cmd_type, 
			substring(@25data,21 ,4), 
			@originator_id, 
			substring(@25data,25 ,4), 
			convert(bit,substring(@25data,33 ,1)), 
			substring(@25data,40,@cmd_data_len) )
	end


	IF @26data is null
	  return
	IF datalength( @26data ) > 39
	begin
		-- Get the originator_id for the first command 
		select @cmd_data_len = substring( @26data, 34, 2 )
		select @orig_srv_len = substring( @26data, 36, 2 )
		select @orig_db_len = substring( @26data, 38, 2 )
		if @orig_srv_len <> 0 and @orig_db_len <> 0 
		begin 
			set @originator_id = null 
			select @originator_id = id from MSrepl_originators where
				publisher_database_id = @publisher_database_id 
				and UPPER(srvname) = upper(convert(sysname, substring( @26data, 40 + @cmd_data_len, @orig_srv_len )))
				and dbname = substring( @26data, 40 + @cmd_data_len + @orig_srv_len, @orig_db_len )
			if @originator_id is null
			begin
				insert into MSrepl_originators (publisher_database_id, srvname, dbname) values
					(@publisher_database_id, UPPER(substring( @26data, 40 + @cmd_data_len, @orig_srv_len )), substring( @26data, 40 + @cmd_data_len + @orig_srv_len, @orig_db_len ))
				select @originator_id = @@identity
			end
		end
		else
			select @originator_id = 0

		-- Now insert into MSrepl_commands
		select @cmd_type = substring(@26data,29,4)
		if( @cmd_type in( 37,38 ) )
		begin
			select @artid = substring(@26data,21,4)
			select @cmd_type = 38 - @cmd_type
			exec sp_MSset_syncstate @publisher_id, @publisher_db, @artid, @cmd_type, @26seqno  
			select @cmd_type = (38 - @cmd_type) | 0x80000000
		end

		INSERT INTO MSrepl_commands (publisher_database_id, xact_seqno, type, article_id, originator_id, command_id, partial_command, command)
			VALUES (@publisher_database_id, 
			@26seqno,
			@cmd_type, 
			substring(@26data,21 ,4), 
			@originator_id, 
			substring(@26data,25 ,4), 
			convert(bit,substring(@26data,33 ,1)), 
			substring(@26data,40,@cmd_data_len) )
	end


	IF @@ERROR <> 0
	  return (1)
end
GO
GRANT EXECUTE ON [sys].[sp_MSadd_repl_commands27hp] TO [public] AS [dbo]
GO
