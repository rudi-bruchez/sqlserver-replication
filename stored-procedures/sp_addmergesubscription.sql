SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_addmergesubscription]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_addmergesubscription] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_addmergesubscription]
	@publication [sysname],
	@subscriber [sysname],
	@subscriber_db [sysname],
	@subscription_type [nvarchar](15),
	@subscriber_type [nvarchar](15),
	@subscription_priority [real],
	@sync_type [nvarchar](15),
	@frequency_type [int],
	@frequency_interval [int],
	@frequency_relative_interval [int],
	@frequency_recurrence_factor [int],
	@frequency_subday [int],
	@frequency_subday_interval [int],
	@active_start_time_of_day [int],
	@active_end_time_of_day [int],
	@active_start_date [int],
	@active_end_date [int],
	@optional_command_line [nvarchar](4000),
	@description [nvarchar](255),
	@enabled_for_syncmgr [nvarchar](5),
	@offloadagent [bit],
	@offloadserver [sysname],
	@use_interactive_resolver [nvarchar](5),
	@merge_job_name [sysname],
	@hostname [sysname]
WITH EXECUTE AS CALLER
AS
SET NOCOUNT ON

    /*
    ** Declarations.
    */
    declare @retcode                int
    declare @subnickname            binary(6)
    declare @priority               real
    declare @subid                  uniqueidentifier
    declare @pubid                  uniqueidentifier    /* Publication id */
    declare @subscriber_typeid      smallint
    declare @subscriber_srvid       int
    declare @merge_jobid            binary(16)            /* Scheduler jobid for the merge agent */
    declare @subscription_type_id   int      
    declare @distproc               nvarchar(300)
    declare @command                nvarchar(255)
    declare @inactive               tinyint
    declare @subscriber_bit         smallint
    declare @global                 tinyint        /* subscriber type is global */
    declare @push                   tinyint        /* subscription type is push */
    declare @sync_typeid            tinyint
    declare @nosync                 tinyint        
    declare @automatic              tinyint        
    declare @distributor            sysname
    declare @distribdb              sysname
    declare @publisher              sysname
    declare @publisher_db           sysname
    declare @found                  int
    declare @datasource_type        int
    DECLARE @platform_nt            binary
    declare @use_interactive_bit    bit
    declare @internal               sysname
    declare @REPOLEVersion_90           int
    			,@publishingservername sysname
    declare @compatlevel int
    
    /* make sure current database is enabled for merge replication */
    exec @retcode=sys.sp_MSCheckmergereplication
    if @@ERROR<>0 or @retcode<>0
        return (1)

    /*
    ** Initializations.
    */
    set @datasource_type = 0    /* Default SQL Server */
    set @platform_nt = 0x1    
    SET @nosync                = 2          /* Const: synchronization type 'none' */
    SET @automatic            = 1          /* Const: synchronization type 'automatic' */
    set @inactive            = 0
    SET @subscriber_bit        = 4     
    set @global                = 1
    set @push                = 0
    set @pubid                = NULL           
    set @publisher            = publishingservername()
    set @publisher_db        = DB_NAME()
    select @found            = 1       /* Any non-NULL value is fine */
    		,@publishingservername = publishingservername()
    set @REPOLEVersion_90    = 90
    
    /*
    ** Parameter Check: @subscription_type.
    ** Set subscriber_typeid based on the @subscription_type specified.
    **
    **     subscription_type      subscription_type
    **     =================      ===============
    **               0            push
    **               1            pull
    */
    if LOWER(@subscription_type collate SQL_Latin1_General_CP1_CS_AS) NOT IN ('push', 'pull')
        BEGIN
            RAISERROR (14128, 16, -1)
            RETURN (1)
        END
    IF LOWER(@subscription_type collate SQL_Latin1_General_CP1_CS_AS) = 'push'
    BEGIN
        set @subscription_type_id = 0
    END
    ELSE
    BEGIN
        set @subscription_type_id = 1
    END

	/*
	** Parameter Check: @offloadagent.
	*/
	IF @offloadagent IS NOT NULL
		AND @offloadagent != 0
	BEGIN
		-- "Parameter '@offloadagent' is no longer supported."
		RAISERROR(21698, 16, -1, '@offloadagent')
		RETURN 1
	END

	IF ISNULL(@offloadserver, N'') != N''
	BEGIN
		-- "Parameter '@offloadserver' is no longer supported."
		RAISERROR(21698, 16, -1, '@offloadserver')
		RETURN 1
	END

    /*
    ** Security Check.
    */
    IF @subscription_type_id = 0 
    BEGIN
        exec @retcode = sys.sp_MSreplcheck_publish
        if @@ERROR <> 0 or @retcode <> 0
            return(1)
    END
    ELSE
    BEGIN
        exec @retcode = sys.sp_MSreplcheck_pull @publication
        if @@ERROR <> 0 or @retcode <> 0
        begin
            return(1)
        end
    END

	-- With the new security model a number of parameters are invalid
	IF sys.fn_yukonsecuritymodelrequired(NULL) = 1
	BEGIN
		IF @frequency_type IS NOT NULL
			OR @frequency_interval IS NOT NULL
			OR @frequency_relative_interval IS NOT NULL
			OR @frequency_recurrence_factor IS NOT NULL
			OR @frequency_subday IS NOT NULL
			OR @frequency_subday_interval IS NOT NULL
			OR @active_start_time_of_day IS NOT NULL
			OR @active_end_time_of_day IS NOT NULL
			OR @active_start_date IS NOT NULL
			OR @active_end_date IS NOT NULL
			OR @optional_command_line IS NOT NULL
			OR @enabled_for_syncmgr IS NOT NULL
			OR @merge_job_name IS NOT NULL
		BEGIN
			-- "The %s parameter(s) have been deprecated from this procedure. The value(s) should now be specified when calling '%s'."
			RAISERROR(21838, 10, -1, 'scheduling, optional command line, sync manager and merge job name', 'sp_addmergepushsubscription_agent'' or ''sp_addmergepullsubscription_agent')

			SELECT @frequency_type = NULL,
					@frequency_interval = NULL,
					@frequency_relative_interval = NULL,
					@frequency_recurrence_factor = NULL,
					@frequency_subday = NULL,
					@frequency_subday_interval = NULL,
					@active_start_time_of_day = NULL,
					@active_end_time_of_day = NULL,
					@active_start_date = NULL,
					@active_end_date = NULL,
					@optional_command_line = NULL,
					@enabled_for_syncmgr = NULL,
					@merge_job_name = NULL
		END

        -- @internal = 'YUKON ADD SUB'. Passing this to sp_MSadd_mergesubscription
        -- signals that we are in 9.0 mode and adding the subscription only (no 
        -- code for adding the agent job will be executed)
        SELECT @internal = N'YUKON ADD SUB'
    END
    ELSE
    BEGIN
        -- Set the original default values for the 8.0 model
        SELECT @enabled_for_syncmgr = ISNULL(@enabled_for_syncmgr, N'false'),
                @use_interactive_resolver = ISNULL(@use_interactive_resolver, N'false')

        -- set @internal = 'PRE-YUKON'. This will be passed to sp_MSadd_mergesubscription 
        -- and signals that we are in 8.0 mode and will allow both the code for adding
        -- the subscription and the agent job to be executed
        SELECT @internal = N'PRE-YUKON'
    END
    
    /*
    ** Parameter Check: @subscriber
    ** Check to make sure that the subscriber is defined
    */
    IF @subscriber IS NULL or ltrim(rtrim(@subscriber)) = N''
        BEGIN
            RAISERROR (14043, 16, -1, '@subscriber', 'sp_addmergesubscription')
            RETURN (1)
        END

    IF @subscriber = 'all'
        BEGIN
            RAISERROR (14136, 16, -1)
            RETURN (1)
        END

    
    EXECUTE @retcode = sys.sp_validname @subscriber
    IF @@ERROR <> 0 OR @retcode <> 0
       RETURN (1)
    
    -- Get subscriber port number
    declare @subscriber_with_port sysname
        exec sys.sp_MSget_server_portinfo 
            @name = @subscriber, 
            @srvname = @subscriber OUTPUT,
            @srvname_with_port = @subscriber_with_port OUTPUT

    /*
    ** Parameter Check: @subscriber_db
    */
    IF @subscriber_db IS NULL or ltrim(rtrim(@subscriber_db)) = N''
    BEGIN
        RAISERROR (14043, 16, -1, '@subscriber_db', 'sp_addmergesubscription')
        RETURN (1)
    END

    IF @subscriber_db = 'all'
    BEGIN
        RAISERROR (14136, 16, -1)
        RETURN (1)
    END

    --
    -- @subscriber_db cannot be master
    --
    if LOWER(@subscriber_db) = 'master'
    BEGIN
        RAISERROR (21481, 16, 1)
        RETURN (1)
    END
    
    /*
    **    Check to see if system tables exist. If not create them. Since under current
    **    design every database is qualified for subscribing.
    */
    
    IF object_id('sysmergesubscriptions') is NULL
    BEGIN
        execute @retcode = sys.sp_MScreate_mergesystables @whattocreate=1
        if @@ERROR <> 0 or @retcode <> 0 return (1)

