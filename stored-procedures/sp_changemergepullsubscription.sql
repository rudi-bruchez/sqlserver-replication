SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_changemergepullsubscription]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_changemergepullsubscription] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_changemergepullsubscription]
	@publication [sysname],
	@publisher [sysname],
	@publisher_db [sysname],
	@property [sysname],
	@value [nvarchar](255)
WITH EXECUTE AS CALLER
AS
SET NOCOUNT ON

    /*
    ** Declarations.
    */
    declare @subscriber_srvid         int
    declare @retcode                 int
    declare    @pubid                     uniqueidentifier
    declare    @subid                     uniqueidentifier
    declare @sync_typeid             tinyint
    declare @nosync                 tinyint
    declare @automatic                 tinyint
     
    declare @artid                    uniqueidentifier
    declare @subscriber                sysname
    declare @subscriber_db            sysname
    declare @schematype                int
    declare @schemaversion            int
    declare @schemaguid                uniqueidentifier
    declare @db_name                sysname
    declare @subscriber_type        int
    declare @schematext                nvarchar(2000)
    declare @use_interactive_bit    bit
    declare @use_interactive_int    int
    declare @enabled_for_syncmgr    int
    declare @regkey                    nvarchar(1000)
    declare @snapshot_ready            int
    declare @SCHEMA_TYPE_PRIORITYCHANGE int

    set @SCHEMA_TYPE_PRIORITYCHANGE= 8
    SET @subscriber     = @@SERVERNAME
    SET @subscriber_db    = DB_NAME()
    SET @nosync         = 2     /* Const: synchronization type 'none' */
    SET @automatic         = 1     /* Const: synchronization type 'automatic' */

    /*
    ** Security Check.
    */
    exec @retcode = sys.sp_MSreplcheck_subscribe
    if @@ERROR <> 0 or @retcode <> 0
        return(1)


    /*
    **    Check to see if current database is enabled for subscribing
    */
    IF object_id('sysmergesubscriptions') is NULL
    BEGIN
        RAISERROR (14055, 16, -1)
        RETURN (1)
    END


    /*
    ** Parameter Check:  @property.
    ** If the @property parameter is NULL, print the options.
    */

    IF @property IS NULL
        BEGIN
            CREATE TABLE #tab1 (properties sysname collate database_default not null)
            INSERT INTO #tab1 VALUES ('sync_type')
            INSERT INTO #tab1 VALUES ('priority')
            INSERT INTO #tab1 VALUES ('description') 
            INSERT INTO #tab1 VALUES ('use_interactive_resolver')             
            -- Properties delegated to sp_change_subscription_properties
            INSERT INTO #tab1 VALUES ('publisher_login')
            INSERT INTO #tab1 VALUES ('publisher_password')
            INSERT INTO #tab1 VALUES ('publisher_security_mode')
            INSERT INTO #tab1 VALUES ('distributor')
            INSERT INTO #tab1 VALUES ('distributor_login')
            INSERT INTO #tab1 VALUES ('distributor_password')
            INSERT INTO #tab1 VALUES ('distributor_security_mode')
            INSERT INTO #tab1 VALUES ('ftp_address')
            INSERT INTO #tab1 VALUES ('ftp_port')
            INSERT INTO #tab1 VALUES ('ftp_login')
            INSERT INTO #tab1 VALUES ('ftp_password')
            INSERT INTO #tab1 VALUES ('alt_snapshot_folder')
            INSERT INTO #tab1 VALUES ('working_directory')
            INSERT INTO #tab1 VALUES ('use_ftp')
            INSERT INTO #tab1 VALUES ('dynamic_snapshot_location')
            INSERT INTO #tab1 VALUES ('use_web_sync')
            INSERT INTO #tab1 VALUES ('internet_url')
            INSERT INTO #tab1 VALUES ('internet_login')
            INSERT INTO #tab1 VALUES ('internet_password')
            INSERT INTO #tab1 VALUES ('internet_security_mode')
            INSERT INTO #tab1 VALUES ('internet_timeout')
            INSERT INTO #tab1 VALUES ('hostname')
            INSERT INTO #tab1 VALUES ('merge_job_login')
            INSERT INTO #tab1 VALUES ('merge_job_password')
            select * FROM #tab1
            RETURN (0)
        END

    /*
    ** Parameter Check:  @publisher.
    ** Check to make sure we have a valid publisher.
    ** Should make sure that @publisher is non-null before using it to check whether @publication is valid
    */
    IF @publisher IS NULL
        BEGIN
            RAISERROR (14043, 16, -1, '@publisher', 'sp_changemergepullsubscription')
            RETURN (1)
        END

    /*
    ** Parameter Check:  @publication.
    ** Make sure that the publication exists.
    */

    IF @publication IS NULL
        BEGIN
            RAISERROR (14043, 16, -1, '@publication', 'sp_changemergepullsubscription')
            RETURN (1)
        END

    select @pubid = pubid FROM dbo.sysmergepublications WHERE name = @publication and UPPER(publisher)=UPPER(@publisher) and publisher_db=@publisher_db
    IF @pubid IS NULL
        BEGIN
            RAISERROR (20026, 11, -1, @publication)
            RETURN (1)
        END

    
    /*
    ** Check to see if you have any subscription to this publication
    */
    set @subid = NULL
    select @subid = subid from dbo.sysmergesubscriptions 
        where pubid = @pubid and subid <> @pubid and 
        UPPER(subscriber_server) collate database_default = UPPER(@subscriber) collate database_default and
        db_name = @subscriber_db
    if @subid IS NULL 
    begin
        RAISERROR (14050, 11, -1)
        RETURN(1)
    end                 


    /*
    ** Parameter Check:  @property.
    ** Check to make sure that @property is a valid property in
    ** a merge pull subscription.
    */

    IF LOWER(@property collate SQL_Latin1_General_CP1_CS_AS) NOT IN 
                               ('sync_type', 
                                'priority', 
                                'description',
                                'publisher_login',
                                'publisher_password',
                                'publisher_security_mode',
                                'distributor',
                                'distributor_login',
                                'distributor_password',
                                'distributor_security_mode',
                                'ftp_address',
                                'ftp_port',
                                'ftp_login',
                                'ftp_password',
                                'alt_snapshot_folder',
                                'working_directory',
                                'use_ftp',
                                'use_interactive_resolver',
                                'offload_agent',
                                'offload_server',
                                'dynamic_snapshot_location',
                                'use_web_sync',
                                'internet_url',
                                'internet_login',
                                'internet_password',
                                'internet_security_mode',
                                'internet_timeout',
                                'hostname',
                                'merge_job_login',
                                'merge_job_password')
        BEGIN
            RAISERROR (21348, 16, -1, @property)
            RETURN (1)
        END

    /*
    ** Change the property.
    */
    IF LOWER(@property collate SQL_Latin1_General_CP1_CS_AS) = 'sync_type'
        BEGIN

            /*
            ** Check to make sure that we have a valid sync_type.
            */

            IF LOWER(@value collate SQL_Latin1_General_CP1_CS_AS) NOT IN ('automatic', 'none')
                BEGIN
                    RAISERROR (14052, 16, -1)
                    RETURN (1)
                END

            /*
            ** Determine the integer value for the sync_type.
            */

            IF LOWER(@value collate SQL_Latin1_General_CP1_CS_AS) = 'automatic'
                SET @sync_typeid = @automatic
            ELSE
                SET @sync_typeid = @nosync

            /*
            ** Update the subscription with the new sync_type.
            */

            UPDATE dbo.sysmergesubscriptions
                   SET sync_type = @sync_typeid
                 WHERE subid = @subid
            IF @@ERROR <> 0
                BEGIN
                    RAISERROR (14053, 16, -1)
                    RETURN (1)
                END

        END
        
    IF LOWER(@property collate SQL_Latin1_General_CP1_CS_AS) = 'description'
        BEGIN
        UPDATE dbo.sysmergesubscriptions
                   SET description = @value
                 WHERE subid = @subid
            IF @@ERROR <> 0
                BEGIN
                    RAISERROR (14053, 16, -1) 
              
                    RETURN (1)
                END

        END

    IF LOWER(@property collate SQL_Latin1_General_CP1_CS_AS) = 'use_interactive_resolver'
    BEGIN

        /* Check to make sure that we have a true/false. */

        IF LOWER(@value collate SQL_Latin1_General_CP1_CS_AS) NOT IN ('true', 'false')
            BEGIN
                RAISERROR (14148, 16, -1, 'use_interactive_resolver')
                RETURN (1)
            END

        /* Determine the bit value. */

        IF LOWER(@value collate SQL_Latin1_General_CP1_CS_AS) = 'true'
            SET @use_interactive_bit = 1
        ELSE
            SET @use_interactive_bit = 0

        /* Update the subscription with the new 'use_interactive' value. */

        UPDATE dbo.MSmerge_replinfo
               SET use_interactive_resolver = @use_interactive_bit
             WHERE repid = @subid
        IF @@ERROR <> 0
            BEGIN
                RAISERROR (14053, 16, -1)
                RETURN (1)
            END
        /* If the subscription is enable for Sync Manager, then update the reg value */
        exec sys.sp_MSsubscription_enabled_for_syncmgr
            @publisher, @publisher_db, @publication, @subscriber, @subscriber_db, 
            @enabled_for_syncmgr OUT, @regkey OUT
        IF @@ERROR <> 0
            BEGIN
                RAISERROR (14053, 16, -1)
                RETURN (1)
            END
        if @enabled_for_syncmgr = 1
        begin
            select @use_interactive_int = convert(int, @use_interactive_bit)
            EXECUTE @retcode = master.dbo.xp_regwrite 'HKEY_LOCAL_MACHINE',
                                   @regkey,
                                   'UseInteractiveResolver',
                                   'REG_DWORD',
                                    @use_interactive_int
            if @retcode <> 0 OR @@ERROR <> 0
                BEGIN
                    RAISERROR (14053, 16, -1)
                    RETURN (1)
                END
        end

    END
        
     
    IF LOWER(@property collate SQL_Latin1_General_CP1_CS_AS) = 'priority'
    BEGIN

        select @db_name = db_name from dbo.sysmergesubscriptions
            where (pubid=@pubid) and (subid=@pubid)
        IF @db_name <> db_name()
            BEGIN
                RAISERROR (20048, 16, -1)
                RETURN (1)
            END

        /* Only the original publisher can change priority of a global subscriptions */

        IF @subscriber_type<>1  
            BEGIN
                RAISERROR (20044, 16, -1)  /* Local subscriber does not have priority*/
                RETURN (1)
            END

         
        BEGIN TRANSACTION
        save tran sp_changemergepullsubscription
            exec sys.sp_MSchange_priority @subid,  @value
            select @snapshot_ready=snapshot_ready from dbo.sysmergepublications where pubid = @pubid
            /* Insert the sp_MSchange_priority schema change only if the publication's snapshot is ready */
            if (@snapshot_ready > 0)
            begin
                select @schemaversion = schemaversion from dbo.sysmergeschemachange
                if (@schemaversion is NULL)
                set @schemaversion = 1
                else
                    select @schemaversion = 1 + max(schemaversion) from dbo.sysmergeschemachange
                set @schemaguid = newid()
                set @artid = newid()
                set @schematype = @SCHEMA_TYPE_PRIORITYCHANGE
                select @schematext = 'exec dbo.sp_MSchange_priority '+ '''' + convert(nchar(36),@subid) + '''' + ',' + '''' + @value + '''' 
                exec sys.sp_MSinsertschemachange @pubid, @artid, @schemaversion, @schemaguid, @schematype, @schematext
                if @@ERROR <> 0 goto Rollback_tran
            end
        COMMIT TRANSACTION

    END

    IF LOWER(@property collate SQL_Latin1_General_CP1_CS_AS) IN 
                           ('publisher_login',
                            'publisher_password',
                            'publisher_security_mode',
                            'distributor',
                            'distributor_login',
                            'distributor_password',
                            'distributor_security_mode',
                            'ftp_address',
                            'ftp_port',
                            'ftp_login',
                            'ftp_password',
                            'alt_snapshot_folder',
                            'working_directory',
                            'use_ftp',
                            'offload_agent',
                            'offload_server',
                            'dynamic_snapshot_location',
                            'use_web_sync',
                            'internet_url',
                            'internet_login',
                            'internet_password',
                            'internet_security_mode',
                            'internet_timeout',
                            'hostname',
                            'merge_job_login',
                            'merge_job_password')
    BEGIN
        EXEC @retcode = sys.sp_change_subscription_properties @publisher = @publisher,
                                                              @publisher_db = @publisher_db,
                                                              @publication = @publication,
                                                              @property = @property,
                                                              @value = @value,
                                                              @publication_type = 2
        IF @retcode <> 0
            RETURN 1
    END


    /*
    ** Return succeed.
    */

    RAISERROR (14054, 10, -1)
    RETURN (0)
    
Rollback_tran:
    rollback tran sp_changemergepullsubscription
    commit tran
    return (1)
GO
GRANT EXECUTE ON [sys].[sp_changemergepullsubscription] TO [public] AS [dbo]
GO
