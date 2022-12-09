SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_changemergearticle]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_changemergearticle] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_changemergearticle]
	@publication [sysname],
	@article [sysname],
	@property [sysname],
	@value [nvarchar](2000),
	@force_invalidate_snapshot [bit],
	@force_reinit_subscription [bit]
WITH EXECUTE AS CALLER
AS
SET NOCOUNT ON

    declare @sp_resolver        sysname
    declare @db_name            sysname
    declare @intvalue           bigint
    declare @artid              uniqueidentifier
    declare @pubid              uniqueidentifier
    declare @artidstr           nvarchar(38)
    declare @object_view        sysname
    declare @vertical           int
    declare @pubidstr           nvarchar(38)
    declare @object             sysname
    declare @owner              sysname
    declare @identity_support   int
    declare @column_list        nvarchar(max)
    declare @resolver_clsid     nvarchar(50)
    declare @article_resolver   nvarchar(255)
    declare @resolver_info      nvarchar(517)
    declare @resolver_clsid_str nvarchar(55)
    declare @article_resolver_str nvarchar(270)
    declare @value_str            nvarchar(517)  
    declare @retcode            int
    declare @statusid           int
    declare @precmdid           tinyint
    declare @sync_mode              tinyint    
    declare @snapshot_ready     int
    declare @schemaversion      int 
    declare @objid              int
    declare @schemaguid         uniqueidentifier
    declare @schematype         int
    declare @schematext         nvarchar(4000)
    declare @type               tinyint
    declare @allow_interactive_bit    int
    declare @published_in_tran_pub_bit  bit
    declare @additive_resolver       sysname
    declare @average_resolver        sysname
    declare @mindate_resolver        sysname
    declare @maxdate_resolver        sysname
    declare @minimum_resolver        sysname
    declare @maximum_resolver        sysname
    declare @mergetxt_resolver       sysname
    declare @pricolumn_resolver      sysname
    declare @pre_command             int
    declare @coltrack                int
    declare @qual_object_view        nvarchar(140)
    declare @qual_object             nvarchar(300)
    declare @quoted_object           nvarchar(140)
    declare @bump_to_80              bit
    declare @schema_option           binary(8)
    declare @old_schema_option       binary(8)
    declare @compatlevel            int
    declare @allow_partition_realignment    bit
    declare @upsert_regenerate_triggersprocs_schemachange bit
    declare @xtype                  int 
    declare @xprec                  int 
    declare @max_range              bigint
    declare @pubname_iter           sysname
    declare @pubid_iter             uniqueidentifier
    declare @delete_tracking        bit
    declare @value_numeric          tinyint
    declare @eventtype              tinyint
    declare @previousbitvalue       bit
    declare @previoustinyintvalue   tinyint
    declare @SCHEMA_TYPE_WELLPARTITIONED int
    declare @SCHEMA_TYPE_ARTICLERESOLVER int
    declare @SCHEMA_TYPE_ARTICLEPROCESSINGORDER int
    declare @SCHEMA_TYPE_PUBLISHED_IN_TRANPUB int
    declare @SCHEMA_TYPE_DELETETRACKING int
    declare @SCHEMA_TYPE_DROPARTICLE int
    declare @publication_has_dynamic_filters bit
    declare @upload_options_tinyint tinyint
    declare @compensate_for_errors  bit
    declare @stream_blob_columns_bit bit
    declare @SCHEMA_TYPE_CHANGE_MERGE_ARTICLE_90RTM int
    declare @pubname_lessthan90compat sysname
    declare @use_partition_groups smallint
    declare @pub_number smallint
    declare @automatic_reinitialization_policy bit
    declare @tablenick int
    declare @dynamic_filters_function_list nvarchar(500)
    declare @is_dotnet_assembly bit
    declare @dotnet_assembly_name nvarchar(255)
    declare @dotnet_class_name nvarchar(255)
    declare @got_merge_admin_applock bit
    declare @num_columns            smallint

    select @got_merge_admin_applock = 0


    /*
    ** Security Check
    */
    EXEC @retcode = sys.sp_MSreplcheck_publish
    IF @@ERROR <> 0 or @retcode <> 0
        return (1)

    select @db_name = db_name()
    select @bump_to_80 = 0
    select @upsert_regenerate_triggersprocs_schemachange = 0
    set @SCHEMA_TYPE_WELLPARTITIONED= 20
    set @SCHEMA_TYPE_ARTICLERESOLVER= 21
    set @SCHEMA_TYPE_ARTICLEPROCESSINGORDER= 22
    set @SCHEMA_TYPE_PUBLISHED_IN_TRANPUB= 23
    set @SCHEMA_TYPE_DELETETRACKING= 27
    set @SCHEMA_TYPE_DROPARTICLE = 28
    set @SCHEMA_TYPE_CHANGE_MERGE_ARTICLE_90RTM = 303
    select @pubname_lessthan90compat = NULL

    /*
    ** Check to see if the database has been activated for publication.
    */

    if (select category & 4
          FROM master.dbo.sysdatabases
         WHERE name = @db_name collate database_default) = 0

    BEGIN
        RAISERROR (14013, 16, -1)
        RETURN (1)
    END

    /*
    ** Parameter Check:     @publication.
    ** Make sure that the publication exists.
    */

    if @publication IS NULL
        BEGIN
            RAISERROR (14043, 16, -1, '@publication', 'sp_changemergearticle')
            RETURN (1)
        END

    select @pubid = pubid, @snapshot_ready=snapshot_ready, @compatlevel=backward_comp_level, 
           @publication_has_dynamic_filters = dynamic_filters, 
           @sync_mode = sync_mode,
           @allow_partition_realignment = allow_partition_realignment,
           @use_partition_groups = use_partition_groups, @pub_number = publication_number,
           @automatic_reinitialization_policy = automatic_reinitialization_policy,
           @dynamic_filters_function_list = dynamic_filters_function_list
    from dbo.sysmergepublications 
    where name = @publication  and UPPER(publisher)=UPPER(publishingservername()) and publisher_db=@db_name
    
    if @pubid IS NULL
    BEGIN
        RAISERROR (20026, 16, -1, @publication)
        RETURN (1)
    END
    
    select @db_name = db_name from dbo.sysmergesubscriptions
        where (pubid=@pubid) and (subid=@pubid)
    IF @db_name <> db_name()
    BEGIN
        RAISERROR (20047, 16, -1)
        RETURN (1)
    END

    /*
    ** Parameter Check:     @property.
    ** If the @property parameter is NULL, print the options.
    */

    if @property IS NULL
    BEGIN
        CREATE TABLE #tab1 (properties sysname collate database_default)
        INSERT INTO #tab1 VALUES ('description')
        INSERT INTO #tab1 VALUES ('pre_creation_command')
        INSERT INTO #tab1 VALUES ('creation_script')
        INSERT INTO #tab1 VALUES ('column_tracking (table article only)')
        INSERT INTO #tab1 VALUES ('article_resolver (table article only)')
        INSERT INTO #tab1 VALUES ('resolver_info (table article only)')
        INSERT INTO #tab1 VALUES ('status')
        INSERT INTO #tab1 VALUES ('subset_filterclause (table article only)')
        INSERT INTO #tab1 VALUES ('schema_option')
        INSERT INTO #tab1 VALUES ('destination_owner')
        INSERT INTO #tab1 VALUES ('pub_identity_range (table article only)')
        INSERT INTO #tab1 VALUES ('identity_range (table article only)')
        INSERT INTO #tab1 VALUES ('threshold (table article only)')
        INSERT INTO #tab1 VALUES ('verify_resolver_signature')
        INSERT INTO #tab1 VALUES ('allow_interactive_resolver')
        INSERT INTO #tab1 VALUES ('check_permissions')
        INSERT INTO #tab1 VALUES ('logical_record_level_conflict_detection')
        INSERT INTO #tab1 VALUES ('logical_record_level_conflict_resolution')
        INSERT INTO #tab1 VALUES ('processing_order')
        INSERT INTO #tab1 VALUES ('published_in_tran_pub')
        INSERT INTO #tab1 VALUES ('subscriber_upload_options (table article only)')
        INSERT INTO #tab1 VALUES ('partition_options (table article only)')
        INSERT INTO #tab1 VALUES ('delete_tracking (table article only)')
        INSERT INTO #tab1 VALUES ('compensate_for_errors (table article only)')
        INSERT INTO #tab1 VALUES ('identityrangemanagementoption')
        INSERT INTO #tab1 VALUES ('stream_blob_columns (table article only)')
        select * FROM #tab1 order by properties
        RETURN (0)
    END

    /*
    ** Check to see that the article exists in dbo.sysmergearticles.
    ** Fetch the article identification number.
    */

    if @article IS NULL
    BEGIN
        RAISERROR (14043, 16, -1, '@article', 'sp_changemergearticle')
        RETURN (1)
    END

    select @artid = artid, 
           @type = type,
           @old_schema_option = schema_option,
           @objid = objid,
           @upload_options_tinyint = upload_options,
           @compensate_for_errors= compensate_for_errors
     FROM dbo.sysmergeextendedarticlesview
        WHERE name = @article AND pubid = @pubid
    if @artid IS NULL
    BEGIN
        RAISERROR (20027, 16, -1, @article)
        RETURN (1)
    END

    /*
    ** Parameter Check:     @property.
    ** Check to make sure that @property is a valid property in
    ** dbo.sysmergearticles.
    */
    if @property IS NULL OR LOWER(@property collate SQL_Latin1_General_CP1_CS_AS) NOT in 
                                                    ('description',
                                                     'pre_creation_command',
                                                     'creation_script',
                                                     'column_tracking',
                                                     'article_resolver',    
                                                     'resolver_info',
                                                     'status',
                                                     'subset_filterclause',
                                                     'schema_option',
                                                     'pub_identity_range',
                                                     'identity_range',
                                                     'threshold',
                                                     'verify_resolver_signature',
                                                     'check_permissions',
                                                     'allow_interactive_resolver',
                                                     'destination_owner',
                                                     'logical_record_level_conflict_detection',
                                                     'logical_record_level_conflict_resolution',
                                                     'partition_options',
                                                     'processing_order',
                                                     'published_in_tran_pub',
                                                     'download_only',
                                                     'subscriber_upload_options',
                                                     'delete_tracking',
                                                     'compensate_for_errors',
                                                     'identityrangemanagementoption',
                                                     'stream_blob_columns')
    BEGIN
        RAISERROR (21259, 16, -1, @property)
        RETURN (1)
    END

    select @pre_command=pre_creation_command, @identity_support = identity_support from dbo.sysmergearticles where pubid=@pubid and artid=@artid
    
    /*
    ** Handle the changing of schema only articles property
    ** in a different procedure
    */
    if @type in (0x20, 0x40, 0x80, 0xA0)
    begin
        exec @retcode = sys.sp_MSchangemergeschemaarticle @pubid = @pubid,
                                                       @artid = @artid,
                                                       @property = @property,
                                                       @value = @value
        return @retcode
    end                

        
    -- COMMENT: the following article properties can not be changed at republisher side
    if    LOWER(@property collate SQL_Latin1_General_CP1_CS_AS) in 
                    ('article_resolver',
                     'resolver_info',
                     'column_tracking',
                     'allow_interactive_resolver',
                     'verify_resolver_signature',
                     'logical_record_level_conflict_detection',
                     'logical_record_level_conflict_resolution',
                     'download_only',
                     'subscriber_upload_options',
                     'delete_tracking',
                     'compensate_for_errors')
            and exists (select * from dbo.sysmergearticles where objid=@objid and pubid not in 
                (select pubid from dbo.sysmergepublications where UPPER(publisher)=UPPER(publishingservername()) 
                    and publisher_db=@db_name))
    BEGIN
        RAISERROR(21400, 16, -1, @article)
        return (1)
    END

    -- Error compensation on non-global replicas is not allowed unless the subscriber_upload_options is set to allow_uploads
    if (
            1 = @compensate_for_errors and
            'subscriber_upload_options' = LOWER(@property collate SQL_Latin1_General_CP1_CS_AS) and
            (convert(int, @value) in (1, 2))
       )
       or
       (
            0 <> @upload_options_tinyint and
            'compensate_for_errors' = LOWER(@property collate SQL_Latin1_General_CP1_CS_AS) and
            'true' = LOWER(@value collate SQL_Latin1_General_CP1_CS_AS)
       )
    begin
        raiserror(20022, 10, -1)
    end

    if @identity_support=0 and LOWER(@property collate SQL_Latin1_General_CP1_CS_AS) in ('pub_identity_range','identity_range','threshold', 'identityrangemanagementoption')
    begin
        RAISERROR(21257, 16, -1, @property, @article)
        return (1)
    end

    if @identity_support=1 and LOWER(@property collate SQL_Latin1_General_CP1_CS_AS) = ('identityrangemanagementoption')
    begin
        if lower(@value collate SQL_Latin1_General_CP1_CS_AS) NOT IN ('manual', 'none')
        begin
            raiserror (25009, 16, -1, @value, @article)
            goto UNDO
        end
    end

    select @objid=objid, @object = object_name(objid), @vertical=vertical_partition from dbo.sysmergearticles where artid=@artid and pubid=@pubid

    exec @retcode = sys.sp_MSget_qualified_name @objid, @qual_object OUTPUT
    if @@ERROR<>0 or @retcode<>0
        goto UNDO
    
    set @artidstr = '''' + convert(nchar(36), @artid) + '''' 
    set @pubidstr = '''' + convert(nchar(36), @pubid) + ''''     
    select @additive_resolver   = formatmessage(21701)
    select @average_resolver    = formatmessage(21702)
    select @mindate_resolver    = formatmessage(21703)
    select @maxdate_resolver    = formatmessage(21704)
    select @minimum_resolver    = formatmessage(21706)
    select @mergetxt_resolver   = formatmessage(21707)
    select @maximum_resolver    = formatmessage(21708)
    select @pricolumn_resolver  = formatmessage(21709)
    select @sp_resolver         = formatmessage(21712)


    BEGIN TRAN
    save TRAN changemergearticle

    exec @retcode = sys.sp_MSgetmergeadminapplock @timeout = 0, -- no wait
                                                  @lockowner = N'Transaction'
    if @retcode<>0 or @@error<>0
    begin
        raiserror(20713, 16, -1, 'sp_changemergearticle', @publication)
        goto UNDO
    end

    select @got_merge_admin_applock = 1

    /*
    ** Changing of the following properties would require a snapshot rerun.and reinit, if snapshot is ready
    */
    if LOWER(@property collate SQL_Latin1_General_CP1_CS_AS) in 
                                                    ('pre_creation_command',
                                                     'creation_script',
                                                     'column_tracking',
                                                     'schema_option',
                                                     'destination_owner',
                                                     'check_permissions',
                                                     'logical_record_level_conflict_detection',
                                                     'logical_record_level_conflict_resolution'
                                                     )
        and @snapshot_ready > 0
    begin
        if @pre_command<>1 -- 1 means'drop': which is the only option that support reintialization
        begin
            raiserror(21416, 16, -1, @property, @article)
            goto UNDO            
        end
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
        
        update dbo.sysmergepublications set snapshot_ready=2 
            where snapshot_ready=1 and
                  pubid in (select pubid from dbo.sysmergearticles where artid=@artid)

        if @@ERROR<>0 GOTO UNDO

        set @pubid_iter= (select top 1 pubid from dbo.sysmergepublications
                                where upper(publisher collate SQL_Latin1_General_CP1_CS_AS) = upper(publishingservername() collate SQL_Latin1_General_CP1_CS_AS) and
                                        publisher_db = db_name() and
                                      pubid in (select pubid from dbo.sysmergearticles 
                                                    where artid=@artid)
                                order by pubid asc)
        
        while @pubid_iter is not null
        begin
            select @pubname_iter= name from dbo.sysmergepublications where pubid=@pubid_iter

            exec @retcode= sys.sp_MSreinitmergepublication 
                                    @publication = @pubname_iter,
                                    @upload_first = @automatic_reinitialization_policy
            if @@ERROR<>0 or @retcode<>0 GOTO UNDO

            set @pubid_iter= (select top 1 pubid from dbo.sysmergepublications
                                    where pubid > @pubid_iter and
                                           upper(publisher collate SQL_Latin1_General_CP1_CS_AS) = upper(publishingservername() collate SQL_Latin1_General_CP1_CS_AS) and
                                              publisher_db = db_name() and
                                            pubid in (select pubid from dbo.sysmergearticles 
                                                        where artid=@artid)
                                    order by pubid asc)
        end
    end

    if LOWER(@property collate SQL_Latin1_General_CP1_CS_AS) = 'subset_filterclause' and @snapshot_ready > 0
    begin
        if @pre_command<>1 -- 1 means'drop': which is the only option that support reintialization
        begin
            raiserror(21416, 16, -1, @property, @article)
            goto UNDO            
        end
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
        
        update dbo.sysmergepublications set snapshot_ready=2 
            where snapshot_ready=1 and
                  pubid=@pubid

        if @@ERROR<>0 GOTO UNDO

        exec @retcode= sys.sp_MSreinitmergepublication 
                              @publication = @publication,
                              @upload_first = @automatic_reinitialization_policy
        if @@ERROR<>0 or @retcode<>0 GOTO UNDO
    end

    if lower(@property collate SQL_Latin1_General_CP1_CS_AS) = 'compensate_for_errors'
    begin
        if lower(@value collate SQL_Latin1_General_CP1_CS_AS) NOT IN ('true', 'false')
        begin
            raiserror (14137, 16, -1)
            goto UNDO
        end
            
        if lower(@value collate SQL_Latin1_General_CP1_CS_AS) = 'true'
        begin
            set @value_numeric= 1
        end
        else
        begin
            set @value_numeric= 0
        end
        
        -- Exit if the value is set to itself.
        if exists (select * from dbo.sysmergearticles 
                        where artid=@artid and compensate_for_errors = @value_numeric)
        begin
            goto UNDO
        end

        /*  Insert event in the MSmerge_settingshistory table if the
        new value is different from the old value
        Look in replsys.sql where the table is created for more
        details about what is in this table. */
            

        select @previousbitvalue = compensate_for_errors from dbo.sysmergearticles 
            where artid=@artid

        update dbo.sysmergearticles 
            set compensate_for_errors= @value_numeric
            where artid=@artid

        select @eventtype       = 102
            
        insert into dbo.MSmerge_settingshistory (eventtime,pubid,artid,eventtype,propertyname,previousvalue,newvalue,eventtext)
            values (default,@pubid,@artid,@eventtype,@property,@previousbitvalue,@value_numeric,NULL)

        if @snapshot_ready > 0
        begin
            -- Insert a schemachange for all publications the article belongs to.
            exec @retcode= sys.sp_MSchange_mergearticle 
                                @pubid= @pubid,
                                @artid= @artid,
                                @property='compensate_for_errors',
                                @value_numeric= @value_numeric

            if @retcode<>0 or @@error<>0 goto UNDO
        end
    end

    if LOWER(@property collate SQL_Latin1_General_CP1_CS_AS) = 'subscriber_upload_options'
    BEGIN
        -- If the upaload_options property is changed from true (1, 2) to false, non-global replicas
        -- need to be reinitialized. If it is changed from false to true, non-global replicas
        -- need to recreate triggers and procs, and contents/tombstone entries are deleted.

        -- Check to make sure that we have a valid type.
        select @value_numeric = convert(int, @value)
        if @value_numeric not in (0, 1, 2)
        BEGIN
            RAISERROR (22542, 16, -1)
            goto UNDO
        END
        
        -- Exit if the value is set to itself.
        if exists (select * from dbo.sysmergearticles 
                        where artid=@artid and upload_options = @value_numeric)
        begin
            goto UNDO
        end

        -- Publications must have 9.0 compat level at least.
        if 0 <> @value_numeric and
           exists(select * from dbo.sysmergepublications
                       where backward_comp_level < 90 and
                             pubid in (select pubid from dbo.sysmergearticles where artid=@artid))
        begin
            raiserror(21522, 16, -1, 'subscriber_upload_options', @publication)
            goto UNDO
        end

        -- upload options can not be set to allow uploads when allow_partition_realignment is set
        -- to false or else it can lead to upload of out of partition updates.
        if 0 = @value_numeric and @allow_partition_realignment = 0
        begin
            raiserror(22543, 16, -1)
            goto UNDO
        end

		--co-existance of uploadable merge article on queued subscription table may cause non-convergence in tran pub since queued trigger is NFR
		--allow it in case some customer rely on this already, write warning to errorlog so we can track this condition
		if (0 = @value_numeric) and (object_id('dbo.MSsubscription_articles') is not null)
		begin
			if exists(select * from dbo.MSsubscription_articles where object_id(quotename(owner) + N'.' + quotename(dest_table)) = @objid)
			begin
				raiserror(21860, 10, -1, @object, @db_name) WITH LOG
			end
		end

        select @previoustinyintvalue = upload_options from dbo.sysmergearticles 
            where artid=@artid

        -- If the upload_options property is changed from 0 to non-zero,
        -- any non-global subscription (containing that article) to that publisher
        -- or to a republisher needs to be reinitialized. As we cannot know whether
        -- a republisher has such a subscription, we require @force_reinit_subscription
        -- as an acknowledgement that some subscriptions MIGHT be reinitialized.
        if ((@previoustinyintvalue = 0)and 
            (0 <> @value_numeric) and 
            (@snapshot_ready > 0) and 
            (0=@force_reinit_subscription))
        begin
            raiserror(20006, 16, -1)
            goto UNDO
        end

        -- Insert a schemachange for all publications the article belongs to.
        exec @retcode= sys.sp_MSchange_mergearticle 
                            @pubid= @pubid,
                            @artid= @artid,
                            @property='subscriber_upload_options',
                            @value_numeric= @value_numeric
        
        if @retcode<>0 or @@error<>0 goto UNDO

        select @eventtype       = 102
            
        /*  Insert event in the MSmerge_settingshistory table if the
            new value is different from the old value
            Look in replsys.sql where the table is created for more
            details about what is in this table. */
            
        insert into dbo.MSmerge_settingshistory (eventtime,pubid,artid,eventtype,propertyname,previousvalue,newvalue,eventtext)
            values (default,@pubid,@artid,@eventtype,@property,@previoustinyintvalue,@value_numeric,NULL)

    END
            
    /*
    ** Change the property.
    */
    if LOWER(@property collate SQL_Latin1_General_CP1_CS_AS) = 'column_tracking'
    BEGIN
        /*
        ** Check to make sure that we have a valid type.
        */
        if LOWER(@value collate SQL_Latin1_General_CP1_CS_AS) NOT IN ('true', 'false')
        BEGIN
            RAISERROR (14137, 16, -1)
            goto UNDO
        END

        if LOWER(@value collate SQL_Latin1_General_CP1_CS_AS) = 'true'
        begin
            select @num_columns=count(*) from sys.columns where object_id = @objid

            -- Colvs can only handle 246 columns so we can not allow more than 246 columns to exist on a table
            -- if column tracking is being used. The reason is that we track all the columns even when vertical
            -- partitioning is used and only some of the columns are published.
            if @num_columns > 246
            begin
                RAISERROR (25020, 16, -1, @article, 246)
                goto UNDO
            end
            update dbo.sysmergearticles set column_tracking = 1 where artid=@artid        
        end
        else
            update dbo.sysmergearticles set column_tracking = 0 where artid=@artid
        if @@ERROR <> 0 
            goto UNDO

    END
        
    /*
    ** Change the property.
    */
    if LOWER(@property collate SQL_Latin1_General_CP1_CS_AS) = 'logical_record_level_conflict_detection'
        BEGIN
            /*
            ** Check to make sure that we have a valid type.
            */
            if LOWER(@value collate SQL_Latin1_General_CP1_CS_AS) NOT IN ('true', 'false')
                BEGIN
                    RAISERROR (14137, 16, -1)
                    goto UNDO
                END

            /*
            ** Update the syssubsetdefintions table with the new logical_record_level_conflict_detection
            */
            if LOWER(@value collate SQL_Latin1_General_CP1_CS_AS) = 'true'
            begin
                -- Only supported with publications that have 90 compatibility level.
                select top 1 @pubname_lessthan90compat = name from dbo.sysmergepublications 
                where backward_comp_level < 90
                and pubid in 
                    (select pubid from dbo.sysmergearticles where objid = @objid)
                    
                if @pubname_lessthan90compat is not null
                begin
                    raiserror(21574, 16, -1, @article, @pubname_lessthan90compat)
                    goto UNDO
                end
                
                if exists (select * from dbo.sysmergepublications where pubid = @pubid and sync_mode = 1)
                begin
                    raiserror(22541, 16, -1, @publication)
                    goto UNDO
                end
                
                if exists (select * from dbo.sysmergepublications where pubid = @pubid and allow_web_synchronization = 1)
                begin
                    raiserror(22545, 16, -1, @publication)
                    goto UNDO
                end


                -- Cannot use Logical records and BusinessLogicResolvers at the same time.
                if exists (select * from dbo.sysmergearticles where (objid = @objid) and resolver_clsid = '00000000-0000-0000-0000-000000000000')
                begin
                    raiserror(20708, 16, -1)
                    goto UNDO
                end
                
                -- based on usability feeback, we should set the allow_subscriber_initiated_snapshot
                -- option to 1 rather than raise an error.
                update dbo.sysmergepublications set allow_subscriber_initiated_snapshot = 1
                    where pubid = @pubid
                
                if exists (select * from dbo.sysmergepartitioninfo where artid=@artid and pubid = @pubid
                            and logical_record_level_conflict_resolution = 0)
                begin
                    raiserror(21728, 16, -1)
                    goto UNDO
                end
                update dbo.sysmergepartitioninfo set logical_record_level_conflict_detection = 1 
                where artid=@artid and pubid = @pubid
            end
            else
            begin
                update dbo.sysmergepartitioninfo set logical_record_level_conflict_detection = 0 
                    where artid=@artid and pubid = @pubid
            end
            if @@ERROR <> 0 
                goto UNDO

        END

    /*
    ** Change the property.
    */
    if LOWER(@property collate SQL_Latin1_General_CP1_CS_AS) = 'logical_record_level_conflict_resolution'
    BEGIN
        /*
        ** Check to make sure that we have a valid type.
        */
        if LOWER(@value collate SQL_Latin1_General_CP1_CS_AS) NOT IN ('true', 'false')
        BEGIN
            RAISERROR (14137, 16, -1)
            goto UNDO
        END

        /*
        ** Update the syssubsetdefintions table with the new logical_record_level_conflict_resolution
        */
        if LOWER(@value collate SQL_Latin1_General_CP1_CS_AS) = 'true'
        begin
        
            -- Only supported with publications that have 90 compatibility level.
            select top 1 @pubname_lessthan90compat = name from dbo.sysmergepublications 
            where backward_comp_level < 90
            and pubid in 
                (select pubid from dbo.sysmergearticles where objid = @objid)
                
            if @pubname_lessthan90compat is not null
            begin
                raiserror(21574, 16, -1, @article, @pubname_lessthan90compat)
                goto UNDO
            end
            
            if exists (select * from dbo.sysmergepublications where pubid = @pubid and sync_mode = 1)
            begin
                raiserror(22541, 16, -1, @publication)
                goto UNDO
            end
            
            if exists (select * from dbo.sysmergepublications where pubid = @pubid and allow_web_synchronization = 1)
            begin
                raiserror(22545, 16, -1, @publication)
                goto UNDO
            end
        
            -- Cannot use Logical records and BusinessLogicResolvers at the same time.
            if exists (select * from dbo.sysmergearticles where (objid = @objid) and resolver_clsid = '00000000-0000-0000-0000-000000000000')
            begin
                raiserror(20708, 16, -1)
                goto UNDO
            end

            -- based on usability feeback, we should set the allow_subscriber_initiated_snapshot
            -- option to 1 rather than raise an error.
            update dbo.sysmergepublications set allow_subscriber_initiated_snapshot = 1
                where pubid = @pubid
                    
            update dbo.sysmergepartitioninfo set logical_record_level_conflict_resolution = 1 
                where artid=@artid and pubid = @pubid
        end
        else
        begin
            if exists (select * from dbo.sysmergepartitioninfo where artid=@artid and pubid = @pubid
                            and logical_record_level_conflict_detection = 1)
            begin
                raiserror(21728, 16, -1)
                goto UNDO
            end
            update dbo.sysmergepartitioninfo set logical_record_level_conflict_resolution = 0 
                where artid=@artid and pubid = @pubid
        end
        if @@ERROR <> 0 
            goto UNDO

    END
        
    if LOWER(@property collate SQL_Latin1_General_CP1_CS_AS) = 'partition_options'
    BEGIN
        /*
        ** Check to make sure that we have a valid type.
        */
        select @value_numeric = convert(tinyint, @value)
        if @value_numeric NOT IN (0, 1, 2, 3)
        BEGIN
            RAISERROR (22526, 16, -1, '@partition_options')
            goto UNDO
        END
        
        if @compatlevel < 90 and @value_numeric IN (1, 2, 3)
        begin
            raiserror(20681, 16, -1, @publication)
            goto UNDO
        end

        update dbo.sysmergepartitioninfo set partition_options = @value_numeric
            where artid=@artid and pubid = @pubid     
        if @@ERROR <> 0 goto UNDO

        -- make sure we only have one published entry for this article. we could have had multiple
        -- rows for one article in different publications as long as all entries were
        -- not well-partitioned. but changing even one of those entries to well-partitioned
        -- cannot be allowed. Only allow changing to well-partitioned if this is the only published entry.            
        if @value_numeric in (2, 3)
        begin
            exec @retcode = sys.sp_MSvalidate_wellpartitioned_articles @publication
            if @@error <> 0 or @retcode <> 0 goto UNDO

            -- raise warning indicating that changes from subscriber in one partition
            -- won't be propagated to subscribers in other partitions.
            raiserror(22520, 10, -1)
        end

        if @snapshot_ready > 0
        begin
            select @schemaversion = 1 + max(schemaversion) from dbo.sysmergeschemachange
            if @schemaversion is NULL
                set @schemaversion = 1
            set @schemaguid = newid()
            
            set @schematype = @SCHEMA_TYPE_WELLPARTITIONED
            select @schematext = 'exec dbo.sp_MSchange_mergearticle @pubid = ''' + convert(nchar(36), @pubid) + ''', @artid = ''' + convert(nchar(36), @artid) + ''', @property = ''partition_options'', @value =' +  sys.fn_replquotename(@value,'''') +', @value_numeric = ''' + cast(@value_numeric as nchar(1)) + ''''
                                     
            exec @retcode = sys.sp_MSinsertschemachange @pubid, @artid, @schemaversion, @schemaguid, @schematype, @schematext
            if @@ERROR <> 0 OR @retcode <> 0 goto UNDO
                
            select @upsert_regenerate_triggersprocs_schemachange = 1
        end        
    END

    -- The identity management for the article is being disabled.
    -- This will call a proc that drops the repl_identity_range constraint that will 
    -- propagate as a schema change to the subscriber.
    if @identity_support=1 and LOWER(@property collate SQL_Latin1_General_CP1_CS_AS) = ('identityrangemanagementoption')
    begin
        if @force_reinit_subscription = 0
        begin
            raiserror(20608, 16, -1)
            goto UNDO
        end
        
        exec @retcode = sys.sp_MSremoveidrangesupport @pubid, @artid, 1 /* @propagate_ddl_change */ 
        IF @@ERROR <> 0 or @retcode <> 0 goto UNDO

        exec @retcode= sys.sp_MSreinitmergepublication 
        		@publication = @publication,
                     @upload_first = @automatic_reinitialization_policy
        if @@ERROR<>0 or @retcode<>0 GOTO UNDO
            
        update dbo.sysmergearticles set identity_support=0 where artid=@artid and pubid=@pubid
    end

    -- whenever pub_identity_range, identity_range or threshold are used we will just
    -- update sysmergearticles and not do any reseed. Only the next request for a new
    -- identity range will use these new values.
    declare @pub_identity_range bigint
    declare @identity_range bigint
    if LOWER(@property collate SQL_Latin1_General_CP1_CS_AS) = 'pub_identity_range'
    BEGIN
        select @pub_identity_range = convert(bigint, @value)

        select @identity_range = range from dbo.sysmergearticles where artid = @artid and sys.fn_MSmerge_islocalpubid(pubid)=1
        if IDENT_INCR(@qual_object) < 0
            select @identity_range = -1*@identity_range
        
        exec @retcode = sys.sp_MScheck_autoident_parameters
                                    @qual_object,
                                    @pub_identity_range,
                                    @identity_range
        if @retcode<>0 or @@error<>0
            goto UNDO
            
        if exists (select pubid from dbo.sysmergearticles where artid=@artid and pubid<>@pubid and sys.fn_MSmerge_islocalpubid(pubid)=0)
        begin
            exec @retcode = sys.sp_MScheck_republisher_ranges @qual_object, @artid, @pub_identity_range, @identity_range
            if @retcode<>0 or @@error<>0
                goto UNDO
        end

        if IDENT_INCR(@qual_object) < 0
            select @pub_identity_range = -1*@pub_identity_range
        update dbo.sysmergearticles set pub_range = @pub_identity_range where artid=@artid and sys.fn_MSmerge_islocalpubid(pubid)=1
        if @@ERROR<>0
            goto UNDO
    END
     
    if LOWER(@property collate SQL_Latin1_General_CP1_CS_AS) = 'identity_range'
    BEGIN
        select @identity_range = convert(bigint, @value)

        select @pub_identity_range = pub_range from dbo.sysmergearticles where artid = @artid and sys.fn_MSmerge_islocalpubid(pubid)=1
        
        if IDENT_INCR(@qual_object) < 0
            select @pub_identity_range = -1*@pub_identity_range
        exec @retcode = sys.sp_MScheck_autoident_parameters
                                    @qual_object,
                                    @pub_identity_range,
                                    @identity_range
        if @retcode<>0 or @@error<>0
            goto UNDO
            
        if exists (select pubid from dbo.sysmergearticles where artid=@artid and pubid<>@pubid and sys.fn_MSmerge_islocalpubid(pubid)=0)
        begin
            exec @retcode = sys.sp_MScheck_republisher_ranges @qual_object, @artid, @pub_identity_range, @identity_range
            if @retcode<>0 or @@error<>0
                goto UNDO
        end

        if IDENT_INCR(@qual_object) < 0
            select @identity_range = -1*@identity_range
        update dbo.sysmergearticles set range = @identity_range where artid=@artid and sys.fn_MSmerge_islocalpubid(pubid)=1
        if @@ERROR<>0
            goto UNDO
    END

    if LOWER(@property collate SQL_Latin1_General_CP1_CS_AS) = 'threshold'
    BEGIN
        declare @threshold int
        
        select @threshold = convert(int, @value)
        if @threshold<1 or @threshold>100
        begin
            raiserror(21241, 16, -1)
            goto UNDO
        end

        update dbo.sysmergearticles set threshold = @threshold where artid=@artid and sys.fn_MSmerge_islocalpubid(pubid)=1
        if @@ERROR<>0
            goto UNDO
    END

    
    /* the property of check permissions is a bitmask of which operation do we want to check for*/     
    if LOWER(@property collate SQL_Latin1_General_CP1_CS_AS) = 'check_permissions'
    BEGIN
        select @intvalue = convert(int, @value)
        if @intvalue<0
        begin
            raiserror(21232, 16, -1)
            goto UNDO
        end
        update dbo.sysmergearticles set check_permissions=@intvalue WHERE artid = @artid and pubid = @pubid
        if @@ERROR<>0
            goto UNDO        
    END



    if LOWER(@property collate SQL_Latin1_General_CP1_CS_AS)='description'
    BEGIN
        UPDATE dbo.sysmergearticles     SET description = @value WHERE artid = @artid and pubid = @pubid
            AND pubid = @pubid
        if @@ERROR <> 0 
                goto UNDO
    END

    if LOWER(@property collate SQL_Latin1_General_CP1_CS_AS) ='creation_script'
    BEGIN
        update dbo.sysmergearticles set creation_script=@value where artid=@artid and pubid=@pubid
        if @@ERROR <> 0 
            goto UNDO
    END

    if LOWER(@property collate SQL_Latin1_General_CP1_CS_AS) = 'subset_filterclause'
    BEGIN
        if @value is not null and @value<>''
        begin
            /* check the validity of subset_filterclause */
            select @object_view=@object
            select @quoted_object=QUOTENAME(@object)    
            select @qual_object_view=@qual_object
            
            if @vertical=1
            begin
              select @object_view='TEMP_VIEW_' + @object
              select @qual_object_view = QUOTENAME(@object_view)
              exec @retcode = sys.sp_MSgetcolumnlist @pubid, @column_list OUTPUT, @objid
              exec ('create view dbo.' + @qual_object_view + ' as select ' + @column_list + ' from ' + @quoted_object)
              if @@ERROR<>0
              begin
                raiserror(21256, 16, -1, @value, @object)
                goto UNDO
              end
            end
            
            exec ('declare @test int select @test=1 from ' + @qual_object_view + ' ' + @quoted_object + ' where ' + @value)
            if @@ERROR<>0
            begin
                if @vertical=1
                    exec('drop view ' + @qual_object_view)
                raiserror(21256, 16, -1, @value, @object)
                goto UNDO
            end
            if @vertical=1
                exec('drop view ' + @qual_object_view)

            -- check if the subsetfilter clause contains a computed column. To do this get a list of computed columns
            -- for the given article. Then check if the filter name is like the computed column
            declare @computedcolname sysname
                        
            declare compted_columns_cursor cursor LOCAL FAST_FORWARD
            for (select name from sys.columns where object_id = @objid and is_computed=1)
            open compted_columns_cursor
            fetch compted_columns_cursor into @computedcolname
            while (@@fetch_status <> -1)
            begin
                
                if sys.fn_MSisfilteredcolumn(@value, @computedcolname, @objid) = 1 
                begin
                    raiserror(20656, 16, -1)
                    goto UNDO
                end
                fetch compted_columns_cursor into @computedcolname
            end
            close compted_columns_cursor
            deallocate compted_columns_cursor


            -- check if the subsetfilter clause contains any column of type that is not supported in
            --  a subset filter.

            if exists (
                        select * from sys.columns
                            where object_id = @objid and 
                            (
                            --(sys.fn_IsTypeBlob(sc.system_type_id,sc.max_length) = 1) -- Blob type text,ntext,xml
                              (system_type_id in (type_id('image'), type_id('text'), type_id('ntext'), type_id('xml')))
                                or max_length = -1
                                or system_type_id = 240    -- CLR-UDTs
                            )
                            and 
                            sys.fn_MSisfilteredcolumn(@value, name, @objid) = 1 
                        )
            begin
                    raiserror(22518, 16, -1, @qual_object)
                    goto UNDO
            end
        end

        update dbo.sysmergearticles set subset_filterclause = @value where artid=@artid and pubid=@pubid
        if @@ERROR<>0 goto UNDO
        
        /*
        ** set the pub type to subset or full as appropriate
        */
        execute @retcode = sys.sp_MSsubsetpublication @publication
        if @@ERROR <> 0 OR @retcode <> 0
            goto UNDO
            
        if @value is not null and @value<>''
        begin
            declare @article_has_dynamic_filters bit
            declare @functions_in_subset_filter nvarchar(500)
            
            -- check if this is a dynamically filtered article and this is not a dynamically filtered publication
            select @article_has_dynamic_filters = 0
            exec @retcode = sys.sp_check_subset_filter @qual_object, @value, @article_has_dynamic_filters output, @functions_in_subset_filter  output
            if @retcode<>0 or @@ERROR<>0
            begin
                raiserror(20641, 16, -1)
                goto UNDO
            end
            if @article_has_dynamic_filters = 1 and @publication_has_dynamic_filters = 0
            begin
                -- we have already done a re init and invalidated snapshot. 
                -- the new snapshot that is run will generate 'dynamic' schema changes
                -- don't delete dropmergearticle schemachange.                
                delete from dbo.sysmergeschemachange where pubid = @pubid and schematype not in (@SCHEMA_TYPE_DROPARTICLE)
                  if @@ERROR<>0 goto UNDO
                update dbo.sysmergepublications set use_partition_groups=2 where pubid=@pubid and use_partition_groups=1
                  if @@ERROR<>0 goto UNDO

                -- Since this is called from sp_changemergearticle, make sure it doesn't raise errors since it is premature stage of the publication. 
                -- The snapshot calls this with @dont_raise_error = NULL which should raise appropriate errors
                exec @retcode = sys.sp_MSset_dynamic_filter_options @publication = @publication, @dynamic_filters = @publication_has_dynamic_filters OUTPUT, @dont_raise_error = 1
                if @retcode<>0 or @@ERROR<>0 goto UNDO
            end
            
            -- if the subset_filterclause is being set to something difference we will blow all the partition information we have
            -- this is needed because the existing partitions may not be valid any more. Since all subscriptions are
            -- anyway being reinitialized it should not cause any problems.
            if @article_has_dynamic_filters = 1 and @functions_in_subset_filter <> @dynamic_filters_function_list
            begin
                 if @use_partition_groups > 0
                 begin
                     delete from dbo.MSmerge_current_partition_mappings where publication_number = @pub_number
                     if @@error <> 0 goto UNDO
                     delete from dbo.MSmerge_past_partition_mappings where publication_number = @pub_number
                     if @@error <> 0 goto UNDO
                     delete from dbo.MSmerge_generation_partition_mappings where publication_number = @pub_number
                     if @@error <> 0 goto UNDO
                     update dbo.sysmergepublications set use_partition_groups = 2 where pubid = @pubid
                     if @@error <> 0 goto UNDO
                 end
                 
                 exec @retcode = sys.sp_MSdropmergedynamicsnapshotjob @publication = @publication
                 if @@error <> 0 or @retcode <> 0
                     goto UNDO
     
                 delete from dbo.MSmerge_dynamic_snapshots where partition_id in
                     (select partition_id from dbo.MSmerge_partition_groups where publication_number = @pub_number)
                 if @@error <> 0 goto UNDO
                     
                 delete from dbo.MSdynamicsnapshotjobs where partition_id in
                     (select partition_id from dbo.MSmerge_partition_groups where publication_number = @pub_number)
                 if @@error <> 0 goto UNDO
                 
                 delete from dbo.MSmerge_partition_groups where publication_number = @pub_number
                 if @@error <> 0 goto UNDO
     
                 update dbo.sysmergepublications 
                 set dynamic_filters_function_list = NULL, 
                     dynamic_filters = 0
                     where pubid = @pubid
                 if @@error <> 0 goto UNDO
                 
                 -- Since this is called from sp_changemergearticle, make sure it doesn't raise errors since it is premature stage of the publication. 
                 -- The snapshot calls this with @dont_raise_error = NULL which should raise appropriate errors
                 exec @retcode = sys.sp_MSset_dynamic_filter_options @publication = @publication, @dynamic_filters = @publication_has_dynamic_filters OUTPUT, @dont_raise_error = 1
                 if @retcode<>0 or @@ERROR<>0 goto UNDO
            end
        end
    END

    if LOWER(@property collate SQL_Latin1_General_CP1_CS_AS) ='article_resolver'
    BEGIN

        if @value IS NULL OR @value = 'default' OR @value = ''
        begin
            set @article_resolver = NULL
            set @resolver_clsid = NULL
            set @value = NULL
            set @resolver_info = NULL
        end                    
                
        else
        begin
            EXECUTE @retcode = sys.sp_lookupcustomresolver @value, @resolver_clsid OUTPUT
            IF @@ERROR <> 0 or @retcode <> 0 or @resolver_clsid IS NULL
            BEGIN
                RAISERROR (20020, 16, -1, @article_resolver)
                goto UNDO
            END
        end                        

        -- Cannot use Logical records and BusinessLogicResolvers at the same time.
        if @resolver_clsid = '00000000-0000-0000-0000-000000000000'
        begin

            if exists (select * from dbo.sysmergepartitioninfo 
                        where (artid = @artid) and
                              ((logical_record_level_conflict_detection = 1) or
                               (logical_record_level_conflict_resolution = 1)))
            begin
                raiserror(20708, 16, -1)
                goto UNDO
            end


            select @tablenick = nickname from dbo.sysmergearticles where artid = @artid
            
            if exists (select * from dbo.sysmergesubsetfilters 
                        where ((@tablenick =  art_nickname) or
                               (@tablenick =  join_nickname)) and
                               (filter_type & 2 = 2))
            begin
                raiserror(20708, 16, -1)
                goto UNDO
            end

            
        end
                
        /*
        ** Update the appropriate column in dbo.sysmergearticles with the new article resolver name.
        ** Note this could affect multiple publication if the same table spans publications
        */

        /* NOTE: new change */
        if @resolver_clsid = '00000000-0000-0000-0000-000000000000'
        begin
            EXECUTE @retcode = sys.sp_lookupcustomresolver @value, @resolver_clsid OUTPUT, @is_dotnet_assembly OUTPUT, @dotnet_assembly_name OUTPUT, @dotnet_class_name OUTPUT
            if @dotnet_assembly_name IS NULL 
                begin
                    RAISERROR (21856, 16, -1, @article_resolver)
                    return (1)
                end
            if @dotnet_class_name IS NULL 
                begin
                    RAISERROR (21808, 16, -1, @article_resolver)
                    return (1)
                end
            exec @retcode = sys.sp_MSchangearticleresolver @article_resolver = @dotnet_assembly_name, @resolver_clsid = @resolver_clsid, @artid = @artid, @resolver_info = @dotnet_class_name
            if @@ERROR <> 0 OR @retcode <> 0
            begin
                goto UNDO                           
            end     
        end
        else
        begin
            exec @retcode = sys.sp_MSchangearticleresolver @value, @resolver_clsid, @artid
            if @@ERROR <> 0 OR @retcode <> 0
            begin
                goto UNDO                           
            end     
        end
        
        declare one_pub CURSOR LOCAL FAST_FORWARD FOR 
            select DISTINCT pubid from dbo.sysmergearticles where artid=@artid
        FOR READ ONLY
        open one_pub
        fetch next from one_pub into @pubid
         
        while (@@fetch_status <> -1)
        begin
            select @snapshot_ready=snapshot_ready from dbo.sysmergepublications 
                where pubid = @pubid
            /* Insert the sp_MSchangearticleresolver schema change only if the publication's snapshot is ready */
            if (@snapshot_ready > 0)
            begin
                select @schemaversion = schemaversion from dbo.sysmergeschemachange
                if (@schemaversion is NULL) 
                    set @schemaversion = 1
                else  
                    select @schemaversion = 1 + max(schemaversion) from dbo.sysmergeschemachange
                set @schemaguid = newid()
                set @schematype = @SCHEMA_TYPE_ARTICLERESOLVER
                if @value is not NULL and @value <> ''
                    select @schematext = 'exec dbo.sp_MSchangearticleresolver ' +  quotename(@value) + ',' + quotename (@resolver_clsid,'''')  + ',' + '''' + convert(nchar(36), @artid) + ''''
                else
                    select @schematext = 'exec dbo.sp_MSchangearticleresolver NULL, NULL,' + '''' + convert(nchar(36), @artid) + ''''
                     
                exec @retcode = sys.sp_MSinsertschemachange @pubid, @artid, @schemaversion, @schemaguid, @schematype, @schematext
                if @@ERROR <> 0 OR @retcode <> 0
                    goto UNDO
            end                                        
            fetch next from one_pub into @pubid
        end 
        close one_pub
        deallocate one_pub

    END /* for property = 'article_resolver' */

    if LOWER(@property collate SQL_Latin1_General_CP1_CS_AS) ='resolver_info'
    BEGIN
        /* allow non-sp's as resolver info; don't change the resolver class */
        select    @article_resolver = article_resolver, 
                @resolver_clsid = resolver_clsid from
                dbo.sysmergearticles where artid = @artid

        -- Convert NULL value to 'NULL' string to be used for constructing schema text
        -- we do not want to change NULL value to ''.
        select @article_resolver_str=QUOTENAME(@article_resolver)
        select @resolver_clsid_str = @resolver_clsid
        select @value_str=@value
        if @article_resolver is null set @article_resolver_str = 'NULL'
        if @resolver_clsid is null set @resolver_clsid_str = 'NULL'
        if @value is null set @value_str = 'NULL'

        /* The following resolvers expect the @resolver_info to be NON NULL */
        if    @article_resolver = @sp_resolver or 
            @article_resolver = @additive_resolver or
            @article_resolver = @average_resolver or
            @article_resolver = @minimum_resolver or
            @article_resolver = @maximum_resolver or
            @article_resolver = @mindate_resolver or
            @article_resolver = @maxdate_resolver or
            @article_resolver = @mergetxt_resolver or
            @article_resolver = @pricolumn_resolver
            begin
                if @value IS NULL or @value = ''
                    begin
                        RAISERROR (21301, 16, -1, @article_resolver)
                        goto UNDO
                    end
            end

        /* The SP resolver expect the @resolver_info to be the name of sp */
        if    @article_resolver = @sp_resolver
            begin
                if not exists (select * from sys.objects where object_id = object_id(@value) and ( type = 'P' or type = 'X'))
                begin
                    raiserror(21343, 16, -1, @value)
                    goto UNDO
                end
            end
        /*
        ** If article resolver is 'mindate/maxdate resolver', make sure that resolver_info refers to a column that is of datatype 'datetime' or smalldatetime
        */
        if  @article_resolver = @mindate_resolver or
            @article_resolver = @maxdate_resolver
        begin
            if not exists (select * from sys.columns where object_id = @objid and name=@value and (system_type_id=type_id('datetime') or system_type_id=type_id('smalldatetime')
	            or system_type_id=type_id('datetime2')
	            or system_type_id=type_id('date')
	            or system_type_id=type_id('time')))
            begin
                RAISERROR (21302, 16, -1, @article_resolver)
                goto UNDO
            end
        end

        /* The following resolvers expect the article to be column trcaked - warn that the default resolver migh be used */
        if    @article_resolver = @additive_resolver or
            @article_resolver = @average_resolver
        begin
            select @coltrack = column_tracking from dbo.sysmergearticles where artid = @artid
            if @coltrack = 0
                begin
                    RAISERROR (21303, 10, -1, @article, @article_resolver)
                end
                
        end
            
        /*
        ** Update the appropriate column in dbo.sysmergearticles with the new resolver info.
        ** Note this could affect multiple publication if the same table spans publications
        */

        /* NOTE: new change */
        -- If the resolver's CLSID indicates that it is a .NET assembly, then do not allow the update to NULL, leave it as default .NET Class Name associated with the assembly
        if (@resolver_clsid = '00000000-0000-0000-0000-000000000000' and (@value IS NULL or @value = ''))
        begin
            goto COMMIT_LABEL                           
        end
        else
        begin
            exec @retcode = sys.sp_MSchangearticleresolver @article_resolver, @resolver_clsid, @artid, @value
            if @@ERROR <> 0 OR @retcode <> 0
            begin
                goto UNDO                           
            end            
    
            declare one_pub CURSOR LOCAL FAST_FORWARD FOR 
                select DISTINCT pubid from dbo.sysmergearticles where artid=@artid
            FOR READ ONLY
            open one_pub
            fetch next from one_pub into @pubid
             
            while (@@fetch_status <> -1)
            begin
                select @snapshot_ready=snapshot_ready from dbo.sysmergepublications 
                    where pubid = @pubid
                /* Insert the sp_MSchangearticleresolver schema change only if the publication's snapshot is ready */
                if (@snapshot_ready > 0)
                begin
                    select @schemaversion = schemaversion from sysmergeschemachange
                    if (@schemaversion is NULL) set @schemaversion = 1
                    else  
                        select @schemaversion = 1 + max(schemaversion) from sysmergeschemachange
                    set @schemaguid = newid()
                    set @schematype = @SCHEMA_TYPE_ARTICLERESOLVER
                    select @schematext = '
                        declare @cmd nvarchar(1000) 
                        set @cmd=''exec dbo.sp_MSchangearticleresolver @article_resolver=@ar, @resolver_clsid=@rc, @artid=@ai, @resolver_info=@ri''
                        exec dbo.sp_executesql @cmd, N''@ar nvarchar(255),@rc nvarchar(40),@ai uniqueidentifier,@ri nvarchar(517)'',
                            @ar=' + @article_resolver_str + ', 
                            @rc='+quotename (@resolver_clsid_str,'''')+',
                            @ai=''' + convert(nchar(36), @artid) + ''',                            
							@ri='''+ replace(@value_str, '''', '''''') +''''							

                     
                    exec @retcode = sys.sp_MSinsertschemachange @pubid, @artid, @schemaversion, @schemaguid, @schematype, @schematext 
                    if @@ERROR <> 0 OR @retcode <> 0
                    begin
                        goto UNDO                          
                    end
                end                             
                fetch next from one_pub into @pubid
            end 
            close one_pub
            deallocate one_pub
        end

    END /* for property = 'resolver_info' */


    if LOWER(@property collate SQL_Latin1_General_CP1_CS_AS) = 'pre_creation_command'
    BEGIN

        /*
        ** Check to make sure that we have a valid pre_creation_cmd.
        */

        if LOWER(@value collate SQL_Latin1_General_CP1_CS_AS) NOT IN ('none', 'drop', 'delete', 'truncate')
            BEGIN
                RAISERROR (14061, 16, -1)
                goto UNDO
            END

        /*
        ** Determine the integer value for the pre_creation_cmd.
        */

        if LOWER(@value collate SQL_Latin1_General_CP1_CS_AS) = 'none'
            select @precmdid = 0
        else if LOWER(@value collate SQL_Latin1_General_CP1_CS_AS) = 'drop'
            select @precmdid = 1
        else if LOWER(@value collate SQL_Latin1_General_CP1_CS_AS) = 'delete'
            select @precmdid = 2
        else if LOWER(@value collate SQL_Latin1_General_CP1_CS_AS) = 'truncate'
            select @precmdid = 3

        /*
        ** Update the article with the new pre_creation_cmd.
        */
        UPDATE dbo.sysmergearticles
            SET pre_creation_command = @precmdid
            WHERE artid = @artid
            AND pubid = @pubid

        if @@ERROR <> 0 
            goto UNDO

    END

    if LOWER(@property collate SQL_Latin1_General_CP1_CS_AS) = 'status'
    BEGIN

        /*
        ** Check to make sure that we have a valid status
        */
        if LOWER(@value collate SQL_Latin1_General_CP1_CS_AS) NOT IN ('active', 'unsynced', 'new_inactive', 'new_active')
        BEGIN
            RAISERROR (20075, 16, -1)
            goto UNDO
        END

        /*
        ** Determine the integer value for the type.
        */

        if LOWER(@value collate SQL_Latin1_General_CP1_CS_AS) = 'unsynced'
            select @statusid = 1
        else if LOWER(@value collate SQL_Latin1_General_CP1_CS_AS) = 'active'
            select @statusid = 2
        else if LOWER(@value collate SQL_Latin1_General_CP1_CS_AS) = 'new_inactive'
            select @statusid = 5
        else if LOWER(@value collate SQL_Latin1_General_CP1_CS_AS) = 'new_active'
            select @statusid = 6

        /*
        ** Update the article with the new type. The same base table might be 
        ** in multiple publications - so qualify  with pubid.
        */
        UPDATE dbo.sysmergearticles
            SET status = @statusid
            WHERE artid = @artid and pubid = @pubid

        if @@ERROR <> 0 
            goto UNDO

    END

    IF LOWER(@property collate SQL_Latin1_General_CP1_CS_AS) = 'destination_owner'
    BEGIN
        IF @value IS NULL or @value=''
            select @value = 'dbo'                       
        UPDATE dbo.sysmergearticles SET destination_owner = @value
            WHERE artid = @artid
            AND pubid = @pubid
        if @@ERROR <> 0
        BEGIN
            goto UNDO
        END
    END
    
    IF LOWER(@property collate SQL_Latin1_General_CP1_CS_AS) = 'schema_option'
    BEGIN
    
        IF @value IS NULL
        BEGIN
            RAISERROR(14146, 16,1)
            goto UNDO
        END

        CREATE TABLE #tab_changearticle (value varbinary(8) NULL)
                             
        IF @@ERROR <> 0 
        BEGIN
            goto UNDO
        END

		IF (SELECT sys.fn_isvalidhexstr(@value)) <> 1
		BEGIN
			RAISERROR(20014, 16, -1)
			RETURN (1)
		END
        
        declare @cmd nvarchar(200)
        select @cmd = 'insert into #tab_changearticle (value) values (@value)'
        --exec @retcode= dbo.sp_executesql @cmd, N'@value nvarchar(2000)', @value = @value
        EXEC ('insert #tab_changearticle values (' + @value +')' )

        IF @@ERROR <> 0 or @retcode <> 0
        BEGIN
            goto UNDO
        END
                  
        SELECT @schema_option = fn_replprepadbinary8(value) 
          FROM #tab_changearticle

        DECLARE @schema_option_lodword INT
        DECLARE @schema_option_hidword INT
        DECLARE @old_schema_option_lodword INT
        DECLARE @old_schema_option_hiword INT
        DECLARE @xprop_schema_option INT
        DECLARE @collation_schema_option INT
        SELECT @xprop_schema_option = 0x00002000
        SELECT @collation_schema_option = 0x00001000
        SELECT @schema_option_lodword = sys.fn_replgetbinary8lodword(@schema_option)
        SELECT @schema_option_hidword = sys.fn_replgetbinary8hidword(@schema_option)
        SELECT @old_schema_option_lodword = CONVERT(INT, SUBSTRING(@old_schema_option, 5, 4))
        SELECT @old_schema_option_hiword = CONVERT(INT, SUBSTRING(@old_schema_option, 1, 4))
        

        /*
           Verify that the schema option being set is compatible with
           publication compatibility level.
        */

        -- Since only the lower 32 bits of @schema_option are 
        -- used, the following check is sufficient. Note that @schema_option is
        -- already padded out to the left at the beginning of this procedure.
        declare @schema_option_xml_to_ntext int
        declare @schema_option_max_to_nonmax int
        declare @schema_option_create_schema int
        declare @schema_option_xml_indexes int
        declare @schema_option_filestream int
        declare @schema_option_katmaidatetime_to_string int
        declare @schema_option_hierarchyid_to_varbinarymax int
        declare @schema_option_largeUDT_to_varbinarymax int
        declare @schema_option_spatial_indexes int
        declare @schema_option_spatial_to_varbinarymax int
        declare @schema_option_udt_to_base_types int
        declare @schema_option_filtered_indexes int
        declare @schema_option_compression int
	 declare @schema_option_filestream_attribute         int
        declare @schema_option_str sysname       

        select @schema_option_xml_to_ntext  = 0x10000000 -- this has to be on  for < 90RTM
        select @schema_option_max_to_nonmax = 0x20000000 -- this has to be on  for < 90RTM
        select @schema_option_create_schema = 0x08000000 -- this has to be off for < 90RTM
        select @schema_option_xml_indexes   = 0x04000000 -- this has to be off for < 90RTM
        select @schema_option_filestream = 0x00000001  -- this has to be OFF  for < 100RTM
        select @schema_option_katmaidatetime_to_string = 0x00000002
        select @schema_option_hierarchyid_to_varbinarymax = 0x00000020 -- this has to be on for < 100RTM    
        select @schema_option_largeUDT_to_varbinarymax = 0x00000010 -- this has to be on for < 100RTM    
        select @schema_option_spatial_indexes = 0x00000100 -- this has to be off for < 100RTM
        select @schema_option_spatial_to_varbinarymax = 0x00000080 -- this has to be on for < 100RTM
        select @schema_option_udt_to_base_types = 0x00000020
	 select @schema_option_filestream_attribute = 0x00000001          
        select @schema_option_filtered_indexes = 0x00000040 -- this has to be on for < 100RTM    
        select @schema_option_compression   = 0x00000004 -- this has to be off for < 100RTM    

        declare @schema_option_has_changed bit;
        select @schema_option_has_changed = 0;

        declare @columns binary(128)     
        declare @colid        int
        declare @prevcolid        int
        declare @filestream_col_published int
        declare @has_filestream int
        declare @in_partition bit
        select @filestream_col_published = 0
        select @has_filestream = 0

        -- check if the article has filestream column and whether it is publised
        select @columns = columns from dbo.sysmergearticles WHERE name = @article AND pubid = @pubid

        select TOP 1 @colid = column_id from sys.columns where object_id = @objid and is_filestream = 1 order by column_id ASC
	
        while @colid is not null
        begin
            exec @in_partition = sys.sp_MStestbit @bm=@columns, @coltotest=@colid
            if ( @in_partition = 1 )
            begin
                select @filestream_col_published=1	        
                break
            end
            select @prevcolid = @colid
            select top 1 @colid=column_id from sys.columns where object_id = @objid and is_filestream=1 and column_id > @prevcolid order by column_id ASC
	    end

        -- varbinary(max) column with filestream attribute cannot be converted to base type (image)
        -- irrespective of whether filestream is repl. as filestream or varbinary(max)
        if ( @filestream_col_published = 1 and (@schema_option_lodword & @schema_option_max_to_nonmax = @schema_option_max_to_nonmax))
        begin
            RAISERROR(22583, 16, -1, @article, @publication)
            goto UNDO    
        end

        /*
        ** If compatlevel is less than 100RTM then make sure the schema option to map down
        ** 100 datatypes to equivalent downlevel datatypes is set. 
        ** * Map large UDT down to varbinary(max)
        ** * If spatial_indexes are set for replication, disable if compatlevel < 100
        ** * Map spatial types to varbinary(max)
        ** * Make sure the schema option to map down 100 datetime types to downlevel data types.
        ** * If filtered_indexes are set for replication, disable for subscribers under 100
        ** * Map new datetime types to string for subscribers under 100
        ** * Disable compression if it is enabled
        ** * Map hierarchyid to varbinary(max)
        */
        if (@compatlevel < 100 and 
           ((@schema_option_hidword & @schema_option_largeUDT_to_varbinarymax = 0) or
           (@schema_option_hidword & @schema_option_compression <> 0) or
           (@schema_option_hidword & @schema_option_hierarchyid_to_varbinarymax = 0) or
           (@schema_option_hidword & @schema_option_spatial_to_varbinarymax = 0) or
           (@schema_option_hidword & @schema_option_spatial_indexes <> 0) or
           (@schema_option_hidword & @schema_option_filtered_indexes <> 0) or
           (@schema_option_hidword & @schema_option_katmaidatetime_to_string = 0)))
        begin
            select @schema_option_hidword = @schema_option_hidword | @schema_option_largeUDT_to_varbinarymax
            select @schema_option_hidword = @schema_option_hidword & ~(@schema_option_compression)
            select @schema_option_hidword = @schema_option_hidword | @schema_option_hierarchyid_to_varbinarymax
            select @schema_option_hidword = @schema_option_hidword | @schema_option_spatial_to_varbinarymax
            select @schema_option_hidword = @schema_option_hidword & ~(@schema_option_spatial_indexes)            
            select @schema_option_hidword = @schema_option_hidword & ~(@schema_option_filtered_indexes)
            select @schema_option_hidword = @schema_option_hidword | @schema_option_katmaidatetime_to_string

            select @schema_option = sys.fn_replcombinehilodwordintobinary8(@schema_option_hidword, @schema_option_lodword)
            select @schema_option_str = sys.fn_varbintohexstr(@schema_option)
            select @schema_option_has_changed = 1;
        end
		
	    /*
	    ** For hierarchy we will map it to varbinarymax for 100 RTM compatibility level in character sync mode (for SSCE subscriber).
	    ** Turn off DataCompression for SSCE subscriber
	    */
	    if(@compatlevel = 100 and
		 @sync_mode = 1 and
		((@schema_option_hidword & @schema_option_hierarchyid_to_varbinarymax = 0) or
		  (@schema_option_hidword & @schema_option_compression <> 0)))
	    begin
	    	select @schema_option_hidword = @schema_option_hidword | @schema_option_hierarchyid_to_varbinarymax
              select @schema_option_hidword = @schema_option_hidword & ~(@schema_option_compression)	    	
	        select @schema_option = sys.fn_replcombinehilodwordintobinary8(@schema_option_hidword, @schema_option_lodword)
	        select @schema_option_str = sys.fn_varbintohexstr(@schema_option)
	        select @schema_option_has_changed = 1;    	      
	    end  

        /*
        ** If a spatial type is being mapped to non spatial type on the subscriber,
        ** ensure that the spatial index schema option is disabled.
        */
        if (@schema_option_hidword & @schema_option_spatial_indexes <> 0 and
           ((@schema_option_hidword & @schema_option_spatial_to_varbinarymax <> 0) or
           (@schema_option_lodword & @schema_option_udt_to_base_types <> 0)))
        begin
            select @schema_option_hidword = @schema_option_hidword & ~(@schema_option_spatial_indexes)
            select @schema_option = sys.fn_replcombinehilodwordintobinary8(@schema_option_hidword, @schema_option_lodword)
            select @schema_option_str = sys.fn_varbintohexstr(@schema_option)
            select @schema_option_has_changed = 1;

        end    

        --if turn changing the large UDT from not mapping to mapping to varbinary(max), we need
        --to mark the corresponding rows as inactive in sysmergeschemachange
        if( (@schema_option_hidword & @schema_option_largeUDT_to_varbinarymax <> 0)
        and (@old_schema_option_hiword & @schema_option_largeUDT_to_varbinarymax = 0))
        begin
            -- need to de-activate the row in schemachanges for the spatial type
            --	SCHEMA_TYPE_CLR_USER_DEFINED_DATA_TYPE 	   = 89,
            --	SCHEMA_TYPE_ASSEMBLY        			                = 90,
            update dbo.sysmergeschemachange set schemastatus = 0 where pubid = @pubid AND schematype in (89, 90)
            if @@ERROR <> 0 return 1                                
        end
        

        -- if compat level is Yukon and turn OFF the schema_option to replicate filestream attribute, if ON
        if ( @filestream_col_published = 1 and @compatlevel >= 90 and @compatlevel < 100 and  
        (@schema_option_hidword & @schema_option_filestream = @schema_option_filestream ))
        begin
            declare @schema_option_strg sysname
            select @schema_option_lodword = sys.fn_replgetbinary8lodword(@schema_option)
            select @schema_option_hidword = @schema_option_hidword & ~( @schema_option_filestream)
            select @schema_option = sys.fn_replcombinehilodwordintobinary8(@schema_option_hidword, @schema_option_lodword)
            select @schema_option_strg = sys.fn_varbintohexstr(@schema_option)
            RAISERROR (22584, 10, -1, @schema_option_strg)
        end

        /*
        ** If compatlevel is less than 90RTM then make sure the schema option to map down
        ** 90 datatypes to equivalent downlevel datatypes is set.
        */
        if (@compatlevel < 90 and 
            (((@schema_option_lodword & (@schema_option_xml_to_ntext | @schema_option_max_to_nonmax)) <> 
            (@schema_option_xml_to_ntext | @schema_option_max_to_nonmax)) or
            ((@schema_option_lodword & (@schema_option_create_schema | @schema_option_xml_indexes)) <> 0)))
        begin
            select @schema_option_lodword = @schema_option_lodword | @schema_option_xml_to_ntext | @schema_option_max_to_nonmax
            select @schema_option_lodword = @schema_option_lodword & ~(@schema_option_create_schema | @schema_option_xml_indexes)
            select @schema_option = sys.fn_replcombinehilodwordintobinary8(@schema_option_hidword, @schema_option_lodword)
            select @schema_option_str = sys.fn_varbintohexstr(@schema_option)
            select @schema_option_has_changed = 1;
        end            

        /*
        ** If we changed what the user originally input, output a message telling them what
        ** the new schema_option value is.
        */
        if @schema_option_has_changed = 1
        begin
            RAISERROR (20732, 10, -1, @schema_option_str)
        end


        -- Raise warnings only when we are enabling the Shiloh specific
        -- options
        IF ((@old_schema_option_lodword & @collation_schema_option) = 0)
            AND 
           ((@schema_option_lodword & @collation_schema_option) <> 0)
           and
           @compatlevel < 40
        BEGIN
            RAISERROR(21389, 10, -1, @publication)
            SELECT @bump_to_80 = 1
        END
        
        IF((@old_schema_option_lodword & @xprop_schema_option) = 0)
          AND 
          ((@schema_option_lodword & @xprop_schema_option) <> 0)
          and
           @compatlevel < 40
        BEGIN
            RAISERROR(21390, 10, -1, @publication)
            SELECT @bump_to_80 = 1
        END
            
        /*
            Read the current value to log to the MSmerge_settingshistory table.
        */
        declare @prev_schema_option binary(8)
        declare @prev_schema_option_str sysname
        declare @new_schema_option_str sysname
        
        select @prev_schema_option = schema_option
            from dbo.sysmergearticles 
            WHERE artid = @artid
            AND pubid = @pubid

        select @prev_schema_option_str = sys.fn_varbintohexstr (@prev_schema_option)
        select @new_schema_option_str = sys.fn_varbintohexstr (@schema_option)

	 declare @prev_schema_option_hidword int
	 SELECT @prev_schema_option_hidword = sys.fn_replgetbinary8hidword(@prev_schema_option)
        SELECT @schema_option_hidword = sys.fn_replgetbinary8hidword(@schema_option)

	-- if schema_option has been changed to include 'filestream' attribute, raise a warning
        if ( (@schema_option_hidword & @schema_option_filestream = @schema_option_filestream)
        and (@prev_schema_option_hidword & @schema_option_filestream <> @schema_option_filestream) )
		RAISERROR (22585, 10, -1, @article)    


        UPDATE dbo.sysmergearticles 
           SET schema_option = @schema_option 
            WHERE artid = @artid
            AND pubid = @pubid
        if @@ERROR <> 0
            BEGIN
            DROP TABLE #tab_changearticle 
            goto UNDO
            END
            
        /*
            Log the change in settings to the MSmerge_settingshistory table.
        */
        if @prev_schema_option_str <> @new_schema_option_str
        begin
            select @eventtype       = 102   -- Change in article settings.
            
            insert into dbo.MSmerge_settingshistory (eventtime,pubid,artid,eventtype,propertyname,previousvalue,newvalue,eventtext)
                values (default,@pubid,@artid,@eventtype,@property,@prev_schema_option_str,@new_schema_option_str, NULL)

        end
        DROP TABLE #tab_changearticle 
                             
        IF @@ERROR <> 0 
            BEGIN
                goto UNDO
            END

    END

    if LOWER(@property collate SQL_Latin1_General_CP1_CS_AS) = 'verify_resolver_signature'
        BEGIN
            if @value NOT IN ('1', '0')
                BEGIN
                    raiserror(21344, 16, -1, '"verify_resolver_signature"')
                    goto UNDO
                END

            update dbo.sysmergearticles set verify_resolver_signature = convert(int, @value) 
            where artid = @artid and pubid = @pubid
            if @@ERROR<>0
                goto UNDO
        END

    if LOWER(@property collate SQL_Latin1_General_CP1_CS_AS) = 'processing_order'
    BEGIN

        declare @processing_order int
        select @processing_order = convert(int, @value) 

        --if @compatlevel < 90 and @processing_order <> 0
        --begin
        --    raiserror(21585, 16, -1, @publication)
        --    goto UNDO
        --end
        
        update dbo.sysmergearticles set processing_order = @processing_order
        where artid = @artid and pubid = @pubid
        if @@ERROR<>0
            goto UNDO
            
        if @snapshot_ready > 0
        begin
            select @schemaversion = 1 + max(schemaversion) from dbo.sysmergeschemachange
            if @schemaversion is NULL
                set @schemaversion = 1
            set @schemaguid = newid()
            
            set @schematype = @SCHEMA_TYPE_ARTICLEPROCESSINGORDER
			select @schematext = 'exec dbo.sp_MSchange_mergearticle @pubid = ''' + convert(nchar(36), @pubid) + ''', @artid = ''' + convert(nchar(36), @artid) + ''', @property = ''processing_order'',@value=' +sys.fn_replquotename(@value,'''')
                                     
            exec @retcode = sys.sp_MSinsertschemachange @pubid, @artid, @schemaversion, @schemaguid, @schematype, @schematext
            if @@ERROR <> 0 OR @retcode <> 0
                goto UNDO
                
            select @upsert_regenerate_triggersprocs_schemachange = 1
        end
    END

    IF LOWER(@property collate SQL_Latin1_General_CP1_CS_AS) = 'allow_interactive_resolver'
    BEGIN

        /* Check to make sure that we have a true/false. */

        IF LOWER(@value collate SQL_Latin1_General_CP1_CS_AS) NOT IN ('true', 'false')
            BEGIN
                RAISERROR (14148, 16, -1, 'allow_interactive_resolver')
                goto UNDO
            END

        /* Determine the bit value. */

        IF LOWER(@value collate SQL_Latin1_General_CP1_CS_AS) = 'true'
            SET @allow_interactive_bit = 1
        ELSE
            SET @allow_interactive_bit = 0

        /* Update the subscription with the new 'allow_interactive_resolver' value. */
        update dbo.sysmergearticles set allow_interactive_resolver = @allow_interactive_bit
            where artid = @artid and pubid = @pubid
        IF @@ERROR <> 0
            BEGIN
                RAISERROR (14053, 16, -1)
                goto UNDO
            END

    END
    
    IF LOWER(@property collate SQL_Latin1_General_CP1_CS_AS) = 'published_in_tran_pub'
    BEGIN

        /* Check to make sure that we have a true/false. */

        IF LOWER(@value collate SQL_Latin1_General_CP1_CS_AS) NOT IN ('true', 'false')
            BEGIN
                RAISERROR (14148, 16, -1, 'published_in_tran_pub')
                goto UNDO
            END

        /* Determine the bit value. */

        IF LOWER(@value collate SQL_Latin1_General_CP1_CS_AS) = 'true'
        BEGIN
            SET @published_in_tran_pub_bit = 1
        END
        ELSE
            SET @published_in_tran_pub_bit = 0

        /* Update the subscription with the new 'published_in_tran_pub' value. */
        update dbo.sysmergearticles set published_in_tran_pub = @published_in_tran_pub_bit
            where artid = @artid and pubid = @pubid
        IF @@ERROR <> 0
            BEGIN
                RAISERROR (14053, 16, -1)
                goto UNDO
            END
            
        if @snapshot_ready > 0
        begin
            select @schemaversion = 1 + max(schemaversion) from dbo.sysmergeschemachange
            if @schemaversion is NULL
                set @schemaversion = 1
            set @schemaguid = newid()
            
            set @schematype = @SCHEMA_TYPE_PUBLISHED_IN_TRANPUB
            select @schematext = 'exec dbo.sp_MSchange_mergearticle @pubid = ''' + convert(nchar(36), @pubid) + ''', @artid = ''' + convert(nchar(36), @artid) + ''', @property = ''published_in_tran_pub'', @value=' + sys.fn_replquotename(@value,'''')
                                     
            exec @retcode = sys.sp_MSinsertschemachange @pubid, @artid, @schemaversion, @schemaguid, @schematype, @schematext
            if @@ERROR <> 0 OR @retcode <> 0
                goto UNDO
            
            select @upsert_regenerate_triggersprocs_schemachange = 1
        end
    END
        
    IF LOWER(@property collate SQL_Latin1_General_CP1_CS_AS) = 'delete_tracking'
    BEGIN

        /* Check to make sure that we have a true/false. */

        IF LOWER(@value collate SQL_Latin1_General_CP1_CS_AS) NOT IN ('true', 'false')
        BEGIN
            RAISERROR (14148, 16, -1, 'delete_tracking')
            goto UNDO
        END

        /* Determine the bit value. */

        IF LOWER(@value collate SQL_Latin1_General_CP1_CS_AS) = 'true'
            SET @delete_tracking = 1
        ELSE
            SET @delete_tracking = 0

        /* Get previous value to put in MSmerge_settingshistory table */
        /* All articles should have the same value so just pick one */
        select top 1 @previousbitvalue = delete_tracking from dbo.sysmergearticles
            where artid = @artid
            
        /* Update the subscription with the new 'delete_tracking' value. */
        /* Changing for one article changes for articles in all publications */
        update dbo.sysmergearticles set delete_tracking = @delete_tracking
            where artid = @artid
        IF @@ERROR <> 0
        BEGIN
            RAISERROR (14053, 16, -1)
            goto UNDO
        END
            
        /*  Insert event in the MSmerge_settingshistory table if the
            new value is different from the old value
            Look in replsys.sql where the table is created for more
            details about what is in this table. */
        if (@previousbitvalue <> @delete_tracking)
        begin
            select @eventtype       = 102
            
            insert into dbo.MSmerge_settingshistory (eventtime,pubid,artid,eventtype,propertyname,previousvalue,newvalue,eventtext)
                values (default,@pubid,@artid,@eventtype,@property,@previousbitvalue,@delete_tracking,NULL)
        end


        /*
        ** Insert the schema change for all the publications that the article is in.
        */
        
        declare one_pub CURSOR LOCAL FAST_FORWARD FOR 
            select DISTINCT pubid from dbo.sysmergearticles where artid=@artid
        FOR READ ONLY
        open one_pub
        fetch next from one_pub into @pubid
         
        while (@@fetch_status <> -1)
        begin
            select @snapshot_ready=snapshot_ready from dbo.sysmergepublications 
                where pubid = @pubid

            if @snapshot_ready > 0
            begin
                -- We insert a schemachange,
                -- so that we can tell SSCE subscriber that the property has changed.
                select @schemaversion = schemaversion from dbo.sysmergeschemachange
                if (@schemaversion is NULL)
                    set @schemaversion = 1
                else
                    select @schemaversion = 1 + max(schemaversion) from dbo.sysmergeschemachange
                    
                set @schemaguid = newid()
                set @artid = @artid
                set @schematype= @SCHEMA_TYPE_DELETETRACKING
                select @schematext = 'update dbo.sysmergearticles set delete_tracking=' + cast(@delete_tracking as nchar(1)) + ' where pubid=''' + cast(@pubid as nchar(36)) + ''''      
                exec @retcode=sys.sp_MSinsertschemachange @pubid, @artid, @schemaversion, @schemaguid, @schematype, @schematext
                if @@ERROR<>0 or @retcode<>0 
                begin
                    close one_pub
                    deallocate one_pub                    
                    goto UNDO      
                end


                /* Regenerate triggers */
                -- Run this on the publisher
                exec @retcode = dbo.sp_MSregenerate_mergetriggersprocs @pubid = @pubid
                if @@ERROR <> 0 OR @retcode <> 0
                begin
                    close one_pub
                    deallocate one_pub                    
                    goto UNDO      
                end
                
                -- Now post it as a schema change for the subscriber to run it as well.
                select @schemaversion = 1 + max(schemaversion) from dbo.sysmergeschemachange
                if @schemaversion is NULL
                    set @schemaversion = 1
                set @schemaguid = newid()
                select @schematext = 'exec dbo.sp_MSregenerate_mergetriggersprocs @pubid = ''' + convert(nchar(36), @pubid) + ''''
                exec @retcode = sys.sp_MSupsertschemachange @pubid=@pubid, @artid=NULL, @schemaversion=@schemaversion, 
                                                            @schemaguid=@schemaguid, @schematype=@schematype, @schematext=@schematext
                if @@ERROR <> 0 OR @retcode <> 0
                begin
                    close one_pub
                    deallocate one_pub                    
                    goto UNDO      
                end


            end

            fetch next from one_pub into @pubid
        end -- end of while
        close one_pub
        deallocate one_pub
        
    END
        
    IF LOWER(@property collate SQL_Latin1_General_CP1_CS_AS) = 'stream_blob_columns'
    BEGIN

        /* Check to make sure that we have a true/false. */

        IF LOWER(@value collate SQL_Latin1_General_CP1_CS_AS) NOT IN ('true', 'false')
        BEGIN
            RAISERROR (14148, 16, -1, 'stream_blob_columns')
            goto UNDO
        END

        /* Determine the bit value. */

        IF LOWER(@value collate SQL_Latin1_General_CP1_CS_AS) = 'true'
            SET @stream_blob_columns_bit = 1
        ELSE
            SET @stream_blob_columns_bit = 0

        /* Get previous value to put in MSmerge_settingshistory table */
        /* All articles should have the same value so just pick one */
        select top 1 @previousbitvalue = stream_blob_columns from dbo.sysmergearticles
            where artid = @artid
            
        /* Update the subscription with the new 'stream_blob_columns' value. */
        /* Changing for one article changes for articles in all publications */
        update dbo.sysmergearticles set stream_blob_columns = @stream_blob_columns_bit
            where artid = @artid
        IF @@ERROR <> 0
        BEGIN
            RAISERROR (14053, 16, -1)
            goto UNDO
        END
            
        /*  Insert event in the MSmerge_settingshistory table if the
            new value is different from the old value
            Look in replsys.sql where the table is created for more
            details about what is in this table. */
        if (@previousbitvalue <> @stream_blob_columns_bit)
        begin
            select @eventtype       = 102
            
            insert into dbo.MSmerge_settingshistory (eventtime,pubid,artid,eventtype,propertyname,previousvalue,newvalue,eventtext)
                values (default,@pubid,@artid,@eventtype,@property,@previousbitvalue,@stream_blob_columns_bit,NULL)
        end

        /*
        ** Insert the schema change for all the publications that the article is in.
        */
        
        declare one_pub CURSOR LOCAL FAST_FORWARD FOR 
            select DISTINCT pubid from dbo.sysmergearticles where artid=@artid
        FOR READ ONLY
        open one_pub
        fetch next from one_pub into @pubid
         
        while (@@fetch_status <> -1)
        begin

            -- We insert a schemachange,
            -- so that we can tell SSCE subscriber that the property has changed.
            select @schemaversion = schemaversion from dbo.sysmergeschemachange
            if (@schemaversion is NULL)
                set @schemaversion = 1
            else
                select @schemaversion = 1 + max(schemaversion) from dbo.sysmergeschemachange
                
            set @schemaguid = newid()
            set @artid = @artid
            set @schematype= @SCHEMA_TYPE_CHANGE_MERGE_ARTICLE_90RTM
            select @schematext = 'exec dbo.sp_MSchange_mergearticle @pubid = ''' + convert(nchar(36), @pubid) + ''', @artid = ''' + convert(nchar(36), @artid) + ''', @property = ''stream_blob_columns'', @value_numeric = ''' + cast(@stream_blob_columns_bit as nchar(1)) + ''''
            exec @retcode=sys.sp_MSinsertschemachange @pubid, @artid, @schemaversion, @schemaguid, @schematype, @schematext
            if @@ERROR<>0 or @retcode<>0
            begin
                close one_pub
                deallocate one_pub                    
                goto UNDO      
            end

            fetch next from one_pub into @pubid
        end -- end of while
        close one_pub
        deallocate one_pub

    END
    
    if @upsert_regenerate_triggersprocs_schemachange = 1
    begin
        -- Run this on the publisher
        exec @retcode = dbo.sp_MSregenerate_mergetriggersprocs @pubid = @pubid
        if @@ERROR <> 0 OR @retcode <> 0
            goto UNDO
        
        -- Now post it as a schema change for the subscriber to run it as well.
        select @schemaversion = 1 + max(schemaversion) from dbo.sysmergeschemachange
        if @schemaversion is NULL
            set @schemaversion = 1
        set @schemaguid = newid()
        select @schematext = 'exec dbo.sp_MSregenerate_mergetriggersprocs @pubid = ''' + convert(nchar(36), @pubid) + ''''
        exec @retcode = sys.sp_MSupsertschemachange @pubid=@pubid, @artid=NULL, @schemaversion=@schemaversion, 
                                                    @schemaguid=@schemaguid, @schematype=@schematype, @schematext=@schematext
        if @@ERROR <> 0 OR @retcode <> 0
            goto UNDO
    end
        
    IF @bump_to_80=1
    BEGIN
        EXEC @retcode = sys.sp_MSBumpupCompLevel @pubid, 40
        IF @@ERROR<>0 or @retcode<>0
            GOTO UNDO
    END
COMMIT_LABEL:    
    /*
    ** Return succeed.
    */
    exec sys.sp_MSreleasemergeadminapplock @lockowner = N'Transaction'
    COMMIT TRAN
    RETURN (0)
UNDO:
    if @@TRANCOUNT > 0
    begin
        if @got_merge_admin_applock=1
            exec sys.sp_MSreleasemergeadminapplock @lockowner = N'Transaction'
        ROLLBACK TRANSACTION changemergearticle
        COMMIT TRANSACTION
    end
    return (1)
GO
GRANT EXECUTE ON [sys].[sp_changemergearticle] TO [public] AS [dbo]
GO
