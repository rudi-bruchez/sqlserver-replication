SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_expired_subscription_cleanup]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_expired_subscription_cleanup] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_expired_subscription_cleanup]
	@publisher [sysname]
WITH EXECUTE AS CALLER
AS
BEGIN
    declare	@retcode			int,
    		@db_name			sysname,
    		@publisher_type		sysname,
			@category			int,
			@proc_name			nvarchar(200),
			@distributor		sysname,
			@distribdb			sysname,
			@distproc			nvarchar(300),
			@IsDistNULL			bit = 0,
			@IsPublished		bit = 0

    -- Security Check is done in called procedures

    -- Get distribution server information for remote RPC call.
    EXEC @retcode = sys.sp_MSrepl_getdistributorinfo @publisher      = @publisher,
    												 @rpcsrvname     = @distributor OUTPUT,
    												 @distribdb      = @distribdb OUTPUT,
    												 @publisher_type = @publisher_type OUTPUT

    IF (@@ERROR != 0 OR @retcode != 0)
    BEGIN
        RETURN (@retcode)
    END

	IF (@distributor IS NULL OR @distribdb IS NULL)
	BEGIN
		SELECT @IsDistNULL = 1
		IF EXISTS (SELECT name FROM sys.databases WHERE sys.fn_MSrepl_ispublished(name) = 1)
		BEGIN
			SELECT @IsPublished = 1
		END
	END

	IF (@publisher_type != N'MSSQLSERVER')
	BEGIN
		-- Heterogeneous publisher subscription cleanup
		IF (@IsDistNULL = 0)
		BEGIN
			SELECT @proc_name = @distribdb + N'.sys.sp_MSdrop_expired_subscription'
			EXEC @retcode = @proc_name	@publisher = @publisher
		END
	END
	ELSE
    BEGIN
    	-- SQL publisher - sweep all the published databases and distribution databases
	    DECLARE DC CURSOR LOCAL FAST_FORWARD for
	    SELECT DISTINCT name, category
	    FROM   master.dbo.sysdatabases 
	    WHERE ((category & 4) = 4
	       OR (category & 1 = 1)
		   OR (category & 16 = 16))
			and databasepropertyex(name, 'Updateability') = 'READ_WRITE'
	       and has_dbaccess(name) = 1
	    FOR READ ONLY
	    
	    OPEN DC
	    FETCH DC INTO @db_name, @category
	    
	    WHILE (@@fetch_status != -1)
	    BEGIN
	    	-- Merge publication db
	        IF (@category & 4 = 4 and @IsDistNULL = 0)
            BEGIN
				SELECT @proc_name = QUOTENAME(RTRIM(@db_name)) + '.sys.sp_MSdrop_expired_mergesubscription'
				EXEC @retcode = @proc_name
                
				IF (@retcode != 0 OR @@ERROR != 0)
				BEGIN
					GOTO DONE
				END
            END

			-- Tran publication db
	        IF (@category & 1 = 1 and @IsDistNULL = 0)
            BEGIN
				SELECT @proc_name = QUOTENAME(RTRIM(@db_name)) + '.sys.sp_MSdrop_expired_subscription'
				EXEC @retcode = @proc_name
                
				IF (@retcode != 0 OR @@ERROR != 0)
				BEGIN
					goto DONE
				END
            END   
			
			--Distribution DB
			IF (@category & 16 = 16 and @IsDistNULL = 0)
            BEGIN
				-- Deactivate any subscriptions which have been inactive beyond the maximum retention
				SELECT @proc_name = QUOTENAME(RTRIM(@db_name)) + '.dbo.sp_MSsubscription_cleanup'
				EXEC @retcode = @proc_name
				IF (@retcode != 0 OR @@ERROR != 0)
				BEGIN
					goto DONE
				END
            END 

			FETCH DC INTO @db_name, @category
	    END

		IF (@IsDistNULL = 1)
		BEGIN
			IF (@IsPublished = 1)
			BEGIN
				RAISERROR (20036, 16, -1)
				SELECT @retcode = 1
				goto DONE
			END
			ELSE
			BEGIN
				SELECT @retcode = 0
				goto DONE
			END
		END
	    --
	    -- sp_MScleanup_agent_entry in distribution database is called to periodically remove obselete
	    -- entries in MSmerge_agents, which may be caused by the following reasons:
	    --  1. publishing database is externally removed; therefore cleanup agent can not do its job
	    --  2. Entries for anonymous merge subscriptions
	    --
	    SELECT @distproc = QUOTENAME(RTRIM(@distributor)) + '.' + QUOTENAME(RTRIM(@distribdb)) + '..sp_MScleanup_agent_entry'
	    EXEC @retcode = @distproc 
	    
	    IF (@@ERROR != 0 OR @retcode != 0)
	    BEGIN
	    	goto DONE
	    END

DONE:
		-- Cursor cleanup
	    CLOSE DC
	    DEALLOCATE DC
	END

	RETURN @retcode
END
GO
GRANT EXECUTE ON [sys].[sp_expired_subscription_cleanup] TO [public] AS [dbo]
GO
