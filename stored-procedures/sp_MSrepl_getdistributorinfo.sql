SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSrepl_getdistributorinfo]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSrepl_getdistributorinfo] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSrepl_getdistributorinfo]
	@distributor [sysname] OUTPUT,
	@distribdb [sysname] OUTPUT,
	@publisher [sysname],
	@local [nvarchar](5),
	@rpcsrvname [sysname] OUTPUT,
	@publisher_type [sysname] OUTPUT,
	@publisher_id [int] OUTPUT,
	@working_directory [nvarchar](255) OUTPUT,
	@version [int] OUTPUT,
	@dist_listener [sysname] OUTPUT,
	@is_DistribDB_in_AG [bit] OUTPUT
WITH EXECUTE AS CALLER
AS
BEGIN
    SET NOCOUNT ON
    DECLARE @loc_distributor sysname,
            @loc_distribdb sysname,
            @loc_rpcsrvname sysname,
            @loc_publishertype sysname,
            @loc_publisherid int,
            @proc nvarchar(255),
            @retcode int,
            @srvid smallint,
            @dist_rpcname sysname,
            @loc_working_directory nvarchar(255),
            @loc_version int,
            @loc_dist_listener sysname = NULL,
            @isDistDBInAGSupported bit = 0,
            @SQLStmt nvarchar(4000),
            @loc_is_DistribDB_in_AG bit = 0,
            @P_distdb sysname,
            @cmd nvarchar(500),
            @ParamDefinition nvarchar(500)

    --
    -- Get the distribution server
    --
    SELECT  @dist_rpcname = name,
                @loc_distributor = upper(data_source collate database_default ),
                @srvid = server_id,
                @loc_rpcsrvname = name
    FROM sys.servers
    WHERE is_distributor = 1
    IF (@loc_distributor is null)
        RETURN (1)
    --
    -- set publisher if necessary
    -- process based on where this is invoked
    --
    SELECT @publisher = case when (@publisher IS NULL) then upper(publishingservername()) else upper(@publisher) end
    
    exec sys.sp_MSget_server_portinfo 
        @name = @publisher, 
        @srvname = @publisher OUTPUT
    
    if @loc_distributor = UPPER(@@servername)
    begin
        --
        -- invoked on distributor
        -- validate the calling publisher
        
		-- Find the distribution DB name for publisher @publisher
        select @P_distdb = distribution_db  from msdb.dbo.MSdistpublishers msd where msd.name = @publisher

		if (@P_distdb is not null)
		BEGIN
			-- Lookup MSreplservers in appropriate distribution db  
			SELECT @proc = QUOTENAME(@P_distdb) + N'.sys.sp_MSgetdistributorinfo'
			EXECUTE @retcode = @proc	@P_publisher  = @publisher,
										@P_loc_distribdb = @loc_distribdb OUTPUT,
										@P_loc_publishertype = @loc_publishertype OUTPUT,
										@P_loc_publisherid	= @loc_publisherid OUTPUT,
										@P_loc_working_directory	= @loc_working_directory OUTPUT,
										@P_loc_version				= @loc_version OUTPUT

			IF (@@ERROR != 0) -- OR @loc_distribdb IS NULL
				RETURN (1)
			IF EXISTS (SELECT * FROM sys.all_parameters WHERE OBJECT_ID = OBJECT_ID('sp_MSrepl_getdistributorinfo') AND [name] = '@dist_listener')
			BEGIN
				IF EXISTS ((SELECT * FROM sys.dm_hadr_database_replica_states WHERE DATABASE_ID = DB_ID(@loc_distribdb))) and serverproperty('EngineEdition') <> 8 -- Check AG DMV when its not Managed Instance
				BEGIN
					SELECT @loc_is_DistribDB_in_AG = 1
					SELECT TOP 1 @loc_dist_listener = dns_name FROM sys.availability_group_listeners AGL
						INNER JOIN sys.dm_hadr_database_replica_states DBRepl ON AGL.group_id = DBRepl.group_id
						WHERE DBRepl.database_id = DB_ID(@loc_distribdb)
				END
			END
		END
    end
    else
    begin
        --
        -- invoked on publisher with remote distributor
        --
		SELECT @proc = @dist_rpcname + '.master.sys.sp_executesql'
		SELECT @SQLStmt = N'if exists (Select * from sys.all_parameters where object_id = OBJECT_ID(''sp_MSrepl_getdistributorinfo'') and [name] = ''@dist_listener'')
				SELECT @isDistDBInAGSupported = 1
			else
				SELECT @isDistDBInAGSupported = 0'
		EXECUTE @retcode = @proc 
			@stmt = @SQLStmt, 
			@params = N'@isDistDBInAGSupported bit OUTPUT', 
			@isDistDBInAGSupported = @isDistDBInAGSupported OUTPUT

		IF @retcode <> 0 or @@ERROR <> 0
			RETURN (1)

        SELECT @proc = @dist_rpcname + N'.master.sys.sp_MSrepl_getdistributorinfo'
		if (@isDistDBInAGSupported = 1)
		BEGIN
			EXECUTE @retcode = @proc @distributor  = @loc_distributor OUTPUT, 
									 @distribdb      = @loc_distribdb OUTPUT, 
									 @publisher      = @publisher,
									 @local          = @local,
									 @publisher_type = @loc_publishertype OUTPUT,
									 @publisher_id   = @loc_publisherid OUTPUT,
									 @working_directory = @loc_working_directory OUTPUT,
									 @version = @loc_version OUTPUT,
									 @dist_listener = @loc_dist_listener OUTPUT,
									 @is_DistribDB_in_AG = @loc_is_DistribDB_in_AG OUTPUT
		END
		ELSE
		BEGIN
			EXECUTE @retcode = @proc @distributor  = @loc_distributor OUTPUT, 
				                     @distribdb      = @loc_distribdb OUTPUT, 
					                 @publisher      = @publisher,
						             @local          = @local,
							         @publisher_type = @loc_publishertype OUTPUT,
								     @publisher_id   = @loc_publisherid OUTPUT,
									 @working_directory = @loc_working_directory OUTPUT,
									 @version = @loc_version OUTPUT
		END
        IF @retcode <> 0 or @@ERROR <> 0
        RETURN (1)
    end
    --
    -- Return output parameters
    -- NOTE: For HREPL, treat the RPC name as the same as the distributor name
    -- to avoid using RPC calls for HREPL since all HREPL is local
    --
    SELECT  @distributor = @loc_distributor,
                @distribdb = @loc_distribdb,
                @publisher_type = @loc_publishertype,
                @publisher_id = @loc_publisherid,
                @working_directory = @loc_working_directory,
                @version = @loc_version,
                -- Remote distributor or local with non-sysadmin rights
                @rpcsrvname = @loc_rpcsrvname,
				@dist_listener = @loc_dist_listener,
				@is_DistribDB_in_AG = @loc_is_DistribDB_in_AG
    --
    -- BUGBUG : The value for @rpcsrvname must match the value returned
    --  by sp_helpdistributor or we will see indefinite blocking  
    --  in some areas of our code. Example-incremental add article.
    --  So if you make a change here make it in sp_helpdistributor
    --
    -- For the following cases use LOCAL SERVER NAME
    --  1. Hetero will always use local server
    --  2. Local distributor with sysadmin access (used to avoid blocking issues)
    --
    if (@loc_publishertype != N'MSSQLSERVER' 
        OR (IS_SRVROLEMEMBER('sysadmin') = 1 
            AND @loc_distributor = UPPER(@@SERVERNAME)))
    begin
        select @rpcsrvname = name
        from sys.servers
        where UPPER(name collate database_default ) = @loc_distributor
    end
    -- all done
    return 0
END
GO
GRANT EXECUTE ON [sys].[sp_MSrepl_getdistributorinfo] TO [public] AS [dbo]
GO
