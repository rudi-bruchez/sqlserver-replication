SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_changemergepublication]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_changemergepublication] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_changemergepublication]
	@publication [sysname],
	@property [sysname],
	@value [nvarchar](255),
	@force_invalidate_snapshot [bit],
	@force_reinit_subscription [bit]
WITH EXECUTE AS CALLER
AS
SET NOCOUNT ON

    /*
    ** Declarations.
    */
    declare @max_concurrent_merge   int
    declare @cmd                nvarchar(255)
    declare @pubid              uniqueidentifier
    declare @pubidstr           nvarchar(38)
    declare @retcode            int
    declare @statusid           tinyint
    declare @sync_modeid        tinyint
    declare @distributor        sysname
    declare @distproc           nvarchar(300)
    declare @value_bit          bit
    declare @snapshot_ready     tinyint
    declare @subscribed         int
    declare @dbname             sysname
    declare @distribdb          sysname
    declare @alt_snapshot_folder nvarchar(255)
    declare @enabled_for_internet bit
    declare @ftp_address        sysname
    declare @enc_ftp_password   nvarchar(524)
    declare @snapshot_in_defaultfolder bit
    declare @dynamic_filters_id int
    declare @schemaversion      int 
    declare @schemaguid         uniqueidentifier
    declare @schematype         int
    declare @schematext         nvarchar(2000)
    declare @artid              uniqueidentifier
    declare @in_ActiveD         bit
    declare @ad_guidname        sysname
    declare @db_name            sysname
    declare @compress_snapshot  bit
    declare @numeric_value      int
    declare @dynamic_filters    bit
    declare @publication_number smallint
    declare @REPOLEVersion_70RTM        int
    declare @REPOLEVersion_70SP1        int
    declare @REPOLEVersion_70SP2        int
    declare @REPOLEVersion_80RTM        int
    declare @REPOLEVersion_90           int
    declare @REPOLEVersion_100           int    

    declare @REPOLEVersion_70RTM_string     nvarchar(5)
    declare @REPOLEVersion_70SP1_string     nvarchar(5)
    declare @REPOLEVersion_70SP2_string     nvarchar(5)
    declare @REPOLEVersion_70SP3_string     nvarchar(5)
    declare @REPOLEVersion_70SP4_string     nvarchar(5)
    declare @REPOLEVersion_80RTM_string     nvarchar(5)
    declare @REPOLEVersion_80SP1_string     nvarchar(5)
    declare @REPOLEVersion_80SP2_string     nvarchar(5)
    declare @REPOLEVersion_80SP3_string     nvarchar(5)
    declare @REPOLEVersion_90RTM_string     nvarchar(5)
    declare @REPOLEVersion_100RTM_string   nvarchar(6)    

    declare @compatlevel int
    declare @SCHEMA_TYPE_DROPARTICLE int
    declare @SCHEMA_TYPE_RETENTIONCHANGE int
    declare @SCHEMA_TYPE_RETENTIONUNITCHANGE int
    declare @SCHEMA_TYPE_BACKWARD_COMPAT_LEVEL int
    declare @SCHEMA_TYPE_VALIDATE_SUBSCRIBERINFO int
    declare @SCHEMA_TYPE_CHANGE_MERGE_PUBLICATION_90RTM int
    declare @previousnumericvalue       int
    declare @previousbitvalue           bit
    declare @eventtype                  tinyint
    declare @retention_period_unit  tinyint
    declare @retention              int 
    declare @buildnumber nvarchar(128)
    declare @upload_options tinyint
    declare @automatic_reinitialization_policy bit
    			,@publishingservername sysname
    declare @got_merge_admin_applock bit

    select @got_merge_admin_applock = 0

    set @property= LOWER(@property collate SQL_Latin1_General_CP1_CS_AS)
    
    select @subscribed = 1
    select @snapshot_ready = 1
    select @db_name=db_name()
    		,@publishingservername = publishingservername()

    set @REPOLEVersion_70RTM= 10
    set @REPOLEVersion_70SP1= 20
    set @REPOLEVersion_70SP2= 30
    set @REPOLEVersion_80RTM= 40
    set @REPOLEVersion_90= 90
    set @REPOLEVersion_100=100

    set @REPOLEVersion_70RTM_string = N'70RTM'
    set @REPOLEVersion_70SP1_string = N'70SP1'
    set @REPOLEVersion_70SP2_string = N'70SP2'
    set @REPOLEVersion_70SP3_string = N'70SP3'
    set @REPOLEVersion_70SP4_string = N'70SP4'
    set @REPOLEVersion_80RTM_string = N'80RTM'
    set @REPOLEVersion_80SP1_string = N'80SP1'
    set @REPOLEVersion_80SP2_string = N'80SP2'
    set @REPOLEVersion_80SP3_string = N'80SP3'
    set @REPOLEVersion_90RTM_string = N'90RTM'
    set @REPOLEVersion_100RTM_string = N'100RTM'

    set @SCHEMA_TYPE_RETENTIONCHANGE= 9
    set @SCHEMA_TYPE_BACKWARD_COMPAT_LEVEL= 18
    set @SCHEMA_TYPE_VALIDATE_SUBSCRIBERINFO= 19
    set @SCHEMA_TYPE_RETENTIONUNITCHANGE = 29
    set @SCHEMA_TYPE_DROPARTICLE = 28
    set @SCHEMA_TYPE_CHANGE_MERGE_PUBLICATION_90RTM = 302

    -- Security Check
    EXEC @retcode = sys.sp_MSreplcheck_publish
    IF @@ERROR <> 0 or @retcode <> 0
        return (1)

    -- make sure current database is enabled for merge replication
    exec @retcode=sys.sp_MSCheckmergereplication
    if @@ERROR<>0 or @retcode<>0
        return (1)
            
    -- build table for subsequent checks of @property parameter
    CREATE TABLE #tab1 (property sysname collate database_default, allownull bit default(0))
    INSERT INTO #tab1 (property,allownull) VALUES ('description',1)
    INSERT INTO #tab1 (property) VALUES ('status')
    INSERT INTO #tab1 (property) VALUES ('retention')
    INSERT INTO #tab1 (property) VALUES ('retention_period_unit')
    INSERT INTO #tab1 (property) VALUES ('sync_mode')
    INSERT INTO #tab1 (property) VALUES ('allow_push')
    INSERT INTO #tab1 (property) VALUES ('allow_pull')
    INSERT INTO #tab1 (property) VALUES ('allow_anonymous')
    INSERT INTO #tab1 (property) VALUES ('enabled_for_internet')
    INSERT INTO #tab1 (property) VALUES ('centralized_conflicts')
    INSERT INTO #tab1 (property) VALUES ('conflict_logging')
    INSERT INTO #tab1 (property) VALUES ('snapshot_ready')
    INSERT INTO #tab1 (property) VALUES ('snapshot_in_defaultfolder')
    INSERT INTO #tab1 (property,allownull) VALUES ('alt_snapshot_folder',1)
    INSERT INTO #tab1 (property,allownull) VALUES ('pre_snapshot_script',1)
    INSERT INTO #tab1 (property,allownull) VALUES ('post_snapshot_script',1)
    INSERT INTO #tab1 (property) VALUES ('compress_snapshot')
    INSERT INTO #tab1 (property,allownull) VALUES ('ftp_address',1)
    INSERT INTO #tab1 (property) VALUES ('ftp_port')
    INSERT INTO #tab1 (property,allownull) VALUES ('ftp_subdirectory',1)
    INSERT INTO #tab1 (property,allownull) VALUES ('ftp_login',1)
    INSERT INTO #tab1 (property,allownull) VALUES ('ftp_password',1)
    INSERT INTO #tab1 (property) VALUES ('conflict_retention')
    INSERT INTO #tab1 (property) VALUES ('allow_subscription_copy')
    INSERT INTO #tab1 (property) VALUES ('allow_synctoalternate')
    INSERT INTO #tab1 (property) VALUES ('validate_subscriber_info')
    INSERT INTO #tab1 (property) VALUES ('publish_to_ActiveDirectory')
    INSERT INTO #tab1 (property) VALUES ('dynamic_filters')
    INSERT INTO #tab1 (property,allownull) VALUES ('max_concurrent_merge',1)
    INSERT INTO #tab1 (property) VALUES ('max_concurrent_dynamic_snapshots')
    INSERT INTO #tab1 (property,allownull) VALUES ('publication_compatibility_level',1)
    INSERT INTO #tab1 (property) VALUES ('use_partition_groups')
    INSERT INTO #tab1 (property) VALUES ('allow_subscriber_initiated_snapshot')
    INSERT INTO #tab1 (property) VALUES ('keep_partition_changes')
    INSERT INTO #tab1 (property) VALUES ('replicate_ddl')
    INSERT INTO #tab1 (property) VALUES ('allow_web_synchronization')
    INSERT INTO #tab1 (property) VALUES ('web_synchronization_url')
    INSERT INTO #tab1 (property) VALUES ('allow_partition_realignment')
    INSERT INTO #tab1 (property) VALUES ('generation_leveling_threshold')
    INSERT INTO #tab1 (property) VALUES ('automatic_reinitialization_policy')
    
    /*
    ** Parameter Check:  @property.
    ** If the @property parameter is NULL, print the options.
    */
    if @property IS NULL
    BEGIN
        select property FROM #tab1 order by property
        RETURN (0)
    END

    if @value is NULL and @property in (select property from #tab1 where allownull=0)
    begin
        RAISERROR (20081, 16, -1, @property)
        RETURN (1)
    end

    /*
    ** Parameter Check:  @publication.
    ** Make sure that the publication exists.
    */

    if @publication IS NULL
    BEGIN
        RAISERROR (14043, 16, -1, '@publication', 'sp_changemergepublication')
        RETURN (1)
    END

    select @pubid = pubid, 
           @ad_guidname=ad_guidname, --with value NULL if this publication is not in AD.
           @snapshot_ready=snapshot_ready,
           @dynamic_filters_id=dynamic_filters,
           @sync_modeid = sync_mode, 
           @alt_snapshot_folder = alt_snapshot_folder,
           @enabled_for_internet = enabled_for_internet,
           @ftp_address = ftp_address,
           @snapshot_in_defaultfolder = snapshot_in_defaultfolder,
           @compress_snapshot = compress_snapshot,
           @in_ActiveD = case when ad_guidname is NULL then 0 else 1 end,
           @compatlevel = backward_comp_level,
           @retention = retention,
           @retention_period_unit = retention_period_unit,
           @automatic_reinitialization_policy = automatic_reinitialization_policy
      FROM dbo.sysmergepublications 
     WHERE name = @publication  and UPPER(publisher)=UPPER(publishingservername()) and publisher_db=db_name()
    set @pubidstr = '''' + convert(nchar(36), @pubid) + ''''

    if @pubid IS NULL
        BEGIN
            RAISERROR (20026, 16, -1, @publication)
            RETURN (1)
        END
    else

    /*
    ** Parameter Check:  @property.
    ** Check to make sure that @property is a valid property in
    ** dbo.sysmergepublications.
    */
    if @property NOT IN (select property from #tab1)
    BEGIN
        RAISERROR (21053, 16, -1, @property)
        RETURN (1)
    END
    
    /*
    ** Parameter Check:
    ** If sync_method of the publication is character mode (an indication that it supports
    ** third party Subscribers), pre/post-snapshot setting must be null   
    **
    */
    IF @sync_modeid = 1 
    BEGIN
        IF (@property = 'pre_snapshot_script' OR @property = 'post_snapshot_script') 
            AND
            @value IS NOT NULL 
            AND 
            @value <> ''
        BEGIN
            RAISERROR (21151, 16, -1)
            RETURN (1)
        END   
    END

    /*
    ** Parameter Check:
    ** If the Publication's alt_snapshot_folder setting is null 
    ** snapshot compression cannot be enabled
    */
    IF ((@alt_snapshot_folder IS NULL OR @alt_snapshot_folder = '')) 
        AND @property = 'compress_snapshot'
        AND LOWER(@value collate SQL_Latin1_General_CP1_CS_AS) = 'true'   
    BEGIN
        RAISERROR (21157, 16, -1)        
        RETURN (1)
    END

    /* 
    ** Parameter Check:
    ** If enabled_for_internet is set to true, the publication must have a non-null
    ** ftp_address.
    */
    IF @property = N'enabled_for_internet' AND
       LOWER(@value collate SQL_Latin1_General_CP1_CS_AS) = N'true' AND 
       (@ftp_address IS NULL OR @ftp_address = N'')
    BEGIN
        RAISERROR(21158, 16, -1)
        RETURN (1)
    END

    /*
    ** .. and ftp_address cannot be null if the publication is enabled for 
    ** internet.
    */
/*
    IF @enabled_for_internet = 1 AND
      (@property = N'ftp_address'
        AND (@value IS NULL OR @value = N''))
    BEGIN
        RAISERROR(21158, 16, -1)
        RETURN (1)
    END
*/

/*
    IF @enabled_for_internet = 1 AND
       (@property = N'alt_snapshot_folder' AND
        (LOWER(@value collate SQL_Latin1_General_CP1_CS_AS) IS NULL OR LOWER(@value collate SQL_Latin1_General_CP1_CS_AS) = N''))
    BEGIN
        RAISERROR(21159, 16, -1)
        RETURN (1)
    END  
*/


    /*
    ** Parameter Check:
    ** 'ftp_port' cannot be null or negative
    */
    IF @property = N'ftp_port' AND (@value IS NULL OR CONVERT(int, @value) < 0 OR CONVERT(int, @value) > 65535)
    BEGIN
        RAISERROR (21160, 16, -1)
        RETURN (1)
    END

    BEGIN TRAN changemergepublication    
    save tran changemergepublication

    exec @retcode = sys.sp_MSgetmergeadminapplock @timeout = 0, -- no wait
                                                  @lockowner = N'Transaction'
    if @retcode<>0 or @@error<>0
    begin
        raiserror(20713, 16, -1, 'sp_changemergepublication', @publication)
        goto UNDO
    end

    select @got_merge_admin_applock = 1

    /*
    ** Changing of the following properties would require a snapshot rerun, if snapshot is ready
    */
    if (@property like 'ftp%' OR @property in ('sync_mode', 'snapshot_in_defaultfolder',
            'alt_snapshot_folder', 'pre_snapshot_script', 'post_snapshot_script','compress_snapshot','keep_partition_changes',
            'use_partition_groups', 'publication_compatibility_level'))
    and @snapshot_ready = 1
    begin
        if @force_invalidate_snapshot = 0 and @snapshot_ready = 1
        begin
            raiserror(20607, 16, -1)
            goto UNDO
        end
        update dbo.sysmergepublications set snapshot_ready=2 where pubid=@pubid and snapshot_ready=1
        if @@ERROR<>0   GOTO UNDO
    end
    
    -- Parameter check: @publication_compatibility_level
    if @property = N'publication_compatibility_level'
    begin
        declare @pubcompat_level_id int
        declare @effectivecomplevel int
        declare @feature nvarchar(4000)

        if UPPER(@value collate SQL_Latin1_General_CP1_CS_AS) = @REPOLEVersion_70RTM_string
        begin
            select @pubcompat_level_id = @REPOLEVersion_70RTM
        end
        else if UPPER(@value collate SQL_Latin1_General_CP1_CS_AS) = @REPOLEVersion_70SP1_string
        begin
            select @pubcompat_level_id = @REPOLEVersion_70SP1
        end
        else if UPPER(@value collate SQL_Latin1_General_CP1_CS_AS) = @REPOLEVersion_70SP2_string
        begin
            select @pubcompat_level_id = @REPOLEVersion_70SP2
        end
        else if UPPER(@value collate SQL_Latin1_General_CP1_CS_AS) = @REPOLEVersion_70SP3_string
        begin
            select @pubcompat_level_id = @REPOLEVersion_70SP2
        end
        else if UPPER(@value collate SQL_Latin1_General_CP1_CS_AS) = @REPOLEVersion_70SP4_string
        begin
            select @pubcompat_level_id = @REPOLEVersion_70SP2
        end
        else if UPPER(@value collate SQL_Latin1_General_CP1_CS_AS) = @REPOLEVersion_80RTM_string
        begin
            select @pubcompat_level_id = @REPOLEVersion_80RTM
        end
        else if UPPER(@value collate SQL_Latin1_General_CP1_CS_AS) = @REPOLEVersion_80SP1_string
        begin
            select @pubcompat_level_id = @REPOLEVersion_80RTM
        end
        else if UPPER(@value collate SQL_Latin1_General_CP1_CS_AS) = @REPOLEVersion_80SP2_string
        begin
            select @pubcompat_level_id = @REPOLEVersion_80RTM
        end
        else if UPPER(@value collate SQL_Latin1_General_CP1_CS_AS) = @REPOLEVersion_80SP3_string
        begin
            select @pubcompat_level_id = @REPOLEVersion_80RTM
        end
        else if UPPER(@value collate SQL_Latin1_General_CP1_CS_AS) = @REPOLEVersion_90RTM_string
        begin
            select @pubcompat_level_id = @REPOLEVersion_90
        end
        else if UPPER(@value collate SQL_Latin1_General_CP1_CS_AS) = @REPOLEVersion_100RTM_string
        begin
            select @pubcompat_level_id = @REPOLEVersion_100
        end        
        else 
        begin
            raiserror(21402, 16, -1, '@publication_compatibility_level')
            goto UNDO
        end

        if @@error<> 0 or @pubcompat_level_id not in
            (
                @REPOLEVersion_70RTM,
                @REPOLEVersion_70SP1,
                @REPOLEVersion_70SP2,
                @REPOLEVersion_80RTM,
                @REPOLEVersion_90,
                @REPOLEVersion_100                
            )
        begin
            raiserror(21402, 16, -1, '@publication_compatibility_level')
            goto UNDO
        end
        
        /* Get the previous value */
        select @previousnumericvalue = backward_comp_level from  dbo.sysmergepublications 
        WHERE pubid = @pubid
        
        if @previousnumericvalue > @pubcompat_level_id
        begin
            raiserror(22562, 16, -1)
            goto UNDO
        end

        exec @retcode = sys.sp_MSget_effective_pub_compat_level @pubid, @effectivecomplevel output, @feature output, @buildnumber output
        if @retcode <>0 or @@error <> 0
        begin
            raiserror(21402, 16, -1, '@publication_compatibility_level')
            goto UNDO
        end

        if @buildnumber is not null and
           @pubcompat_level_id = @effectivecomplevel
        begin
            raiserror(20004, 10, -1, @publication, @feature, @buildnumber)
        end
            
        if @pubcompat_level_id < @effectivecomplevel
        begin
            raiserror(20651, 16, -1, @publication, @feature, @effectivecomplevel)
            goto UNDO
        end

        UPDATE dbo.sysmergepublications  SET backward_comp_level = @pubcompat_level_id WHERE pubid = @pubid 
        if @@ERROR <> 0 
            GOTO UNDO

        /*  Insert event in the MSmerge_settingshistory table if the
        new value is different from the old value
        Look in replsys.sql where the table is created for more
        details about what is in this table. */
        
        if (@previousnumericvalue <> @pubcompat_level_id)
        begin
            select @eventtype       = 2 -- Change in publication level property
            
            insert into dbo.MSmerge_settingshistory (eventtime,pubid,artid,eventtype,propertyname,previousvalue,newvalue,eventtext)
            values (default,@pubid,NULL,@eventtype,@property,@previousnumericvalue,@pubcompat_level_id,NULL)
        end

        select @schemaversion = schemaversion from dbo.sysmergeschemachange
        if (@schemaversion is NULL)
            set @schemaversion = 1
        else
            select @schemaversion = 1 + max(schemaversion) from dbo.sysmergeschemachange
            
        set @schemaguid = newid()
        set @artid = null
        set @schematype= @SCHEMA_TYPE_BACKWARD_COMPAT_LEVEL
        select @schematext = 'update dbo.sysmergepublications set backward_comp_level=' + cast(@pubcompat_level_id as nvarchar(5)) + ' where pubid=''' + cast(@pubid as nchar(36)) + ''''     
        exec @retcode=sys.sp_MSinsertschemachange @pubid, @artid, @schemaversion, @schemaguid, @schematype, @schematext
        if @@ERROR<>0 or @retcode<>0 goto UNDO    
    end


    if @property='dynamic_filters' 
    begin
        if LOWER(@value collate SQL_Latin1_General_CP1_CS_AS) = 'true' 
            select @dynamic_filters_id = 1
        else if LOWER(@value collate SQL_Latin1_General_CP1_CS_AS) = 'false' 
            select @dynamic_filters_id = 0
            else
            begin
                raiserror(14137, 16, -1)
                goto UNDO
            end

        declare @previousDynFiltBit int
        select @previousDynFiltBit = dynamic_filters from dbo.sysmergepublications where pubid = @pubid

        if @snapshot_ready>0
        begin
            if @force_invalidate_snapshot = 0 and @snapshot_ready = 1
            begin
                raiserror(20607, 16, -1)
                goto UNDO
            end
            if @force_reinit_subscription = 0
            begin
                raiserror(20608, 16, -1)
                goto UNDO
            end

            -- we should also delete all existing schemachanges for this publication in sysmergeschemachange
            -- this is in order to avoid a number of the problems we have been having with schema processing
            delete from dbo.sysmergeschemachange where pubid = @pubid and schematype not in (@SCHEMA_TYPE_DROPARTICLE)

            update dbo.sysmergepublications set dynamic_filters=@dynamic_filters_id, snapshot_ready=2 where pubid=@pubid
            if @@ERROR<>0
                goto UNDO
            exec @retcode = sys.sp_MSreinitmergepublication 
                                    @publication = @publication,
                                    @upload_first = @automatic_reinitialization_policy
            if @retcode<>0 or @@ERROR<>0
                goto UNDO
        end
        else
        begin
            update dbo.sysmergepublications set dynamic_filters=@dynamic_filters_id where pubid=@pubid
            if @@ERROR<>0
                goto UNDO       
        end

        -- Insert event into MSmerge_settingshistory
        if (@previousDynFiltBit <> @dynamic_filters_id)
        begin
            select @eventtype       = 2 -- Change in publication level property
    
            insert into dbo.MSmerge_settingshistory (eventtime,pubid,artid,eventtype,propertyname,previousvalue,newvalue,eventtext)
            values (default,@pubid,NULL,@eventtype,@property,@previousDynFiltBit,@dynamic_filters_id,NULL)
        end
    end
    
    if @property='validate_subscriber_info'
    begin
        if @value is not NULL
        begin
            if @dynamic_filters_id = 0
            begin
                raiserror(21313, 16, -1)
                GOTO UNDO
            end
            if exists (select * from dbo.sysmergesubscriptions where pubid=@pubid and subid<>@pubid and status<>0)
            begin
                if @force_reinit_subscription = 0
                begin
                    raiserror(20643, 16, -1, @publication)
                    GOTO UNDO
                end
                else
                begin
                    exec @retcode = sys.sp_MSreinitmergepublication 
                                            @publication = @publication,
                                            @upload_first = @automatic_reinitialization_policy
                    if @retcode<>0 or @@ERROR<>0 goto UNDO
                end
            end 
        end
        
        declare @previousValSubInfo nvarchar(500)
        SELECT @previousValSubInfo = validate_subscriber_info from dbo.sysmergepublications WHERE pubid = @pubid

        UPDATE dbo.sysmergepublications  SET validate_subscriber_info = @value WHERE pubid = @pubid
        if @@ERROR <> 0 GOTO UNDO

        -- Although a reinit will occur, we add the schemachange so that we can tell
        -- SSCE about the publication property being changed.
        select @schemaversion = schemaversion from dbo.sysmergeschemachange
        if (@schemaversion is NULL)
            set @schemaversion = 1
        else
            select @schemaversion = 1 + max(schemaversion) from dbo.sysmergeschemachange
            
        set @schemaguid = newid()
        set @artid = null
        set @schematype= @SCHEMA_TYPE_VALIDATE_SUBSCRIBERINFO
        select @schematext = 'update dbo.sysmergepublications set validate_subscriber_info=''' + replace(@value, '''', '''''') + ''' where pubid=''' + cast(@pubid as nchar(36)) + ''''      
        exec @retcode=sys.sp_MSinsertschemachange @pubid, @artid, @schemaversion, @schemaguid, @schematype, @schematext
        if @@ERROR<>0 or @retcode<>0 goto UNDO    

        -- Insert event into MSmerge_settingshistory
        if (@previousValSubInfo <> @value)
        begin
            select @eventtype       = 2 -- Change in publication level property
    
            insert into dbo.MSmerge_settingshistory (eventtime,pubid,artid,eventtype,propertyname,previousvalue,newvalue,eventtext)
            values (default,@pubid,NULL,@eventtype,@property,@previousValSubInfo,@value,NULL)
        end

    end

  
    if @property IN ('description')
        BEGIN
            declare @previousDesc nvarchar(255)            
            SELECT @previousDesc = description FROM dbo.sysmergepublications WHERE pubid = @pubid
            UPDATE dbo.sysmergepublications  SET description = @value WHERE pubid = @pubid
            if @@ERROR <> 0 GOTO UNDO

            -- Insert event into MSmerge_settingshistory
            if (@previousDesc <> @value)
            begin
                select @eventtype       = 2 -- Change in publication level property

                insert into dbo.MSmerge_settingshistory (eventtime,pubid,artid,eventtype,propertyname,previousvalue,newvalue,eventtext)
                values (default,@pubid,NULL,@eventtype,@property,@previousDesc,@value,NULL)
            end

        END

  
    if @property = 'status'
    BEGIN

        /*
        ** Check to make sure that we have a valid status.
        */

        if LOWER(@value collate SQL_Latin1_General_CP1_CS_AS) NOT IN ('active', 'inactive')
            BEGIN
                RAISERROR (14012, 16, -1)
                GOTO UNDO
            END

        /*
        ** Determine the integer value for the status.
        */

        if LOWER(@value collate SQL_Latin1_General_CP1_CS_AS) = 'active'
            select @statusid = 1
        else
            select @statusid = 0
            
            
		-- if the status is being set to 1, then get the publication ready enough to be able to add merge partitions irrespective of whether
		-- or not the snapshot has been run.
		if @statusid = 1
		begin
			exec @retcode = sys.sp_MSpublicationview @publication
			if @@error <> 0 or @retcode <> 0 goto UNDO
			
			exec @retcode = sys.sp_MSset_dynamic_filter_options @publication
			if @@error <> 0 goto UNDO
			
			if exists (select * from dbo.sysmergepublications where pubid = @pubid and use_partition_groups = 2)
			begin
				exec @retcode = sys.sp_MSsetup_use_partition_groups @publication
				if @@error <> 0 goto UNDO
			end
		end
		
        /*
        ** Update the publication with the new status.
        */
        declare @previousStatus tinyint
        SELECT @previousStatus = status FROM dbo.sysmergepublications WHERE pubid = @pubid
        UPDATE dbo.sysmergepublications SET status = @statusid WHERE pubid = @pubid

        if @@ERROR <> 0 GOTO UNDO

        -- Insert event into MSmerge_settingshistory
        if (@previousStatus <> @statusid)
        begin
            select @eventtype       = 2 -- Change in publication level property
 
            insert into dbo.MSmerge_settingshistory (eventtime,pubid,artid,eventtype,propertyname,previousvalue,newvalue,eventtext)
            values (default,@pubid,NULL,@eventtype,@property,@previousStatus,@statusid,NULL)
        end

    END


    if @property = 'retention'
    BEGIN
        /*
        ** Update the publication with the new replication frequency.
        */

        select @retention = CONVERT(int, @value)
        if @@error <>0 goto UNDO

        if @retention is NULL
        begin
            select @retention = 0
        end
        else if @retention < 0 or @retention > sys.fn_units_until_maxdate(@retention_period_unit, getdate())
        begin
            raiserror(20050, 16, -1, 0)
            GOTO UNDO
        end

        declare @oldRetentionValue int
        SELECT @oldRetentionValue = retention from dbo.sysmergepublications WHERE pubid = @pubid

        UPDATE dbo.sysmergepublications set retention = @retention WHERE pubid = @pubid
        if @@ERROR <> 0 
            GOTO UNDO

        select @schemaversion = schemaversion from dbo.sysmergeschemachange
        if (@schemaversion is NULL)
            set @schemaversion = 1
        else
            select @schemaversion = 1 + max(schemaversion) from dbo.sysmergeschemachange
            
        set @schemaguid = newid()
        set @artid = null
        set @schematype = @SCHEMA_TYPE_RETENTIONCHANGE
        select @schematext = 'exec dbo.sp_MSchange_retention '+ '''' + convert(nchar(36),@pubid) + '''' + ',' + '''' + @value + ''''          
        exec @retcode=sys.sp_MSinsertschemachange @pubid, @artid, @schemaversion, @schemaguid, @schematype, @schematext
        if @@ERROR<>0 or @retcode<>0 goto UNDO    

        if @oldRetentionValue <> @retention
        begin
            select @eventtype       = 2 -- Change in publication level property

            insert into dbo.MSmerge_settingshistory (eventtime,pubid,artid,eventtype,propertyname,previousvalue,newvalue,eventtext)
            values (default,@pubid,NULL,@eventtype,@property,@oldRetentionValue,@retention,NULL)
        end
    END

    if @property = 'retention_period_unit'
    BEGIN
        
        select @pubcompat_level_id = backward_comp_level from dbo.sysmergepublications
        where pubid = @pubid
        
        if @pubcompat_level_id < @REPOLEVersion_90
        begin
            raiserror(22529, 16, -1, @publication)
            goto UNDO
        end
        
        if @value is null
        or lower(@value collate SQL_Latin1_General_CP1_CS_AS) not in ('day', 'days', 'dd', 'year', 'years', 'yy', 'yyyy', 'month', 'months', 'mm', 'week', 'weeks', 'wk', 'hour', 'hours', 'hh', 'minute', 'minutes', 'mi')
        begin
            raiserror(22527, 16, -1, @value)
            goto UNDO
        end
    
        select @retention_period_unit = 
            case    when lower(@value collate SQL_Latin1_General_CP1_CS_AS) in ('day', 'days', 'dd')
                        then 0
                    when lower(@value collate SQL_Latin1_General_CP1_CS_AS) in ('week', 'weeks', 'wk')
                        then 1
                    when lower(@value collate SQL_Latin1_General_CP1_CS_AS) in ('month', 'months', 'mm')
                        then 2
                    when lower(@value collate SQL_Latin1_General_CP1_CS_AS) in ('year', 'years', 'yy', 'yyyy')
                        then 3
                    when lower(@value collate SQL_Latin1_General_CP1_CS_AS) in ('hour', 'hours', 'hh')
                        then 4
                    when lower(@value collate SQL_Latin1_General_CP1_CS_AS) in ('minute', 'minutes', 'mi')
                        then 5
            end
        
        if @retention_period_unit <> 0 and @pubcompat_level_id < @REPOLEVersion_90
        begin
            raiserror(22528, 16, -1, @publication)
            goto UNDO
        end
        
        if @retention_period_unit <> 0 and @sync_modeid = 1
        begin
            raiserror(22555, 16, -1, @publication)
            goto UNDO
        end
        
        if @retention > sys.fn_units_until_maxdate(@retention_period_unit, getdate())
        begin
            raiserror(20050, 16, -1, 0)
            GOTO UNDO
        end

        declare @previousRPU tinyint
        SELECT @previousRPU = retention_period_unit FROM dbo.sysmergepublications WHERE pubid = @pubid
        UPDATE dbo.sysmergepublications set retention_period_unit = @retention_period_unit WHERE pubid = @pubid
        if @@ERROR <> 0 
            GOTO UNDO

        -- Insert event into MSmerge_settingshistory
        if (@previousRPU <> @retention_period_unit)
        begin
            select @eventtype       = 2 -- Change in publication level property
    
            insert into dbo.MSmerge_settingshistory (eventtime,pubid,artid,eventtype,propertyname,previousvalue,newvalue,eventtext)
            values (default,@pubid,NULL,@eventtype,@property,@previousRPU,@retention_period_unit,NULL)
        end

        select @schemaversion = schemaversion from dbo.sysmergeschemachange
        if (@schemaversion is NULL)
            set @schemaversion = 1
        else
            select @schemaversion = 1 + max(schemaversion) from dbo.sysmergeschemachange
            
        set @schemaguid = newid()
        set @artid = null
        set @schematype = @SCHEMA_TYPE_RETENTIONUNITCHANGE
        select @schematext = 'exec dbo.sp_MSchange_retention_period_unit '+ '''' + convert(nchar(36),@pubid) + '''' + ',' + convert(nvarchar, @retention_period_unit)
        exec @retcode=sys.sp_MSinsertschemachange @pubid, @artid, @schemaversion, @schemaguid, @schematype, @schematext
        if @@ERROR<>0 or @retcode<>0 goto UNDO    
    END
    
    if @property = 'conflict_retention'
    BEGIN
        /*
        ** Update the publication with the new conflict_retention value
        */

        select @retention = CONVERT(int, @value)
        if @@ERROR<>0
            GOTO UNDO

        if @value is NULL 
            select @retention = 0

        if @retention < 0
            begin
                raiserror(20050, 16, -1, 0)
                GOTO UNDO
            end

        declare @previousConflictRet int
        SELECT @previousConflictRet = conflict_retention FROM dbo.sysmergepublications where pubid = @pubid

        UPDATE dbo.sysmergepublications
            SET conflict_retention = @retention
            WHERE pubid = @pubid

        if @@ERROR <> 0 
            GOTO UNDO

        -- Insert event into MSmerge_settingshistory
        if (@previousConflictRet <> @retention)
        begin
            select @eventtype       = 2 -- Change in publication level property

            insert into dbo.MSmerge_settingshistory (eventtime,pubid,artid,eventtype,propertyname,previousvalue,newvalue,eventtext)
            values (default,@pubid,NULL,@eventtype,@property,@previousConflictRet,@retention,NULL)
        end            

    END

    if @property = 'max_concurrent_merge'
    BEGIN
        /*
        ** Update the publication property <max_concurrent_merge> with a new value
        */

        select @max_concurrent_merge = CONVERT(int, @value)
        if @max_concurrent_merge < 0    
        begin
            raiserror(21402, 16, -1, '@value')
            GOTO UNDO
        end

        declare @previousMaxConcMrg int

        SELECT @previousMaxConcMrg = max_concurrent_merge FROM dbo.sysmergepublications
            WHERE pubid = @pubid

        UPDATE dbo.sysmergepublications
            SET max_concurrent_merge = @max_concurrent_merge
            WHERE pubid = @pubid

        if @@ERROR <> 0 
            GOTO UNDO

        -- Insert event into MSmerge_settingshistory
        if (@previousMaxConcMrg <> @max_concurrent_merge)
        begin
            select @eventtype       = 2 -- Change in publication level property

            insert into dbo.MSmerge_settingshistory (eventtime,pubid,artid,eventtype,propertyname,previousvalue,newvalue,eventtext)
            values (default,@pubid,NULL,@eventtype,@property,@previousMaxConcMrg,@max_concurrent_merge,NULL)
        end
    END


    if @property = 'sync_mode'
    BEGIN
        /*
        ** Check for a valid synchronization method.
        */
        if LOWER(@value collate SQL_Latin1_General_CP1_CS_AS)='portable' select @value='character'

        if LOWER(@value collate SQL_Latin1_General_CP1_CS_AS) NOT IN ('native', 'character', 'bcp native', 'bcp character')
        begin
            raiserror (20076, 16, -1)
            GOTO UNDO
        end
        
        /*
        ** Determine the integer value for the sync_mode.
        */
        if LOWER(@value collate SQL_Latin1_General_CP1_CS_AS) IN ('native', 'bcp native')
            select @sync_modeid = 0
        else if LOWER(@value collate SQL_Latin1_General_CP1_CS_AS) IN ('character', 'bcp character')
            select @sync_modeid = 1
            
        -- logical records not supported with char mode bcp (CE subscribers)
        if @sync_modeid = 1 and (exists (select * from dbo.sysmergesubsetfilters where pubid = @pubid
                                        and filter_type & 2 = 2)
                                or exists (select * from dbo.sysmergepartitioninfo where pubid = @pubid
                                            and (logical_record_level_conflict_detection = 1 or logical_record_level_conflict_resolution = 1)))
        begin 
            raiserror(22540, 16, -1, @publication)
            goto UNDO
        end
        
        if @sync_modeid = 1 and exists (select * from dbo.sysmergepublications where pubid = @pubid
                                        and retention_period_unit <> 0)
        begin 
            raiserror(22554, 16, -1, @publication)
            goto UNDO
        end

        /*
        ** Update the publication with the new synchronization method.
        */
        declare @previousSyncMode tinyint
        SELECT @previousSyncMode = sync_mode FROM dbo.sysmergepublications
         WHERE pubid = @pubid
        
        UPDATE dbo.sysmergepublications
           SET sync_mode = @sync_modeid
         WHERE pubid = @pubid

        if @@ERROR <> 0 GOTO UNDO

        -- Insert event into MSmerge_settingshistory
        if (@previousSyncMode <> @sync_modeid)
        begin
            select @eventtype       = 2 -- Change in publication level property

            insert into dbo.MSmerge_settingshistory (eventtime,pubid,artid,eventtype,propertyname,previousvalue,newvalue,eventtext)
            values (default,@pubid,NULL,@eventtype,@property,@previousSyncMode,@sync_modeid,NULL)
        end        

    END

    IF @property = N'alt_snapshot_folder'
    BEGIN
        -- If the alt_snapshot_folder is set to '' or NULL,
        -- set the compress_snapshot bit to 0 and disable internet 
        -- support

        declare @previousAltSnapFolder nvarchar(255)
        SELECT @previousAltSnapFolder = alt_snapshot_folder FROM dbo.sysmergepublications
             WHERE pubid = @pubid

        IF @value IS NULL OR @value = N''
        BEGIN
            UPDATE dbo.sysmergepublications
               SET alt_snapshot_folder = @value,
                   compress_snapshot = 0,
                   enabled_for_internet = 0
             WHERE pubid = @pubid
        END
        ELSE
        BEGIN
            UPDATE dbo.sysmergepublications
               SET alt_snapshot_folder = @value
             WHERE pubid = @pubid
        END
        IF @@error <> 0
        BEGIN
           GOTO UNDO
        END
        exec @retcode=sys.sp_MSrefreshdynamicsnapshotlocations @pubid
        if @@error<>0 or @retcode<>0
            goto UNDO

        -- Insert event into MSmerge_settingshistory
        if (@previousAltSnapFolder <> @value)
        begin
            select @eventtype       = 2 -- Change in publication level property

            insert into dbo.MSmerge_settingshistory (eventtime,pubid,artid,eventtype,propertyname,previousvalue,newvalue,eventtext)
            values (default,@pubid,NULL,@eventtype,@property,@previousAltSnapFolder,@value,NULL)
        end

    END

    IF @property = N'pre_snapshot_script'
    BEGIN
        declare @previousPreSnapScript nvarchar(255)
        SELECT @previousPreSnapScript = pre_snapshot_script FROM dbo.sysmergepublications
         WHERE pubid = @pubid

        UPDATE dbo.sysmergepublications
           SET pre_snapshot_script = @value
         WHERE pubid = @pubid
        IF @@error <> 0
        BEGIN
           GOTO UNDO
        END

        -- Insert event into MSmerge_settingshistory
        if (@previousPreSnapScript <> @value)
        begin
            select @eventtype       = 2 -- Change in publication level property

            insert into dbo.MSmerge_settingshistory (eventtime,pubid,artid,eventtype,propertyname,previousvalue,newvalue,eventtext)
            values (default,@pubid,NULL,@eventtype,@property,@previousPreSnapScript,@value_bit,NULL)
        end

    END

    IF @property = N'post_snapshot_script'
    BEGIN
        declare @previousPostSnapScript nvarchar(255)
        
        SELECT @previousPostSnapScript = post_snapshot_script FROM dbo.sysmergepublications
         WHERE pubid = @pubid

        UPDATE dbo.sysmergepublications
           SET post_snapshot_script = @value
         WHERE pubid = @pubid
        IF @@error <> 0
        BEGIN
           GOTO UNDO
        END

        -- Insert event into MSmerge_settingshistory
        if (@previousPostSnapScript <> @value)
        begin
            select @eventtype       = 2 -- Change in publication level property

            insert into dbo.MSmerge_settingshistory (eventtime,pubid,artid,eventtype,propertyname,previousvalue,newvalue,eventtext)
            values (default,@pubid,NULL,@eventtype,@property,@previousPostSnapScript,@value_bit,NULL)
        end
    END

    IF @property = N'ftp_address'
    BEGIN
        declare @previousFtpAddr sysname
        SELECT @previousFtpAddr = ftp_address FROM dbo.sysmergepublications
             WHERE pubid = @pubid

        IF @value IS NULL OR @value = N''    
        BEGIN
            UPDATE dbo.sysmergepublications
               SET ftp_address = @value,
                   enabled_for_internet = 0
             WHERE pubid = @pubid
            IF @@error <> 0
            BEGIN
                GOTO UNDO
            END
            exec @retcode=sys.sp_MSrefreshdynamicsnapshotlocations @pubid
            if @@error<>0 or @retcode<>0
                goto UNDO
        END
        ELSE
        BEGIN
            UPDATE dbo.sysmergepublications
               SET ftp_address = @value
             WHERE pubid = @pubid
            IF @@error <> 0
            BEGIN
                GOTO UNDO
            END
        END

        -- Insert event into MSmerge_settingshistory
        if (@previousFtpAddr <> @value)
        begin
            select @eventtype       = 2 -- Change in publication level property

            insert into dbo.MSmerge_settingshistory (eventtime,pubid,artid,eventtype,propertyname,previousvalue,newvalue,eventtext)
            values (default,@pubid,NULL,@eventtype,@property,@previousFtpAddr,@value,NULL)
        end
    END
            
    IF @property = N'ftp_port'
    BEGIN
        declare @previousFtpPort int
        SELECT @previousFtpPort = ftp_port FROM dbo.sysmergepublications
              WHERE pubid = @pubid

        SET @numeric_value = CONVERT(int, @value)

        UPDATE dbo.sysmergepublications
           SET ftp_port = @numeric_value
         WHERE pubid = @pubid
        IF @@error <> 0
        BEGIN
           GOTO UNDO
        END

        -- Insert event into MSmerge_settingshistory
        if (@previousFtpPort <> @numeric_value)
        begin
            select @eventtype       = 2 -- Change in publication level property

            insert into dbo.MSmerge_settingshistory (eventtime,pubid,artid,eventtype,propertyname,previousvalue,newvalue,eventtext)
            values (default,@pubid,NULL,@eventtype,@property,@previousFtpPort,@value,NULL)
        end        

    END

    IF @property = N'ftp_subdirectory'
    BEGIN

        declare @previousFtpSubdir nvarchar(255)
        SELECT @previousFtpSubdir = ftp_subdirectory FROM dbo.sysmergepublications
               WHERE pubid = @pubid        

        UPDATE dbo.sysmergepublications
           SET ftp_subdirectory = @value
         WHERE pubid = @pubid
        IF @@error <> 0
        BEGIN
           GOTO UNDO
        END
        exec @retcode=sys.sp_MSrefreshdynamicsnapshotlocations @pubid
        if @@error<>0 or @retcode<>0
            goto UNDO

        -- Insert event into MSmerge_settingshistory
        if (@previousFtpSubdir <> @value)
        begin
            select @eventtype       = 2 -- Change in publication level property

            insert into dbo.MSmerge_settingshistory (eventtime,pubid,artid,eventtype,propertyname,previousvalue,newvalue,eventtext)
            values (default,@pubid,NULL,@eventtype,@property,@previousFtpSubdir,@value,NULL)
        end
    END

    IF @property = N'ftp_login'
    BEGIN
        declare @previousFtpLogin sysname
        SELECT @previousFtpLogin = ftp_login FROM dbo.sysmergepublications WHERE pubid = @pubid

        UPDATE dbo.sysmergepublications
           SET ftp_login = @value
         WHERE pubid = @pubid
        IF @@error <> 0
        BEGIN
           GOTO UNDO
        END

        -- Insert event into MSmerge_settingshistory
        if (@previousFtpLogin <> @value)
        begin
            select @eventtype       = 2 -- Change in publication level property

            insert into dbo.MSmerge_settingshistory (eventtime,pubid,artid,eventtype,propertyname,previousvalue,newvalue,eventtext)
            values (default,@pubid,NULL,@eventtype,@property,@previousFtpLogin,@value,NULL)
        end

    END

    IF @property = N'ftp_password'
    BEGIN
        SELECT @enc_ftp_password = NULL
        IF @value IS NOT NULL
        BEGIN
            SELECT @enc_ftp_password = @value
            EXEC @retcode = sys.sp_MSreplencrypt @enc_ftp_password OUTPUT
            IF @retcode <> 0
            BEGIN
                GOTO UNDO
            END
        END

        UPDATE dbo.sysmergepublications
           SET ftp_password = @enc_ftp_password
         WHERE pubid = @pubid
        IF @@error <> 0
        BEGIN
           GOTO UNDO
        END
    END

    IF @property = N'max_concurrent_dynamic_snapshots'
    BEGIN
        SELECT @numeric_value = CONVERT(int, @value)
        IF @@ERROR<>0 OR @numeric_value < 0 OR @numeric_value IS NULL
        BEGIN
            RAISERROR(21403, 16, -1)
            GOTO UNDO
        END

        declare @previousMaxConcDynSnap int
        SELECT @previousMaxConcDynSnap = max_concurrent_dynamic_snapshots FROM dbo.sysmergepublications WHERE pubid = @pubid

        UPDATE dbo.sysmergepublications
           SET max_concurrent_dynamic_snapshots = @numeric_value
         WHERE pubid = @pubid
        IF @@error <> 0
        BEGIN 
            GOTO UNDO
        END 

        -- Insert event into MSmerge_settingshistory
        if (@previousMaxConcDynSnap <> @numeric_value)
        begin
            select @eventtype       = 2 -- Change in publication level property

            insert into dbo.MSmerge_settingshistory (eventtime,pubid,artid,eventtype,propertyname,previousvalue,newvalue,eventtext)
            values (default,@pubid,NULL,@eventtype,@property,@previousMaxConcDynSnap,@numeric_value,NULL)
        end
    END         

    IF @property = N'replicate_ddl'
    BEGIN
        SELECT @numeric_value = CONVERT(int, @value)
        IF @@ERROR<>0 OR (@numeric_value NOT in (0, 1) ) OR @numeric_value IS NULL
        BEGIN
            RAISERROR(21544, 16, -1)
            GOTO UNDO
        END

        if @numeric_value = 1 and @compatlevel < 90
        begin
            RAISERROR(20650, 16, -1, @publication)
            GOTO UNDO
        end

        /* Get the previous value */
        select @previousnumericvalue = replicate_ddl from  dbo.sysmergepublications 
        WHERE pubid = @pubid

        /* Update the replicate_ddl column */
        UPDATE dbo.sysmergepublications 
            SET replicate_ddl = @numeric_value
            WHERE pubid = @pubid
        if @@error <> 0
        BEGIN
           GOTO UNDO
        END

        /*  Insert event in the MSmerge_settingshistory table if the
        new value is different from the old value
        Look in replsys.sql where the table is created for more
        details about what is in this table. */
        
        if (@previousnumericvalue <> @numeric_value)
        begin
            select @eventtype       = 2 -- Change in publication level property

            insert into dbo.MSmerge_settingshistory (eventtime,pubid,artid,eventtype,propertyname,previousvalue,newvalue,eventtext)
            values (default,@pubid,NULL,@eventtype,@property,@previousnumericvalue,@numeric_value,NULL)
        end

    END

   if @property = 'publish_to_activedirectory'
   BEGIN
        if LOWER(@value collate SQL_Latin1_General_CP1_CS_AS) NOT IN ('true', 'false')
        BEGIN
            RAISERROR (14137, 16, -1)
            GOTO UNDO
        END
    END
    else if @property in ('conflict_logging', 'centralized_conflicts')
    begin
        set @value= LOWER(@value collate SQL_Latin1_General_CP1_CS_AS)
        
        if @property = 'conflict_logging'
        begin
            set @numeric_value= 
                    case @value
                        when 'publisher' then 1
                        when 'subscriber' then 0
                        when 'both' then 2
                        else null
                    end

            if @numeric_value is null
            begin
                RAISERROR (14103, 16, -1, 'conflict_logging')
                goto UNDO
            end
        end
        else
        begin
            raiserror (21767, 10, 1, 'centralized_conflicts', 'conflict_logging')

            set @numeric_value= 
                    case @value
                        when 'true' then 1
                        when 'false' then 0
                        else null
                    end
        
            if @numeric_value is null
            begin
                RAISERROR (14148, 16, -1, 'decentralized_conflicts')
                goto UNDO
            end
        end

        declare @old_centralized_conflicts int
        declare @old_decentralized_conflicts int
        declare @new_centralized_conflicts int
        declare @new_decentralized_conflicts int
        
        -- conflict_logging of 'both' is allowed for 90RTM and higher compat levels only.
        if @numeric_value = 2 and @compatlevel < @REPOLEVersion_90
        begin
            RAISERROR (20705, 16, -1, @publication)
            goto UNDO
        end

        if @numeric_value = 0 and @compatlevel < 30
        begin
            EXEC @retcode = sys.sp_MSBumpupCompLevel @pubid, 30
            IF @@ERROR<>0 OR @retcode<>0 GOTO UNDO
        end

        select @old_centralized_conflicts = centralized_conflicts, 
               @old_decentralized_conflicts = decentralized_conflicts
           from dbo.sysmergepublications where pubid=@pubid

        if @numeric_value = 0
        begin
            set @new_centralized_conflicts = 0
            set @new_decentralized_conflicts = 1
        end

        if @numeric_value = 1
        begin
            set @new_centralized_conflicts = 1
            set @new_decentralized_conflicts = 0
        end

        if @numeric_value = 2
        begin
            set @new_centralized_conflicts = 1
            set @new_decentralized_conflicts = 1
        end

        -- changing from conflict logging type of publisher to both or subscriber will require a reinit
        if @snapshot_ready>0 and @old_decentralized_conflicts = 0 and @new_decentralized_conflicts = 1
        begin            
            if @force_reinit_subscription = 0
            begin
                raiserror(20608, 16, -1)
                goto UNDO
            end
            exec @retcode = sp_MSreinitmergepublication @publication
            if @@ERROR<>0 or @retcode<>0
                goto UNDO
        end

        update dbo.sysmergepublications
            set centralized_conflicts = @new_centralized_conflicts,
                decentralized_conflicts = @new_decentralized_conflicts
            where pubid = @pubid

        if (@old_centralized_conflicts <> @new_centralized_conflicts)
        begin
            select @eventtype       = 2 -- Change in publication level property

            insert into dbo.MSmerge_settingshistory (eventtime,pubid,artid,eventtype,propertyname,previousvalue,newvalue,eventtext)
            values (default,@pubid,NULL,@eventtype,N'centralized_conflicts',@old_centralized_conflicts,@new_centralized_conflicts,NULL)

            insert into dbo.MSmerge_settingshistory (eventtime,pubid,artid,eventtype,propertyname,previousvalue,newvalue,eventtext)
            values (default,@pubid,NULL,@eventtype,N'decentralized_conflicts',@old_decentralized_conflicts,@new_decentralized_conflicts,NULL)
        end

        select @schemaversion = schemaversion from dbo.sysmergeschemachange
        if (@schemaversion is NULL)
            set @schemaversion = 1
        else
            select @schemaversion = 1 + max(schemaversion) from dbo.sysmergeschemachange
            
        set @schemaguid = newid()
        set @artid = null
        set @schematype = @SCHEMA_TYPE_CHANGE_MERGE_PUBLICATION_90RTM
        select @schematext = 'exec dbo.sp_MSchange_mergepublication @pubid = ''' + convert(nchar(36), @pubid) + ''', @property = ''' + @property + ''', @value = ''' + cast(@numeric_value as nvarchar) + ''''
        exec @retcode=sys.sp_MSinsertschemachange @pubid, @artid, @schemaversion, @schemaguid, @schematype, @schematext
        if @@ERROR<>0 or @retcode<>0 goto UNDO    
    end
    else if @property = 'generation_leveling_threshold'
    begin
              
        set @numeric_value= convert(int, @value)
        
        if @numeric_value is null
            select @numeric_value = 0
            
        if @numeric_value < 0
        begin
            raiserror(21119, 16, -1, @numeric_value, 'generation_leveling_threshold')
            goto UNDO
        end
            
        declare @previousGenLevelThresh int
        SELECT @previousGenLevelThresh = generation_leveling_threshold FROM dbo.sysmergepublications WHERE pubid = @pubid

        update dbo.sysmergepublications
            set generation_leveling_threshold = @numeric_value
            where pubid = @pubid

        -- Insert event into MSmerge_settingshistory
        if (@previousGenLevelThresh <> @numeric_value)
        begin
            select @eventtype       = 2 -- Change in publication level property

            insert into dbo.MSmerge_settingshistory (eventtime,pubid,artid,eventtype,propertyname,previousvalue,newvalue,eventtext)
            values (default,@pubid,NULL,@eventtype,@property,@previousGenLevelThresh,@numeric_value,NULL)
        end

        select @schemaversion = schemaversion from dbo.sysmergeschemachange
        if (@schemaversion is NULL)
            set @schemaversion = 1
        else
            select @schemaversion = 1 + max(schemaversion) from dbo.sysmergeschemachange
            
        set @schemaguid = newid()
        set @artid = null
        set @schematype = @SCHEMA_TYPE_CHANGE_MERGE_PUBLICATION_90RTM
        select @schematext = 'exec dbo.sp_MSchange_mergepublication @pubid = ''' + convert(nchar(36), @pubid) + ''', @property = ''' + @property + ''', @value = ''' + cast(@numeric_value as nvarchar) + ''''
        exec @retcode=sys.sp_MSinsertschemachange @pubid, @artid, @schemaversion, @schemaguid, @schematype, @schematext
        if @@ERROR<>0 or @retcode<>0 goto UNDO    
    end
    else if @property IN ('allow_push', 'allow_pull', 'allow_anonymous', 'enabled_for_internet',
        'snapshot_ready', 'snapshot_in_defaultfolder', 'compress_snapshot', 
        'allow_subscription_copy', 'allow_synctoalternate', 'allow_web_synchronization','use_partition_groups', 'allow_subscriber_initiated_snapshot', 'keep_partition_changes',
        'allow_partition_realignment')
    BEGIN

        /*
        ** Check for a valid  value.
        */

        if LOWER(@value collate SQL_Latin1_General_CP1_CS_AS) NOT IN ('true', 'false')
        BEGIN
            RAISERROR (14137, 16, -1)
            GOTO UNDO
        END

        /*
        ** set value bit
        */
        if LOWER(@value collate SQL_Latin1_General_CP1_CS_AS) = 'true'
            select @value_bit = 1
        else 
            select @value_bit = 0

        if @property = 'allow_anonymous'
        BEGIN
            declare @previousAllowAnon int
            SELECT @previousAllowAnon = allow_anonymous FROM dbo.sysmergepublications WHERE pubid = @pubid

            /* Update the allow_anonymous column */
            UPDATE dbo.sysmergepublications 
                SET allow_anonymous = @value_bit
                WHERE pubid = @pubid
            if @@error <> 0
            BEGIN
               GOTO UNDO
            END
            -- Insert event into MSmerge_settingshistory
            if (@previousAllowAnon <> @value_bit)
            begin
                select @eventtype       = 2 -- Change in publication level property
    
                insert into dbo.MSmerge_settingshistory (eventtime,pubid,artid,eventtype,propertyname,previousvalue,newvalue,eventtext)
                values (default,@pubid,NULL,@eventtype,@property,@previousAllowAnon,@value_bit,NULL)
            end
        END

        if @property = 'allow_push'
        BEGIN
            declare @previousAllowPush int
            SELECT @previousAllowPush = allow_push FROM dbo.sysmergepublications WHERE pubid = @pubid

            /* Update the allow_push column */
            UPDATE dbo.sysmergepublications 
                SET allow_push = @value_bit
                WHERE pubid = @pubid
            if @@error <> 0
            BEGIN
               GOTO UNDO
            END
            -- Insert event into MSmerge_settingshistory
            if (@previousAllowPush <> @value_bit)
            begin
                select @eventtype       = 2 -- Change in publication level property
    
                insert into dbo.MSmerge_settingshistory (eventtime,pubid,artid,eventtype,propertyname,previousvalue,newvalue,eventtext)
                values (default,@pubid,NULL,@eventtype,@property,@previousAllowPush,@value_bit,NULL)
            end
        END

        if @property = 'allow_pull'
        BEGIN
            declare @previousAllowPull int
            SELECT @previousAllowPull = allow_pull FROM dbo.sysmergepublications WHERE pubid = @pubid

            /* Update the allow_pull column */
            UPDATE dbo.sysmergepublications 
                SET allow_pull = @value_bit
                WHERE pubid = @pubid
            if @@error <> 0
            BEGIN
               GOTO UNDO
            END

            -- Insert event into MSmerge_settingshistory
            if (@previousAllowPull <> @value_bit)
            begin
                select @eventtype       = 2 -- Change in publication level property
    
                insert into dbo.MSmerge_settingshistory (eventtime,pubid,artid,eventtype,propertyname,previousvalue,newvalue,eventtext)
                values (default,@pubid,NULL,@eventtype,@property,@previousAllowPull,@value_bit,NULL)
            end

        END

        if @property = 'enabled_for_internet'
        BEGIN
            declare @previousEnableForInternet int
            SELECT @previousEnableForInternet = enabled_for_internet FROM dbo.sysmergepublications WHERE pubid = @pubid

            UPDATE dbo.sysmergepublications 
               SET enabled_for_internet = @value_bit
             WHERE pubid = @pubid

            IF @@error <> 0
            BEGIN
               GOTO UNDO
            END
            exec @retcode=sys.sp_MSrefreshdynamicsnapshotlocations @pubid
            if @@error<>0 or @retcode<>0
                goto UNDO

            -- Insert event into MSmerge_settingshistory
            if (@previousEnableForInternet <> @value_bit)
            begin
                select @eventtype       = 2 -- Change in publication level property
    
                insert into dbo.MSmerge_settingshistory (eventtime,pubid,artid,eventtype,propertyname,previousvalue,newvalue,eventtext)
                values (default,@pubid,NULL,@eventtype,@property,@previousEnableForInternet,@value_bit,NULL)
            end

        END

        if @property = 'snapshot_ready'
        BEGIN
            declare @previousSnapshotReadyValue tinyint
            SELECT @previousSnapshotReadyValue = snapshot_ready from dbo.sysmergepublications WHERE pubid = @pubid

            declare @newSnapshotReadyValue tinyint
            SET @newSnapshotReadyValue = case @value_bit when 1 then 1 else 2 end

            -- snapshot_ready should not be set to 0. If snapshot_ready was 1 then
            -- set it to 2 to invalidate it.
            UPDATE dbo.sysmergepublications 
                SET snapshot_ready = @newSnapshotReadyValue
                WHERE pubid = @pubid
            if @@error <> 0
            BEGIN
               GOTO UNDO
            END

            -- Insert event in MSmerge_settingshistory
            if (@previousSnapshotReadyValue <> @newSnapshotReadyValue)
            begin
                select @eventtype       = 2 -- Change in publication level property

                insert into dbo.MSmerge_settingshistory (eventtime,pubid,artid,eventtype,propertyname,previousvalue,newvalue,eventtext)
                values (default,@pubid,NULL,@eventtype,@property,@previousSnapshotReadyValue,@newSnapshotReadyValue,NULL)
            end

        END

        IF @property = 'snapshot_in_defaultfolder'
        BEGIN
            -- snapshot_in_defaultfolder = 1 is only meaningful when
            -- alt_snapshot_folder is non-null, otherwise 
            -- a copy of the snapshot files is always kept
            -- at the publisher's working directory 

            declare @previousSnapInDefaultFolder int
            SELECT @previousSnapInDefaultFolder = snapshot_in_defaultfolder FROM dbo.sysmergepublications WHERE pubid = @pubid

            UPDATE dbo.sysmergepublications 
               SET snapshot_in_defaultfolder = @value_bit
             WHERE pubid = @pubid
            IF @@error <> 0
            BEGIN
                GOTO UNDO
            END                

            -- Insert event into MSmerge_settingshistory
            if (@previousSnapInDefaultFolder <> @value_bit)
            begin
                select @eventtype       = 2 -- Change in publication level property
    
                insert into dbo.MSmerge_settingshistory (eventtime,pubid,artid,eventtype,propertyname,previousvalue,newvalue,eventtext)
                values (default,@pubid,NULL,@eventtype,@property,@previousSnapInDefaultFolder,@value_bit,NULL)
            end

            -- Bump up the compatibility level if we are
            -- setting snapshot_in_defaultfolder to 0
            -- and compression is enabled. i.e. only 
            -- a compressed snapshot will be generated
            -- Note that alt_snapshot_folder is implicitly
            -- specified for the publication
            IF @value_bit = 0 and @compress_snapshot = 1 and @compatlevel < 40
            BEGIN
                EXEC @retcode = sys.sp_MSBumpupCompLevel @pubid, 40
                IF @@ERROR<>0 OR @retcode<>0
                    GOTO UNDO
            END

        END
        
        IF @property = 'compress_snapshot'
        BEGIN
            declare @previousCompressSnap int
            SELECT @previousCompressSnap = compress_snapshot FROM dbo.sysmergepublications WHERE pubid = @pubid

            UPDATE dbo.sysmergepublications
               SET compress_snapshot = @value_bit
             WHERE pubid = @pubid
            IF @@error <> 0
            BEGIN
                GOTO UNDO
            END

            -- Insert event into MSmerge_settingshistory
            if (@previousCompressSnap <> @value_bit)
            begin
                select @eventtype       = 2 -- Change in publication level property
    
                insert into dbo.MSmerge_settingshistory (eventtime,pubid,artid,eventtype,propertyname,previousvalue,newvalue,eventtext)
                values (default,@pubid,NULL,@eventtype,@property,@previousCompressSnap,@value_bit,NULL)
            end

            -- See comment for 'snapshot_in_defaultfolder'
            IF @value_bit = 1 and @snapshot_in_defaultfolder = 0 and @compatlevel < 40
            BEGIN
                EXEC @retcode = sys.sp_MSBumpupCompLevel @pubid, 40
                IF @@ERROR<>0 OR @retcode<>0
                    GOTO UNDO
            END
        END

        if @property = 'allow_subscription_copy'
        BEGIN

            declare @previousAllowSubCopy int
            SELECT @previousAllowSubCopy = allow_subscription_copy FROM dbo.sysmergepublications WHERE pubid = @pubid

            /* Update the allow_subscription_copy column */
            UPDATE dbo.sysmergepublications 
                SET allow_subscription_copy = @value_bit
                WHERE pubid = @pubid
            if @@error <> 0
            BEGIN
               GOTO UNDO
            END

            -- Insert event into MSmerge_settingshistory
            if (@previousAllowSubCopy <> @value_bit)
            begin
                select @eventtype       = 2 -- Change in publication level property
    
                insert into dbo.MSmerge_settingshistory (eventtime,pubid,artid,eventtype,propertyname,previousvalue,newvalue,eventtext)
                values (default,@pubid,NULL,@eventtype,@property,@previousAllowSubCopy,@value_bit,NULL)
            end
            
            select @schemaversion = schemaversion from dbo.sysmergeschemachange
            if (@schemaversion is NULL)
                set @schemaversion = 1
            else
                select @schemaversion = 1 + max(schemaversion) from dbo.sysmergeschemachange
                
            set @schemaguid = newid()
            set @artid = null
            set @schematype = @SCHEMA_TYPE_CHANGE_MERGE_PUBLICATION_90RTM
            select @schematext = 'exec dbo.sp_MSchange_mergepublication @pubid = ''' + convert(nchar(36), @pubid) + ''', @property = ''' + @property + ''', @value = ''' + @value + ''''
            exec @retcode=sys.sp_MSinsertschemachange @pubid, @artid, @schemaversion, @schemaguid, @schematype, @schematext
            if @@ERROR<>0 or @retcode<>0 goto UNDO    
            
        END
        if @property = 'allow_synctoalternate'
        BEGIN

            declare @previousSyncToAlt int
            SELECT @previousSyncToAlt = allow_synctoalternate FROM dbo.sysmergepublications WHERE pubid = @pubid

            /* Update the allow_synctoalternate column */
            UPDATE dbo.sysmergepublications 
                SET allow_synctoalternate = @value_bit
                WHERE pubid = @pubid
            if @@error <> 0
            BEGIN
               GOTO UNDO
            END

            -- Insert event into MSmerge_settingshistory
            if (@previousSyncToAlt <> @value_bit)
            begin
                select @eventtype       = 2 -- Change in publication level property
    
                insert into dbo.MSmerge_settingshistory (eventtime,pubid,artid,eventtype,propertyname,previousvalue,newvalue,eventtext)
                values (default,@pubid,NULL,@eventtype,@property,@previousSyncToAlt,@value_bit,NULL)
            end

        END
        
        if @property = 'allow_web_synchronization'
        BEGIN
        
            -- logical records not supported with char mode bcp (CE subscribers)
            if @value_bit = 1 and (exists (select * from dbo.sysmergesubsetfilters where pubid = @pubid
                                        and filter_type & 2 = 2)
                                    or exists (select * from dbo.sysmergepartitioninfo where pubid = @pubid
                                        and (logical_record_level_conflict_detection = 1 or logical_record_level_conflict_resolution = 1)))                                        
            begin 
                raiserror(22546, 16, -1, @publication)
                goto UNDO
            end
        

            declare @previousAllowWebSync int
            SELECT @previousAllowWebSync = allow_web_synchronization FROM dbo.sysmergepublications WHERE pubid = @pubid

            /* Update the allow_web_synchronization column */
            UPDATE dbo.sysmergepublications 
                SET allow_web_synchronization = @value_bit
                WHERE pubid = @pubid
            if @@error <> 0
            BEGIN
               GOTO UNDO
            END

            -- Insert event into MSmerge_settingshistory
            if (@previousAllowWebSync <> @value_bit)
            begin
                select @eventtype       = 2 -- Change in publication level property
    
                insert into dbo.MSmerge_settingshistory (eventtime,pubid,artid,eventtype,propertyname,previousvalue,newvalue,eventtext)
                values (default,@pubid,NULL,@eventtype,@property,@previousAllowWebSync,@value_bit,NULL)
            end
        END
        
        if @property = 'allow_subscriber_initiated_snapshot'
        BEGIN

            declare @previousAllowSubInitSnapshot int
            SELECT @previousAllowSubInitSnapshot = allow_subscriber_initiated_snapshot FROM dbo.sysmergepublications WHERE pubid = @pubid

            /* Update the allow_subscriber_initiated_snapshot column */
            UPDATE dbo.sysmergepublications 
                SET allow_subscriber_initiated_snapshot = @value_bit
                WHERE pubid = @pubid
            if @@error <> 0
            BEGIN
               GOTO UNDO
            END

            -- Insert event into MSmerge_settingshistory
            if (@previousAllowSubInitSnapshot <> @value_bit)
            begin
                select @eventtype       = 2 -- Change in publication level property
    
                insert into dbo.MSmerge_settingshistory (eventtime,pubid,artid,eventtype,propertyname,previousvalue,newvalue,eventtext)
                values (default,@pubid,NULL,@eventtype,@property,@previousAllowSubInitSnapshot,@value_bit,NULL)
            end
        END 

        if @property = 'allow_partition_realignment'
        BEGIN

            -- upload options can not be set to allow uploads when allow_partition_realignment is set
            -- to false or else it can lead to upload of out of partition updates.
            select @upload_options = NULL
            select top 1 @upload_options = upload_options from dbo.sysmergearticles 
                where pubid = @pubid
            if @value_bit = 0 and @upload_options <> 1 and @upload_options <> 2 and @upload_options is not NULL
            begin
                raiserror(22543, 16, -1)
                GOTO UNDO
            end

            /* Get the previous value */
            select @previousbitvalue = allow_partition_realignment from  dbo.sysmergepublications 
            WHERE pubid = @pubid

            /* Update the allow_subscriber_initiated_snapshot column */
            UPDATE dbo.sysmergepublications 
                SET allow_partition_realignment = @value_bit
                WHERE pubid = @pubid
            if @@error <> 0
            BEGIN
               GOTO UNDO
            END

            /*  Insert event in the MSmerge_settingshistory table if the
            new value is different from the old value
            Look in replsys.sql where the table is created for more
            details about what is in this table. */
            
            if (@previousbitvalue <> @value_bit)
            begin
                select @eventtype       = 2 -- Change in publication level property

                insert into dbo.MSmerge_settingshistory (eventtime,pubid,artid,eventtype,propertyname,previousvalue,newvalue,eventtext)
                values (default,@pubid,NULL,@eventtype,@property,@previousbitvalue,@value_bit,NULL)
            end

        END 
        
        if @property = 'keep_partition_changes'
        BEGIN
            declare @use_partition_groups smallint
            declare @backward_comp_level int
            declare @keep_partition_changes_old int
            select @use_partition_groups = use_partition_groups, 
                   @backward_comp_level = backward_comp_level,
                   @keep_partition_changes_old = keep_before_values from dbo.sysmergepublications
                where pubid = @pubid
            -- when changing partition groups from 0 to 1 all subscriptions have to be reinitialized
            if ((@keep_partition_changes_old = 0 and @value_bit = 1) and (@force_reinit_subscription = 0 and @snapshot_ready>0))
            begin
                raiserror(20608, 16, -1)
                goto UNDO
            end
            if @use_partition_groups > 0 and @backward_comp_level >= @REPOLEVersion_90
                and @value_bit = 1
            begin
                raiserror(21729, 16, -1)
                GOTO UNDO
            end

            declare @previousKeepBeforeValues int
            SELECT @previousKeepBeforeValues = keep_before_values FROM dbo.sysmergepublications WHERE pubid = @pubid

            /* Update the keep_partition_changes column */
            UPDATE dbo.sysmergepublications 
                SET keep_before_values = @value_bit
                WHERE pubid = @pubid
            if @@error <> 0 GOTO UNDO

            -- Insert event into MSmerge_settingshistory
            if (@previousKeepBeforeValues <> @value_bit)
            begin
                select @eventtype       = 2 -- Change in publication level property
    
                insert into dbo.MSmerge_settingshistory (eventtime,pubid,artid,eventtype,propertyname,previousvalue,newvalue,eventtext)
                values (default,@pubid,NULL,@eventtype,@property,@previousKeepBeforeValues,@value_bit,NULL)
            end

            if @keep_partition_changes_old = 0 and @value_bit = 1 and @snapshot_ready>0
            begin
                exec @retcode = sys.sp_MSreinitmergepublication 
                                        @publication = @publication,
                                        @upload_first = @automatic_reinitialization_policy
                if @@ERROR<>0 or @retcode<>0 goto UNDO
            end

            if @keep_partition_changes_old = 1 and @value_bit = 0
            begin
                declare @before_view_objid int
                declare @before_upd_view_objid int
                declare @before_image_objid int
                declare @nickloop int

                set @nickloop = 0

                select top 1 @nickloop = nickname, 
                       @before_view_objid = before_view_objid,
                       @before_upd_view_objid = before_upd_view_objid,
                       @before_image_objid = before_image_objid
                       from dbo.sysmergearticles where pubid = @pubid and nickname > @nickloop
                       order by nickname
                WHILE @nickloop is not null
                BEGIN
                    declare @obj_to_drop nvarchar(258)
                    -- Before dropping anything, ensure that another publication
                    -- is not using it.
                    if not exists (select * from dbo.sysmergearticles where
                                    before_upd_view_objid=@before_upd_view_objid
                                    and pubid <> @pubid) and @before_upd_view_objid is not null
                    begin
                        set @obj_to_drop = QUOTENAME(OBJECT_NAME(@before_upd_view_objid))
                        exec('drop view ' + @obj_to_drop)
                        if @@ERROR<>0 GOTO UNDO
                    end

                    if not exists (select * from dbo.sysmergearticles where
                                    before_view_objid=@before_view_objid
                                    and pubid <> @pubid) and @before_view_objid is not null
                    begin
                        set @obj_to_drop = QUOTENAME(OBJECT_NAME(@before_view_objid))
                        exec('drop view ' + @obj_to_drop)
                        if @@ERROR<>0 GOTO UNDO
                    end

                    if not exists (select * from dbo.sysmergearticles where
                                    before_image_objid=@before_image_objid
                                    and pubid <> @pubid) and @before_image_objid is not null
                    begin
                        set @obj_to_drop = QUOTENAME(OBJECT_NAME(@before_image_objid))
                        exec('drop table ' + @obj_to_drop)
                        if @@ERROR<>0 GOTO UNDO
                    end

                    select top 1 @nickloop = nickname, 
                           @before_view_objid = before_view_objid,
                           @before_upd_view_objid = before_upd_view_objid,
                           @before_image_objid = before_image_objid
                           from dbo.sysmergearticles where pubid = @pubid and nickname > @nickloop
                           order by nickname

                    if @@rowcount = 0
                        set @nickloop = NULL
                END

                -- Set entries to NULL
                UPDATE dbo.sysmergearticles SET before_upd_view_objid = NULL, 
                    before_view_objid = NULL,
                    before_image_objid = NULL
                    WHERE pubid = @pubid

                -- Recreate expand procs to reflect change
                declare @filter_id int
                declare @filter_id_str nvarchar(10)
                declare @procname nvarchar(300)
                declare @quoted_obj nvarchar(310)
                set @filter_id = 0
                select @filter_id = min(join_filterid) from dbo.sysmergesubsetfilters where
                    pubid = @pubid and join_filterid > @filter_id and (filter_type & 1) = 1
                while @filter_id is not null
                begin
                    set @filter_id_str = convert(nvarchar(10), @filter_id)
                    select @procname = expand_proc from dbo.sysmergesubsetfilters where
                        pubid = @pubid and join_filterid = @filter_id and (filter_type & 1) = 1
                    if object_id(@procname) is not NULL
                    begin
                        set @quoted_obj = QUOTENAME(@procname)
                        exec ('drop procedure ' + @quoted_obj)
                    end
                    else
                    begin
                        set @procname = 'MSmerge_expand_' + @filter_id_str
                        set @quoted_obj= quotename(@procname)
                        if object_id(@procname) is not NULL
                        begin
                            exec ('drop procedure ' + @quoted_obj)
                            if @@error<>0 goto FAILURE
                        end
                        update dbo.sysmergesubsetfilters set expand_proc = @procname 
                            where pubid = @pubid and join_filterid = @filter_id and (filter_type & 1) = 1
                    end                    

                    declare @command nvarchar(max)
                    set @dbname = db_name()
                    set @command = 'exec sys.sp_MSmakeexpandproc ' + QUOTENAME(@publication) + ', ' + @filter_id_str + ', ' + @quoted_obj
                    exec @retcode = sys.xp_execresultset @command, @dbname
                    if @retcode <> 0 goto UNDO

                    exec dbo.sp_MS_marksystemobject @quoted_obj
                    if @@ERROR <> 0 goto UNDO

                    exec ('grant execute on ' + @quoted_obj + ' to public')
                    select @filter_id = min(join_filterid) from dbo.sysmergesubsetfilters where
                        pubid = @pubid and join_filterid > @filter_id and (filter_type & 1) = 1
                     
                END                
            END
        END
    END


    /*
    ** Update merge publication property at distributor side if necessaray 
    */
    
    IF @property IN ('description','allow_push', 'allow_pull', 'allow_anonymous','retention', 'allow_subscription_copy', 'retention_period_unit')
    BEGIN

        IF @property IN ('allow_push', 'allow_pull', 'allow_anonymous','allow_subscription_copy')
            
        /* Translate values */
        BEGIN            
            IF LOWER(@value collate SQL_Latin1_General_CP1_CS_AS) = 'true'
                SELECT @value = '1'
            ELSE IF LOWER(@value collate SQL_Latin1_General_CP1_CS_AS) = 'false'
                    SELECT @value = '0'
        END
        else if @property = 'retention_period_unit'
            select @value = convert(nvarchar, @retention_period_unit)
            
        /*
        ** Get distribution server information for remote RPC call.
        */
        EXECUTE @retcode = sys.sp_helpdistributor @rpcsrvname = @distributor OUTPUT,
           @distribdb   = @distribdb OUTPUT
        IF @@ERROR <> 0 or @retcode <> 0
            BEGIN
                GOTO UNDO
            END

        SELECT @dbname =  DB_NAME()
        
        SELECT @distproc = QUOTENAME(RTRIM(@distributor)) + '.' + QUOTENAME(@distribdb) + 
            '.dbo.sp_MSchange_publication'
    
        EXECUTE @retcode = @distproc
            @publisher = @publishingservername,
            @publisher_db = @dbname,
            @publication = @publication,
            @property = @property,
            @value = @value

        IF @@ERROR <> 0 OR @retcode <> 0
        BEGIN
            GOTO UNDO
        END
    END

    if @property = 'use_partition_groups'
    BEGIN
        declare @old_use_partition_groups_value smallint, @dynamic_filters_function_list nvarchar(500)
        declare @new_use_partition_groups_value smallint
        declare @old_snapshot_ready tinyint
        declare @new_snapshot_ready tinyint

        select @old_use_partition_groups_value = use_partition_groups, @old_snapshot_ready = snapshot_ready
        from dbo.sysmergepublications 
        where pubid = @pubid
           
        if @old_use_partition_groups_value is null
        begin
            set @new_use_partition_groups_value = case when @value_bit=1 then 2 else 0 end
            /* Update the use_partition_groups column */
            UPDATE dbo.sysmergepublications 
                SET use_partition_groups = @new_use_partition_groups_value
                WHERE pubid = @pubid
            if @@error <> 0
            BEGIN
                GOTO UNDO
            END
            update dbo.sysmergepublications set snapshot_ready=2 where pubid=@pubid and snapshot_ready=1
        end
        else if (@old_use_partition_groups_value <= 0 and @value_bit = 1)
        begin
            set @new_use_partition_groups_value = 2        -- 2=snapshot agent needs to recreate article triggers accordingly and make other changes required.
            /* Update the use_partition_groups column */
            UPDATE dbo.sysmergepublications 
                SET use_partition_groups = @new_use_partition_groups_value
                WHERE pubid = @pubid
            if @@error <> 0
            BEGIN
                GOTO UNDO
            END
            
            set @new_snapshot_ready = 2                      
            update dbo.sysmergepublications set snapshot_ready=@new_snapshot_ready where pubid=@pubid and snapshot_ready=1

           -- In the snapshot agent, MergeSnapshotProvider.CreateArticleTriggers will only generate merge triggers if the article
	    -- status is inactive/unsynced (value 1) or new_inactive (value 5). So when we transite setupbelongs to use_partition_groups, we need to update
	    -- the article status and make them new_inactive. 
	    -- yiche bug#407427
	    update dbo.sysmergearticles set status = case 
        	                                                            when pubid=@pubid and status=6 then 5
        	                                                            when pubid=@pubid and status=2 then 1
        	                                                            else status
        	                                                         end
	    
            
        end
        else if (@old_use_partition_groups_value >= 1 and @value_bit = 0)
        begin
            -- It is invalid to toggle use_partition_groups to false when logical records feature is used
            if (exists (select * from dbo.sysmergesubsetfilters where pubid = @pubid
                                        and filter_type & 2 = 2)
                                    or exists (select * from dbo.sysmergepartitioninfo where pubid = @pubid
                                        and (logical_record_level_conflict_detection = 1 or logical_record_level_conflict_resolution = 1)))                                        
            begin 
                raiserror(22578, 16, -1, @publication)
                goto UNDO
            end
        
            select top 1 @publication_number = publication_number from dbo.sysmergepublications where pubid = @pubid
            delete from dbo.MSmerge_generation_partition_mappings where publication_number = @publication_number
            delete from dbo.MSmerge_current_partition_mappings where publication_number = @publication_number
            delete from dbo.MSmerge_past_partition_mappings where publication_number = @publication_number
            -- don't delete here since the partitions are still valid. Can be used to keep track of dynamic snapshots
            -- delete from dbo.MSmerge_partition_groups where publication_number = @publication_number
            
            update dbo.sysmergesubscriptions set partition_id = NULL where pubid = @pubid
            
            set @new_use_partition_groups_value = -1
            UPDATE dbo.sysmergepublications 
                SET use_partition_groups = @new_use_partition_groups_value
                WHERE pubid = @pubid
            if @@error <> 0
            BEGIN
                GOTO UNDO
            END
            set @new_snapshot_ready = 2
            update dbo.sysmergepublications set snapshot_ready=@new_snapshot_ready where pubid=@pubid and snapshot_ready=1
	    update dbo.sysmergearticles set status = case 
        	                                                            when pubid=@pubid and status=6 then 5
        	                                                            when pubid=@pubid and status=2 then 1
        	                                                            else status
        	                                                         end
            
            
        end
        
        -- else the value is the same as before. needn't do any further processing.

        -- Insert event into MSmerge_settingshistory
        if (@old_use_partition_groups_value <> @new_use_partition_groups_value)
        begin
            select @eventtype       = 2 -- Change in publication level property

            insert into dbo.MSmerge_settingshistory (eventtime,pubid,artid,eventtype,propertyname,previousvalue,newvalue,eventtext)
            values (default,@pubid,NULL,@eventtype,@property,@old_use_partition_groups_value,@new_use_partition_groups_value,NULL)
        end
        if (@old_snapshot_ready <> @new_snapshot_ready)
        begin
            select @eventtype       = 2 -- Change in publication level property

            insert into dbo.MSmerge_settingshistory (eventtime,pubid,artid,eventtype,propertyname,previousvalue,newvalue,eventtext)
            values (default,@pubid,NULL,@eventtype,N'snapshot_ready',@old_snapshot_ready,@new_snapshot_ready,NULL)
        end
    END

    if @property = 'web_synchronization_url'
    BEGIN

        declare @previousWebSyncUrl nvarchar(500)
        SELECT @previousWebSyncUrl = web_synchronization_url FROM dbo.sysmergepublications WHERE pubid = @pubid

        update dbo.sysmergepublications
            set web_synchronization_url = @value
            where pubid = @pubid
        if @@error <> 0 goto UNDO
        -- Insert event into MSmerge_settingshistory
        if (@previousWebSyncUrl <> @value)
        begin
            select @eventtype       = 2 -- Change in publication level property

            insert into dbo.MSmerge_settingshistory (eventtime,pubid,artid,eventtype,propertyname,previousvalue,newvalue,eventtext)
            values (default,@pubid,NULL,@eventtype,@property,@previousWebSyncUrl,@value,NULL)
        end

    END
    
    if (@property = 'use_partition_groups' or @property = 'allow_subscriber_initiated_snapshot')
        and @value_bit = 0
    begin
        exec @retcode = sys.sp_MSvalidate_wellpartitioned_articles @publication
        if @@error <> 0 or @retcode <> 0
            goto UNDO
    end

    if @property = 'automatic_reinitialization_policy'
    begin
        if convert(int, @value) in (1,0)
        begin

            declare @previousAutoReinitPolicy bit
            SELECT @previousAutoReinitPolicy = automatic_reinitialization_policy FROM dbo.sysmergepublications WHERE pubid = @pubid

            update dbo.sysmergepublications
                set automatic_reinitialization_policy = convert(bit, @value)
                where pubid = @pubid
            if @@error <> 0 goto UNDO


            -- Insert event into MSmerge_settingshistory
            if (@previousAutoReinitPolicy <> convert(bit, @value))
            begin
                select @eventtype       = 2 -- Change in publication level property
    
                insert into dbo.MSmerge_settingshistory (eventtime,pubid,artid,eventtype,propertyname,previousvalue,newvalue,eventtext)
                values (default,@pubid,NULL,@eventtype,@property,@previousAutoReinitPolicy,@value,NULL)
            end

            select @schemaversion = schemaversion from dbo.sysmergeschemachange
            if (@schemaversion is NULL)
                set @schemaversion = 1
            else
                select @schemaversion = 1 + max(schemaversion) from dbo.sysmergeschemachange
                
            set @schemaguid = newid()
            set @artid = null
            set @schematype = @SCHEMA_TYPE_CHANGE_MERGE_PUBLICATION_90RTM
            select @schematext = 'exec dbo.sp_MSchange_mergepublication @pubid = ''' + convert(nchar(36), @pubid) + ''', @property = ''' + @property + ''', @value = ''' + @value + ''''
            exec @retcode=sys.sp_MSinsertschemachange @pubid, @artid, @schemaversion, @schemaguid, @schematype, @schematext
            if @@ERROR<>0 or @retcode<>0 goto UNDO    
        end
        else
        begin
            raiserror(22556, 16, -1, '@automatic_reinitialization_policy')
        end
    end
    
    exec sys.sp_MSreleasemergeadminapplock @lockowner = N'Transaction'
    COMMIT TRAN

    /*
    ** Return succeed.
    */
    
    RAISERROR (14077, 10, -1)
    RETURN (0)
FAILURE:
    
    if @got_merge_admin_applock=1
        exec sys.sp_MSreleasemergeadminapplock @lockowner = N'Transaction'
    raiserror(21371, 10, -1, @publication)
    return (1)   

UNDO: 
    if @@TRANCOUNT > 0
    begin
        if @got_merge_admin_applock=1
            exec sys.sp_MSreleasemergeadminapplock @lockowner = N'Transaction'
        ROLLBACK TRANSACTION changemergepublication
        COMMIT TRANSACTION
    end
GO
GRANT EXECUTE ON [sys].[sp_changemergepublication] TO [public] AS [dbo]
GO
