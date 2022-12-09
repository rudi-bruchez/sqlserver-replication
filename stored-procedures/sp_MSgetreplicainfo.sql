SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSgetreplicainfo]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSgetreplicainfo] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSgetreplicainfo]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@datasource_type [int],
	@server_name [sysname],
	@db_name [sysname],
	@datasource_path [nvarchar](255),
	@compatlevel [int]
WITH EXECUTE AS CALLER
AS
declare    @retcode           int
    declare    @repid             uniqueidentifier
    declare    @pubid             uniqueidentifier
    declare    @schemaguid        uniqueidentifier
    declare    @replnick          binary(6)
    declare    @subscription_type int
    declare    @validation_level  int
    declare    @reptype           int
    declare    @priority          real 
    declare    @schversion        int 
    declare    @status            int
    declare    @resync_gen        bigint
    declare    @replicastate      uniqueidentifier
    declare    @sync_type         tinyint
    declare    @description       nvarchar(255)
    declare    @dynamic_snapshot_received int
    declare    @distributor       sysname
    declare    @dometadata_cleanup int
    declare    @REPLICA_STATUS_Deleted tinyint
    declare    @REPLICA_STATUS_BeforeRestore tinyint
    declare    @REPLICA_STATUS_AttachFailed tinyint
    declare    @retention_period_unit tinyint
    declare    @islocalpubid bit, @islocalsubid bit, @cleanedup_unsent_changes bit
    declare    @last_sync_time datetime, @num_time_units_since_last_sync int
    declare    @supportability_mode int

    select @publisher_db = RTRIM(@publisher_db)
    select @db_name = RTRIM(@db_name)
    
    /* 
    ** Security Check and publication validation
    */
    exec @retcode = sys.sp_MSmerge_validate_publication_presence @publication, @publisher_db, @publisher, @pubid output
    if @retcode <> 0 or @@error <> 0
        return 1

    set @REPLICA_STATUS_Deleted= 2
    set @REPLICA_STATUS_BeforeRestore= 7
    set @REPLICA_STATUS_AttachFailed= 6

    if (@server_name is NULL)
        SET @server_name = publishingservername()

    exec sys.sp_MSget_server_portinfo 
        @name = @server_name, 
        @srvname = @server_name OUTPUT

    if (@db_name is NULL)
        set @db_name = db_name()

    select @retention_period_unit = retention_period_unit from dbo.sysmergepublications
    where pubid = @pubid

    SELECT @repid = subid, @replnick = replnickname, @priority = priority, @reptype = subscriber_type, 
        @subscription_type = subscription_type , @status = status, @replicastate = replicastate, 
        @schversion = schemaversion, @schemaguid = schemaguid,
        @sync_type = sync_type, @description = description, @priority = priority,
        @dometadata_cleanup = case when sys.fn_add_units_to_date(-1, @retention_period_unit, getdate()) > metadatacleanuptime then 1
                                    else 0
                              end,
        @last_sync_time = last_sync_date,
        @supportability_mode = supportability_mode
        FROM dbo.sysmergesubscriptions
        WHERE UPPER(subscriber_server) collate database_default = UPPER(@server_name) collate database_default 
            and db_name = @db_name and pubid = @pubid 
            and status <> @REPLICA_STATUS_Deleted 
            and status <> @REPLICA_STATUS_BeforeRestore
            and status <> @REPLICA_STATUS_AttachFailed
    if @repid is NULL
    begin
        RAISERROR(20021, 16, -1)
        return (1)
    end

    select @validation_level=validation_level, @resync_gen=resync_gen 
    from dbo.MSmerge_replinfo 
    where repid = @repid

    -- the following columns are no longer used but are being returned for backward compatibility
    select @distributor = NULL
    select @publication = NULL
    -- only return publication and distributor information if this is the loop back 
    -- subscription information of a publication
    if @repid = @pubid
    begin
        select @publication = name, @distributor = distributor from dbo.sysmergepublications 
            where pubid = @pubid
    end
    
    select @num_time_units_since_last_sync = sys.fn_datediff_units(@retention_period_unit, getdate(), @last_sync_time)

    -- update the application name that we have stored to reflect the current connection's program name
    -- this is needed here because for anonymous subscribers the program name is a guid which is different
    -- every time the merge runs
    if @repid <> @pubid
    begin
        update s 
        set s.application_name = p.program_name 
        from sys.dm_exec_sessions p, dbo.sysmergesubscriptions s where p.session_id = @@spid and s.subid = @repid
        if @@error<>0
            return 1
    end

    if @compatlevel >= 90
    begin
        select @islocalpubid = sys.fn_MSmerge_islocalpubid(@pubid), 
            @islocalsubid = sys.fn_MSmerge_islocalsubid(@repid),
            @cleanedup_unsent_changes = 0
            
        if @islocalsubid = 0
            -- called on subscriber for publisher's replica info
            -- or called on publisher for subscriber's replica info
            select @cleanedup_unsent_changes = cleanedup_unsent_changes
            from dbo.sysmergesubscriptions
            where subid = @repid    -- right replica row
        else 
        begin
            if @islocalpubid = 0
                -- called on subscriber for subscriber's replica info
                select @cleanedup_unsent_changes = cleanedup_unsent_changes
                from dbo.sysmergesubscriptions
                where pubid = @pubid
                and subid = @pubid    -- we are interested in the cleanedup_unsent_changes bit from the publisher replica row
            else
                -- called on publisher for publisher's replica info
                select @cleanedup_unsent_changes = 0 -- no way to tell which subscriber we are syncing with
        end
        
        select @repid, @replnick,
               @reptype, @subscription_type, @priority, @schversion, @schemaguid, @status, @replicastate, 
               @sync_type, @description, @publication, @distributor, @validation_level, @resync_gen, @dometadata_cleanup, 
               @pubid, @cleanedup_unsent_changes, @num_time_units_since_last_sync, @supportability_mode
    end
    else
    begin
        select @repid, {fn REPLNICK_90_TO_80(@replnick)},
               @reptype, @subscription_type, @priority, @schversion, @schemaguid, @status, @pubid, 
               @sync_type, @description, @publication, @distributor, @validation_level, @resync_gen, @dometadata_cleanup

    end

    return (0)
GO
GRANT EXECUTE ON [sys].[sp_MSgetreplicainfo] TO [public] AS [dbo]
GO
