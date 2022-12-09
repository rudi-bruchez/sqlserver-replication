SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_publisherproperty]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_publisherproperty] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_publisherproperty]
	@publisher [sysname],
	@propertyname [sysname],
	@propertyvalue [sysname]
WITH EXECUTE AS CALLER
AS
BEGIN
	DECLARE @cmd			nvarchar(4000)
	DECLARE @cmd2			nvarchar(4000)
	DECLARE @retcode		int
	DECLARE @publisher_type	sysname
	DECLARE @jobenabled		bit
	DECLARE @batchenabled	bit
	DECLARE @interval		int

	SET @jobenabled	= 0
	SET @batchenabled = 0
	SET @interval = 0

	-- Security Check: requires sysadmin, done in sp_MSrepl_getpublisherinfo

	SET @retcode = 0

	EXEC @retcode = sys.sp_MSrepl_getpublisherinfo	@publisher		= @publisher,
													@rpcheader		= @cmd OUTPUT,
													@publisher_type	= @publisher_type OUTPUT,
													@hreplOnly		= 1							
	
	IF @retcode <> 0
		RETURN (@retcode)

	-- Error if the publisher is not an Oracle publisher
	IF @publisher_type NOT LIKE 'ORACLE%'
	BEGIN
		RAISERROR (21687, 16, -1, @publisher, @publisher_type)
		RETURN (1)
	END
	
	-- If propertyname is NULL, propertyvalue must be NULL as well
	IF @propertyname IS NULL and @propertyvalue IS NOT NULL
    BEGIN
        -- Nothing to do - just leave
        RETURN (0)
	END
	
	-- If propertyname is NULL return values for all of the settable properties
	IF @propertyname IS NULL
	BEGIN
		create table #properties
		(
			propertyname sysname,
			propertyvalue sysname
		)
	
		-- Return parity of xactsetbatching flag
		set @cmd2 = @cmd
		set @cmd2 = @cmd2 + N'sys.sp_ORAhelpXactBatching'
	
		EXEC @retcode = @cmd2	@publisher,
			@enabled = @batchenabled OUTPUT
				
		if @retcode <> 0 or @@error <> 0
			RETURN(1)	

		-- Return parity of xactset job flag and job interval
		set @cmd2 = @cmd
		set @cmd2 = @cmd2 + N'sys.sp_ORAhelpXactSetJob'
	
		EXEC @retcode = @cmd2	@publisher,
			@interval = @interval OUTPUT,
			@enabled = @jobenabled OUTPUT
				
		if @retcode <> 0 or @@error <> 0
			RETURN(1)	
				
		-- Return result set
		INSERT INTO #properties
		VALUES(
			N'xactsetbatching',
			CASE isnull(@batchenabled,0)
				WHEN 1 THEN N'enabled'
				WHEN 0 THEN N'disabled'
			END
		)
		INSERT INTO #properties
		VALUES(
			N'xactsetjob',
			CASE isnull(@jobenabled,0)
				WHEN 1 THEN N'enabled'
				WHEN 0 THEN N'disabled'
			END
		)
		INSERT INTO #properties
		VALUES(
			N'xactsetjobinterval',
			CONVERT(NVARCHAR(20),@interval)
		)
		
		-- return result set
		SELECT * FROM #properties
			
		RETURN (0)
	END

	-- Validate property name
	IF @propertyname NOT IN (N'xactsetbatching', N'xactsetjob', N'xactsetjobinterval')
	BEGIN
		RAISERROR (21794, 16, -1, '''xactsetbatching'',''xactsetjob'', and ''xactsetjobinterval''')
    	RETURN (1)
	END
	
	-- Process xactsetbatching
	IF @propertyname = 'xactsetbatching'
	BEGIN
		-- If propertyvalue is NULL, return property value
		IF @propertyvalue IS NULL
		BEGIN
			-- Return parity of xactsetbatching flag
			set @cmd = @cmd + N'sys.sp_ORAhelpXactBatching'
	
			EXEC @retcode = @cmd	@publisher,
				@enabled = @batchenabled OUTPUT
				
			if @retcode <> 0 or @@error <> 0
				RETURN(1)	

			-- Return result set
			select @propertyname as N'propertyname',
				CASE isnull(@batchenabled,0)
					WHEN 1 THEN N'enabled'
					WHEN 0 THEN N'disabled'
				END as N'propertyvalue'
				
			RETURN (@retcode)
		END
	
		-- If set, property value must be either enable or disabled
		IF @propertyvalue NOT IN (N'enabled', N'disabled')
		BEGIN
			RAISERROR (21795, 16, -1, '''xactsetbatching''', '''enabled'' and ''disabled''')
    		RETURN (1)
		END
		
		IF @propertyvalue = N'enabled'
			SET @batchenabled = 1
		ELSE
			SET @batchenabled = 0	

		set @cmd = @cmd + N'sys.sp_ORASetXactBatching'
	
		EXEC @retcode = @cmd	@publisher,
				@enabled = @batchenabled

		RETURN (@retcode)
	
	END
	
	-- Process xactsetjob
	IF @propertyname = N'xactsetjob'
	BEGIN

		-- If propertyvalue is NULL, return property value
		IF @propertyvalue IS NULL
		BEGIN
			-- Return parity of xactsetjob flag
			set @cmd = @cmd + N'sys.sp_ORAhelpXactSetJob'
	
			EXEC @retcode = @cmd	@publisher,
				@enabled = @jobenabled OUTPUT
				
			if @retcode <> 0 or @@error <> 0
				RETURN(1)	

			-- Return result set
			select @propertyname as N'propertyname',
				CASE isnull(@jobenabled,0)
					WHEN 1 THEN N'enabled'
					WHEN 0 THEN N'disabled'
				END as N'propertyvalue'
				
			RETURN (@retcode)
		END
		
		-- If set, property value must be either enable or disabled
		IF @propertyvalue NOT IN (N'enabled', N'disabled')
		BEGIN
			RAISERROR (21795, 16, -1, '''xactsetjob''', '''enabled'' and ''disabled''')
    		RETURN (1)
		END
		
		IF @propertyvalue = N'enabled'
			SET @jobenabled = 1
		ELSE
			SET @jobenabled = 0	
		
		set @cmd = @cmd + N'sys.sp_ORAXactSetJob'
	
		EXEC @retcode = @cmd	@publisher,
				@enabled = @jobenabled
				
		RETURN (@retcode)
	
	END
	
	-- Process xactsetjobinterval
	IF @propertyname = N'xactsetjobinterval'
	BEGIN
		-- If propertyvalue is NULL, return property value
		IF @propertyvalue IS NULL
		BEGIN
			-- Return xactset job interval
			set @cmd = @cmd + N'sys.sp_ORAhelpXactSetJob'
	
			EXEC @retcode = @cmd	@publisher,
				@interval = @interval OUTPUT
				
			if @retcode <> 0 or @@error <> 0
				RETURN(1)	
			
			-- Return result set
			select @propertyname as N'propertyname',
				CONVERT(NVARCHAR(20),@interval) as N'propertyvalue'	
				
			RETURN (@retcode)
		END
	
		-- If set, property value must be a number greater than or equal to 0
		SET @interval = CONVERT(int,@propertyvalue)
		IF @interval < 0
		BEGIN
			RAISERROR (21796, 16, -1)
    		RETURN (1)
		END
		
		set @cmd = @cmd + N'sys.sp_ORAXactSetJob'
	
		EXEC @retcode = @cmd	@publisher,
				NULL,
				@interval,
				0,
				@interval,
				0
		RETURN (@retcode)
	
	END

	RETURN (@retcode)
END
GO
GRANT EXECUTE ON [sys].[sp_publisherproperty] TO [public] AS [dbo]
GO
