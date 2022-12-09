SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_changemergesubscription]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_changemergesubscription] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_changemergesubscription]
	@publication [sysname],
	@subscriber [sysname],
	@subscriber_db [sysname],
	@property [sysname],
	@value [nvarchar](255),
	@force_reinit_subscription [bit]
WITH EXECUTE AS CALLER
AS
SET NOCOUNT ON

    declare @subscriber_bit            smallint
    declare @retcode                int
    declare @pubid                    uniqueidentifier
    declare @subid                    uniqueidentifier
    declare @sync_typeid            tinyint
    declare @nosync                    tinyint
    declare @automatic                tinyint
    declare @push                    tinyint
    declare @artid                    uniqueidentifier
    declare @schematype                int
    declare @schemaversion            int
    declare @schemaguid                uniqueidentifier
    declare @db_name                sysname
    declare @subscriber_type        int
    declare @subscription_type        int
    declare @schematext                nvarchar(2000)
    declare @publisher                sysname
    declare @publisher_db            sysname
    declare @use_interactive_bit    int 
    declare @enabled_for_syncmgr    int
    declare @regkey                    nvarchar(1000)
    declare @snapshot_ready            int
    declare @SCHEMA_TYPE_PRIORITYCHANGE int
    declare @automatic_reinitialization_policy bit
	declare @mrgagent_exists 		bit
	declare @proxy_id				int
	declare @distproc             	nvarchar(1000)
    declare @distributor         	sysname
    declare @distribution_db     	sysname
    
    SET @nosync            = 2        /* Const: synchronization type 'none' */
    SET @automatic        = 1        /* Const: synchronization type 'automatic' */
    set @push            = 0
    set @publisher        = publishingservername()
    set @publisher_db    = DB_NAME()
    set @SCHEMA_TYPE_PRIORITYCHANGE= 8

    /*
    ** Security Check.
    */
    exec @retcode= sys.sp_MSreplcheck_subscribe
    if @@error <> 0 or @retcode <> 0
    begin
        raiserror(15247,-1,-1)
        return (1)
    end


    /*
    **    Check to see if current database is doing publishing/subscribing
    */
    IF object_id('sysmergesubscriptions') is NULL
    BEGIN
        RAISERROR (14055, 16, -1)
        RETURN (1)
    END

    /*
    ** Parameter Check:     @property.
    ** If the @property parameter is NULL, print the options.
    */

    IF @property IS NULL
        BEGIN
            CREATE TABLE #tab1 (properties sysname collate database_default)
            INSERT INTO #tab1 VALUES ('sync_type')
            INSERT INTO #tab1 VALUES ('priority')
            INSERT INTO #tab1 VALUES ('description') 
            INSERT INTO #tab1 VALUES ('use_interactive_resolver')
            INSERT INTO #tab1 VALUES ('subscriber_security_mode')
            INSERT INTO #tab1 VALUES ('subscriber_login')
            INSERT INTO #tab1 VALUES ('subscriber_password')
            INSERT INTO #tab1 VALUES ('publisher_security_mode')
            INSERT INTO #tab1 VALUES ('publisher_login')
            INSERT INTO #tab1 VALUES ('publisher_password')
            INSERT INTO #tab1 VALUES ('merge_job_login')
            INSERT INTO #tab1 VALUES ('merge_job_password')
            
            select * FROM #tab1
            RETURN (0)
        END

    /*
    ** Parameter Check:     @publication.
    ** Make sure that the publication exists.
    */

    IF @publication IS NULL
        BEGIN
            RAISERROR (14043, 16, -1, '@publication', 'sp_changemergesubscription')
            RETURN (1)
        END

    select @pubid = pubid, 
           @snapshot_ready=snapshot_ready,
           @automatic_reinitialization_policy = automatic_reinitialization_policy
       FROM dbo.sysmergepublications 
       WHERE name = @publication  and UPPER(publisher)=UPPER(publishingservername()) and publisher_db=db_name()
    IF @pubid IS NULL
        BEGIN
            RAISERROR (20026, 11, -1, @publication)
            RETURN (1)
        END

    
    /*
    ** Parameter Check:     @subscriber.
    ** Check to make sure we have a valid subscriber.
    */
    IF @subscriber IS NULL
        BEGIN
            RAISERROR (14043, 16, -1, '@subscriber', 'sp_changemergesubscription')
            RETURN (1)
        END
    
    exec sys.sp_MSget_server_portinfo 
        @name = @subscriber, 
        @srvname = @subscriber OUTPUT

    /*
    ** Check to see if you have a local / global subscription on this publication
    */
    set @subid = NULL
    select @subid = subs.subid, 
           @pubid = pubs.pubid, /* identified from publication name */
           @subscriber_type=subs.subscriber_type,
           @subscription_type=subs.subscription_type
          from dbo.sysmergesubscriptions    subs,
            dbo.sysmergepublications    pubs
        where UPPER(subs.subscriber_server) collate database_default = UPPER(@subscriber) collate database_default
            and subs.db_name = @subscriber_db
            and subs.pubid = pubs.pubid
            and pubs.name = @publication 
            and UPPER(pubs.publisher)=UPPER(publishingservername()) 
            and pubs.publisher_db=db_name()
            and (subs.subscriber_type = 1 or subs.subscriber_type = 2)
    if @subid IS NULL 
        begin
            RAISERROR (14050, 11, -1)
            RETURN(1)
        end                    

    /*
    ** Parameter Check:     @property.
    ** Check to make sure that @property is a valid property in
    ** sysarticles.
    */
    IF LOWER(@property collate SQL_Latin1_General_CP1_CS_AS) NOT IN ('sync_type', 'priority', 'description', 'use_interactive_resolver', 
                                                                        'subscriber_security_mode', 'subscriber_login', 'subscriber_password', 
                                                                        'publisher_security_mode', 'publisher_login', 'publisher_password',
                                                                        'merge_job_login', 'merge_job_password')
    BEGIN
        RAISERROR (20078, 16, -1)
        RETURN (1)
    END

	EXEC @retcode = sys.sp_helpdistributor @rpcsrvname = @distributor OUTPUT, 
											@distribdb = @distribution_db OUTPUT
    IF @@ERROR <> 0 or @retcode <> 0 or @distributor is NULL 
    BEGIN
        RAISERROR (20036, 16, -1)
        goto UNDO
    END         

	-- we only need to check if we have enough permissions to modify
	-- subscription properties for push cases since well known pull 
	-- subscriptions will never have jobs at the distributor...
	IF @subscription_type = @push
	BEGIN
		-- make sure we have permission to perform this action
		SELECT @distproc = QUOTENAME(RTRIM(@distributor)) + '.' + QUOTENAME(RTRIM(@distribution_db)) + '.sys.sp_MSreplagentjobexists'
		EXEC  @distproc @type = 1,
						@exists = @mrgagent_exists OUTPUT,
						@proxy_id = @proxy_id OUTPUT,
						@publisher = @publisher,
						@publisher_db = @publisher_db,
						@publication = @publication,
						@subscriber = @subscriber,
						@subscriber_db = @subscriber_db
		IF @@ERROR <> 0 OR @retcode <> 0
			RETURN 1

		IF IS_SRVROLEMEMBER('sysadmin') != 1
			AND (@mrgagent_exists = 0
				OR @proxy_id IS NULL)
		BEGIN
			-- Only members of the sysadmin fixed server role can modify a subscription that does not have a job with a proxy account defined.
			RAISERROR(20813, 16, -1, 'subscription')
			RETURN 1
		END
	END

    BEGIN TRANSACTION change_subscription
    save TRAN change_subscription
    IF LOWER(@property collate SQL_Latin1_General_CP1_CS_AS) = 'use_interactive_resolver'
    BEGIN

        /* Check to make sure that we have a true/false. */

        IF LOWER(@value collate SQL_Latin1_General_CP1_CS_AS) NOT IN ('true', 'false')
            BEGIN
                RAISERROR (14148, 16, -1, 'use_interactive_resolver')
                goto UNDO    
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
                goto UNDO
            END

        /* If the subscription is enable for Sync Manager, then update the reg value */
        exec sys.sp_MSsubscription_enabled_for_syncmgr
            @publisher, @publisher_db, @publication, @subscriber, @subscriber_db, 
            @enabled_for_syncmgr OUT, @regkey OUT
        IF @@ERROR <> 0
            BEGIN
                RAISERROR (14053, 16, -1)
                goto UNDO
            END
        if @enabled_for_syncmgr = 1
        begin
                EXECUTE @retcode = master.dbo.xp_regwrite 'HKEY_LOCAL_MACHINE',
                                       @regkey,
                                       'UseInteractiveResolver',
                                       'REG_DWORD',
                                        @use_interactive_bit
                if @retcode <> 0 OR @@ERROR <> 0
                    BEGIN
                        RAISERROR (14053, 16, -1)
                        goto UNDO
                    END
        end
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
                    goto UNDO
                END

            /*
            ** Determine the integer value for the sync_type.
            */

            IF LOWER(@value collate SQL_Latin1_General_CP1_CS_AS) = 'automatic'
                SET @sync_typeid = @automatic
            ELSE
            BEGIN

            /*
            **    If current publication contains an article without rowguidcol, do not allow no-sync subscription
            */    
            if exists (select * from dbo.sysmergearticles a where pubid = @pubid and 
                    not exists (select * from sys.columns c where c.object_id=a.objid and c.is_rowguidcol=1))
                begin
                    Raiserror(20086, 16, -1, @publication)
                    goto UNDO
                end
                else 
                    SET @sync_typeid = @nosync
            END

            /*
            ** Update the subscription with the new sync_type.
            */

            UPDATE dbo.sysmergesubscriptions
                SET sync_type = @sync_typeid
                WHERE subid = @subid
            IF @@ERROR <> 0
                BEGIN
                    RAISERROR (14053, 16, -1)
                    goto UNDO
                END

            if @snapshot_ready>0
            begin
                --if there is one article in this publication with pre_command of other than 'drop',
                --do not allow changing subscription property.
                if exists (select * from dbo.sysmergearticles where pubid=@pubid and pre_creation_command<>1)
                    begin
                        RAISERROR (21420, 16, -1, @property)
                        goto UNDO                
                    end
                /*
                ** make sure we know we really want to do this.
                */
                if @force_reinit_subscription = 0
                begin
                    raiserror(20608, 16, -1)
                    goto UNDO
                end

                exec @retcode=sys.sp_MSreinitmergepublication 
                                    @publication = @publication,
                                    @upload_first = @automatic_reinitialization_policy
                if @@ERROR<>0 or @retcode<>0 GOTO UNDO 
            end
        END
        
    IF LOWER(@property collate SQL_Latin1_General_CP1_CS_AS) = 'description'
    BEGIN
        UPDATE dbo.sysmergesubscriptions
                SET description = @value
                WHERE subid = @subid
            IF @@ERROR <> 0
            BEGIN
                RAISERROR (14053, 16, -1) 
                goto UNDO
            END

    END
        
     
    IF LOWER(@property collate SQL_Latin1_General_CP1_CS_AS) = 'priority'
    BEGIN

        select @db_name = db_name from dbo.sysmergesubscriptions
            where (pubid=@pubid) and (subid=@pubid)
        IF @db_name <> db_name()
        BEGIN
            RAISERROR (20047, 16, -1)
            goto UNDO
        END     

    /* Only the original publisher can change priority of a global subscriptions */

        IF @subscriber_type<>1    
            BEGIN
                RAISERROR (20044, 16, -1)  /* Local subscriber does not have priority*/
                goto UNDO
            END

        declare @priority real
        set @priority= cast(@value as real)
        if @@error<>0 goto UNDO

        IF @priority>100.0
        BEGIN
            RAISERROR (20049, 16, -1)  /* Don't accept priority greater than 100 */
            goto UNDO
        END
        
        exec sys.sp_MSchange_priority @subid,  @value
        if @@ERROR<>0 goto UNDO
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
                exec @retcode=sys.sp_MSinsertschemachange @pubid, @artid, @schemaversion, @schemaguid, @schematype, @schematext
                if @@ERROR<>0 or @retcode<>0 goto UNDO
            end                    
    END

    IF LOWER(@property collate SQL_Latin1_General_CP1_CS_AS) in ('subscriber_security_mode', 'subscriber_login', 'subscriber_password',
                                                                'publisher_security_mode', 'publisher_login', 'publisher_password',
                                                                'merge_job_login', 'merge_job_password', 'description')
    BEGIN
        -- this is only valid for a push subscription
        IF @subscription_type <> @push
        BEGIN
            -- "The property '@property' is only valid for push subscriptions."
            RAISERROR (21817, 16, -1, @property)
            goto UNDO
        END

		IF LOWER(@property collate SQL_Latin1_General_CP1_CS_AS) = N'merge_job_login'
			AND sys.fn_replisvalidwindowsloginformat(@value) != 1
		BEGIN
			-- '@job_login' must be a valid Windows Login in the form : 'MACHINE\Login' or 'DOMAIN\Login'. Please see the documentation for 'sp_changemergesubscription'.
			RAISERROR(21797, 16, -1, '@value (merge_job_login)', 'sp_changemergesubscription')
			goto UNDO
		END
        
        SELECT @distproc = QUOTENAME(RTRIM(@distributor)) + '.' + QUOTENAME(RTRIM(@distribution_db)) + '.sys.sp_MSchange_merge_agent_properties'    
        EXEC @retcode = @distproc @publisher        = @publisher,
                                    @publisher_db    = @publisher_db,
                                    @publication     = @publication,
                                    @subscriber     = @subscriber,
                                    @subscriber_db    = @subscriber_db,
                                    @property        = @property,
                                    @value            = @value
        IF @@ERROR <> 0 or @retcode <> 0
        BEGIN
            goto UNDO
        END
    END
    
    COMMIT TRANSACTION

    /*
    ** Return succeed. It is not an error message.
    */

    RAISERROR (14054, 10, -1)
    RETURN (0)
UNDO:
    if @@TRANCOUNT > 0
    begin
        ROLLBACK TRANSACTION change_subscription
        COMMIT TRANSACTION
    end
    return (1)
GO
GRANT EXECUTE ON [sys].[sp_changemergesubscription] TO [public] AS [dbo]
GO