--        execute @retcode = sys.sp_MScreate_DDLtriggers
--        if @@ERROR <> 0 or @retcode <> 0 return (1)

        execute @retcode= sys.sp_MSrepl_ddl_triggers @type='merge', @mode='add'
        if @@ERROR <> 0 or @retcode <> 0 return (1)                        
    END 
        
    /*
    ** Parameter Check: @publication.
    ** Check to make sure that the publication exists and that it conforms
    ** to the rules for identifiers.
    */
    if NOT EXISTS (select * FROM dbo.sysmergepublications 
        WHERE name = @publication and UPPER(publisher)=UPPER(publishingservername()) and publisher_db=db_name())
        BEGIN
            RAISERROR (20026, 16, -1, @publication)
            RETURN (1)
        END

    if @pubid IS NULL
        select @pubid = pubid, @compatlevel = backward_comp_level FROM dbo.sysmergepublications 
            WHERE name = @publication and UPPER(publisher)=UPPER(publishingservername()) and publisher_db=db_name()

    /*
    ** Parameter Check: @subscriber_type.
    ** Set subscriber_typeid based on the @subscriber_type specified.
    **
    **     subscriber_type     subscriber_type
    **     =================      ===============
    **               1            global
    **               2            local
    **               3            anonymous
    **                            Type 'republisher' is taken out for B3. We may want to add this back later.
    */
    if LOWER(@subscriber_type collate SQL_Latin1_General_CP1_CS_AS) NOT IN ('local', 'global')
        BEGIN
            RAISERROR (21337, 16, -1)
            RETURN (1)
        END

    if LOWER(@subscriber_type collate SQL_Latin1_General_CP1_CS_AS) IN ('global')
        set @subscriber_typeid = 1
    else if LOWER(@subscriber_type collate SQL_Latin1_General_CP1_CS_AS) IN ('local')
        set @subscriber_typeid = 2

    /*
    ** Parameter Check: @use_interactive_resolver  
    */
    IF @use_interactive_resolver IS NOT NULL
        AND LOWER(@use_interactive_resolver collate SQL_Latin1_General_CP1_CS_AS) NOT IN ('true', 'false')
    BEGIN
        RAISERROR (14148, 16, -1, '@use_interactive_resolver')
        RETURN (1)
    END
    
    if LOWER(@use_interactive_resolver collate SQL_Latin1_General_CP1_CS_AS) = 'true'
        set @use_interactive_bit = 1
    else 
        set @use_interactive_bit = 0

    
    /* 
    ** Assign priority appropriately - choose 0.99 times the minimum priority
    ** of the global replicas.
    */
    if (@subscription_priority >= 100.0 or @subscription_priority < 0.0)
        BEGIN
            RAISERROR (20088, 16, -1)
            RETURN (1)
        END
    if (@subscription_priority IS NULL)
        begin
            select @priority = 0.99 * min(priority) from dbo.sysmergesubscriptions where subscriber_type = 1
            if (@priority IS NOT NULL)
                select @subscription_priority = @priority
            if (@subscription_priority IS NULL) 
                select @subscription_priority = 0.0
        end
    /*
    ** For local and anonymous subscriptions the priority is 0.0
    */
    if LOWER(@subscriber_type collate SQL_Latin1_General_CP1_CS_AS) IN ('local', 'anonymous')
        select @subscription_priority = 0.0
    
    /*
    ** Validate that if Transactional subscriptions exist, that the same article is not subscribed to a 
    ** tran publication.
    */    
    IF object_id('syssubscriptions') is not NULL
    begin
        select @subscriber_srvid = srvid from master.dbo.sysservers where UPPER(srvname) = UPPER(@subscriber) collate database_default
        IF @subscriber_srvid IS NOT NULL
        BEGIN
            if exists (select name from dbo.sysmergeextendedarticlesview where pubid=@pubid and objid in
                (select objid from sysextendedarticlesview where artid in
                    (select artid from syssubscriptions where dest_db=@subscriber_db and UPPER(srvname) = UPPER(@subscriber) collate database_default)))
            begin
                RAISERROR(21280, 16, -1, @publication, @subscriber_db)
                RETURN (1)
            end
        END
    end


    /* 
    ** Parameter Check: Make sure that the subscriber,subscription_db and publisher,publication_db are different
    ** This proc is called on the publisher and publisher db.
    */
    if ((UPPER(publishingservername()) = UPPER(@subscriber)) and (@subscriber_db = db_name()))
    begin
        RAISERROR (21690, 16, -1)
        RETURN (1)
    end
    
    /*
    ** Making it possible for a deleted subscription to come back.
    ** UNDONE : This disallows second pull subscription from being added unless the previous 
    ** subscription was initial synced.
    */
    -- ignore anonymous subscriptions. Entries for it may be present due to subscriber tracking
    if EXISTS (select *    FROM dbo.sysmergesubscriptions
                WHERE db_name = @subscriber_db
                AND UPPER(subscriber_server) collate database_default = UPPER(@subscriber) collate database_default 
                AND pubid = @pubid AND status <>2 --We can definitely add back subscriptions that were deleted.
                and subscription_type <> 2 and subscription_type <> 3) 
        BEGIN
            RAISERROR (14058, 16, -1)
            RETURN (1)
        END

    -- delete if there exists an anonymous subscriptions as well
    select @subid = NULL
    select @subid = subid FROM dbo.sysmergesubscriptions 
               WHERE db_name = @subscriber_db  
                 AND UPPER(subscriber_server) collate database_default = UPPER(@subscriber) collate database_default
                 AND pubid = @pubid AND (status = 2 or subscription_type = 2 or subscription_type = 3)
    if @subid is not NULL
    BEGIN
    
		-- delete supportability settings for the subscriptions that we are about to delete.
	    delete from dbo.MSmerge_supportability_settings where subid = @subid        	
	    delete from dbo.MSmerge_log_files where subid = @subid

        delete from dbo.sysmergesubscriptions where subid = @subid
        exec sys.sp_MScleanup_subscriber_history @subid=@subid
        delete from dbo.MSmerge_replinfo where repid = @subid

        -- If the only remaining subscriptions are old entries (before restore),
        -- we remove them now.
        if not exists (select * from dbo.sysmergesubscriptions 
                            where status <> 7) -- REPLICA_STATUS_BeforeRestore
        begin
            delete from dbo.sysmergesubscriptions
            truncate table dbo.MSmerge_supportability_settings
            truncate table dbo.MSmerge_log_files
            truncate table dbo.MSrepl_errors
			truncate table dbo.MSmerge_history
			truncate table dbo.MSmerge_articlehistory
			truncate table dbo.MSmerge_sessions
            delete from dbo.MSmerge_replinfo
        end
    END

    /* 
    ** Downlevel subscribers (8.0 and lower) run merge agents which select the srvid entry of the subscriber from the Publisher
    ** In order to support that, we check the srvid entry and if not pre-existing, we execute the sp_MSadd_subserver proc that 
    ** does an execute as DBO
    */
    if (@compatlevel <  @REPOLEVersion_90)
    begin
        SELECT @subscriber_srvid = srvid from master..sysservers where UPPER(srvname) = UPPER(@subscriber) collate database_default
        if @subscriber_srvid is NULL
        	begin
            declare @provstr nvarchar(4000)
            set @provstr = sys.fn_getproviderstring(@subscriber_with_port)
        	EXEC @retcode = sys.sp_MSadd_subserver @subscriber = @subscriber, @type = 0, @subscriber_provstr = @provstr

            IF @@error <> 0 OR @retcode <> 0
                BEGIN
                    RAISERROR (14042, 16, -1)
                    RETURN (1)
                END
        	end            	
    end

    select @subid = newid()       
    
   /*
   ** Parameter Check: @sync_type.
   ** Set sync_typeid based on the @sync_type specified.
   **
   **    sync_typeid        sync_type
   **    ===========        =========
   **              1        automatic
   **              2        none
   */


   IF LOWER(@sync_type collate SQL_Latin1_General_CP1_CS_AS) NOT IN ('automatic', 'none')
       BEGIN
           RAISERROR (14052, 16, -1)
           RETURN (1)
       END


    /*
    ** If current publication contains an article without rowguidcol, do not allow no-sync subscription
    */
   IF LOWER(@sync_type collate SQL_Latin1_General_CP1_CS_AS) = 'automatic'
   BEGIN
        SET @sync_typeid = @automatic
   END
   ELSE
   BEGIN
        if exists (select * from dbo.sysmergearticles a where pubid=@pubid and 
            not exists (select * from sys.columns c where c.object_id = a.objid and c.is_rowguidcol = 1))
            
            BEGIN
                Raiserror(20086, 16, -1, @publication)
                RETURN (1)
            END
        else 
            SET @sync_typeid = @nosync
   END


    /*
    ** UNDONE: Validate that the publisher is of type "republisher"
    */
    begin tran
    save TRAN addmergesubscription
        /* Generate a guid for the Subscriber ID */
    
        /* Look for existing nickname from any other subscription */
        exec @retcode = sys.sp_MSgetreplnick @subscriber, @subscriber_db , NULL,  @subnickname out
        if (@@error <> 0) or @retcode <> 0 
            GOTO FAILURE
            
        /* Generate a new replica nickname from the @subid */
        if (@subnickname is null)
        begin
            EXECUTE sys.sp_MSgenreplnickname 
                            @srcguid= @subid, 
                            @replnick= @subnickname output
            if @@ERROR<>0 
                GOTO FAILURE
        end
            
        /*
        ** The subscription doesn't exist, so let's add it to dbo.sysmergesubscriptions 
        */
        INSERT dbo.sysmergesubscriptions (subscriber_server, db_name, pubid, datasource_type,
                subid, replnickname, replicastate, status, subscriber_type, subscription_type,
                sync_type, description, priority)
        VALUES (@subscriber, @subscriber_db, @pubid, @datasource_type, 
                @subid, @subnickname, newid(), @inactive, @subscriber_typeid, @subscription_type_id,
                @sync_typeid, @description, @subscription_priority)
        if @@ERROR <> 0
        BEGIN
            GOTO FAILURE
        END
                
        /*
        ** Get distribution server information for remote RPC call.
        */
        EXECUTE @retcode = sys.sp_helpdistributor @rpcsrvname = @distributor OUTPUT,
           @distribdb    = @distribdb OUTPUT
        IF @@ERROR <> 0 or @retcode <> 0
            BEGIN
                GOTO FAILURE
            END
            
        declare @publisher_engine_edition int

        select @publisher_engine_edition = sys.fn_MSrepl_editionid()
       
        SELECT @distproc = QUOTENAME(RTRIM(@distributor)) + '.' + QUOTENAME(RTRIM(@distribdb)) + 
            '.dbo.sp_MSadd_merge_subscription'
        EXEC @retcode = @distproc 
            @publisher = @publishingservername, 
            @publisher_db = @publisher_db, 
            @publication = @publication,
            @subscriber = @subscriber, 
            @subscriber_db = @subscriber_db, 
            @subscription_type = @subscription_type_id,
            @sync_type = @sync_typeid, 
            @status = @inactive,
            @frequency_type = @frequency_type,
            @frequency_interval = @frequency_interval,
            @frequency_relative_interval = @frequency_relative_interval,
            @frequency_recurrence_factor = @frequency_recurrence_factor,
            @frequency_subday = @frequency_subday,
            @frequency_subday_interval = @frequency_subday_interval,
            @active_start_time_of_day = @active_start_time_of_day,
            @active_end_time_of_day = @active_end_time_of_day,
            @active_start_date = @active_start_date,
            @active_end_date = @active_end_date,
            @optional_command_line = @optional_command_line,
            @merge_jobid = @merge_jobid OUTPUT,
            @agent_name = @merge_job_name,
            @hostname = @hostname,
            @description = @description,
            @subid = @subid,
            @internal = @internal,
            @publisher_engine_edition = @publisher_engine_edition
        IF @@ERROR <> 0 OR @retcode <> 0
            begin    
                goto FAILURE
            end
            
        /*
        **    Add row for subscription in dbo.MSmerge_replinfo.
        */
        insert dbo.MSmerge_replinfo(repid, login_name, use_interactive_resolver, hostname, merge_jobid)
                values (@subid, suser_sname(suser_sid()), @use_interactive_bit, @hostname, @merge_jobid)
        if @@ERROR <> 0
            BEGIN
                GOTO FAILURE
            END

        /* Conditional support for MobileSync */
        if sys.fn_yukonsecuritymodelrequired(NULL) = 0
            AND LOWER(@enabled_for_syncmgr collate SQL_Latin1_General_CP1_CS_AS) = 'true'
        BEGIN

            /* MobileSync Support */
            declare @distributor_server                    sysname
            declare @distributor_security_mode            int
            declare @distributor_login                    sysname
            declare @distributor_password                nvarchar(524)

            /* 
            ** The registry entry needs to be created only for push subscriptions -     
            ** i.e - need not be called when a pull subscription is created at the 
            ** subscriber and sp_addmergesubscription is being called then.
            */
            
            IF @subscription_type_id = 0 
            BEGIN
                EXECUTE @retcode = sys.sp_helpdistributor
                    @distributor = @distributor_server OUTPUT                /* Distributor RPC server name */
                IF @@ERROR <> 0 or @retcode <> 0
                    BEGIN
                        GOTO FAILURE
                    END

                -- Always use integrated security on winNT
                select @distributor_security_mode = 1,
                        @distributor_login = N'',
                        @distributor_password = newid()

                exec @retcode = sys.sp_MSreplencrypt @distributor_password output
                IF @@ERROR <> 0 or @retcode <> 0
                        GOTO FAILURE

                /* Call sp_MSregistersubscription so that the subscription can be synchronized via Onestop etc. */
                exec @retcode = sys.sp_MSregistersubscription @replication_type = 2,
                                    @publisher = @publishingservername,
                                    @publisher_db = @publisher_db,
                                    @publication = @publication,
                                    @subscriber = @subscriber,
                                    @subscriber_db = @subscriber_db,
                                    @distributor = @distributor,
                                    @distributor_security_mode = @distributor_security_mode,
                                    @distributor_login = @distributor_login,
                                    @distributor_password = @distributor_password,
                                    @subscription_id = @subid,
                                    @subscription_type = @subscription_type_id,
                                    @use_interactive_resolver = @use_interactive_bit,
                                    @hostname = @hostname
                IF @@error <> 0 OR @retcode <> 0
                BEGIN
                    GOTO FAILURE
                END

            END                                       
        END        
    COMMIT TRAN
    return (0)

FAILURE:
    RAISERROR (14057, 16, -1)
    /* UNDONE : This code is specific to 6.X nested transaction semantics */
    if @@TRANCOUNT > 0
    begin
        ROLLBACK TRANSACTION addmergesubscription
        COMMIT TRANSACTION
    end
    RETURN (1)

GO
GRANT EXECUTE ON [sys].[sp_addmergesubscription] TO [public] AS [dbo]
GO
