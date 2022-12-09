SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_dropmergesubscription]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_dropmergesubscription] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_dropmergesubscription]
	@publication [sysname],
	@subscriber [sysname],
	@subscriber_db [sysname],
	@subscription_type [nvarchar](15),
	@ignore_distributor [bit],
	@reserved [bit]
WITH EXECUTE AS CALLER
AS
SET NOCOUNT ON

    /*
    ** Declarations.
    */
    declare @retcode                int
    declare @subscriber_bit            smallint
    declare @subscriber_type        smallint
    declare @pubid                    uniqueidentifier
    declare @subid                    uniqueidentifier
    declare @subscription_type_id    int      
    declare @found_subscription        int      
    declare @cmd                    nvarchar(290)
    declare @distributor            sysname
    declare @distribdb                sysname
    declare @distproc                nvarchar(300)
    declare @pubidstr                nvarchar(38)
    declare @publisher                sysname
    declare @publisher_db            sysname

    declare @implicit_transaction    int
    declare @close_cursor_at_commit int
    			,@publishingservername sysname

    select @close_cursor_at_commit = 0
    select @implicit_transaction = 0
    		,@publishingservername = publishingservername()

    -- Security check
    if 1 <> is_member('db_owner')
    begin
        RAISERROR (15247, 11, -1)
        return 1
    end

    /*
    ** Save setting values first before changing them
    */
    IF (@reserved = 0)
    BEGIN
        SELECT @implicit_transaction = @@options & 2
        SELECT @close_cursor_at_commit = @@options & 4
        SET IMPLICIT_TRANSACTIONS OFF
        SET CURSOR_CLOSE_ON_COMMIT OFF
    END

     /*
    ** Initializations.
    */
    set @subscriber_bit        = 4
    set @subscription_type_id  = -1
    set @found_subscription   = 0                        
    set @publisher            = publishingservername()
    set @publisher_db         = DB_NAME()

    /*
    **    Check to see if current database is enabled for publishing/subscribing
    */
    IF object_id('sysmergesubscriptions') is NULL
    BEGIN
        RAISERROR (14055, 16, -1)
        RETURN (1)
    END

    /*
    ** Parameter Check: @subscription_type.
    ** Set subscription_typeid based on the @subscription_type specified.
    **
    **     subscription_type      subscription_type
    **     =================      ===============
    **               0            push
    **               1            pull
    */
    if LOWER(@subscription_type collate SQL_Latin1_General_CP1_CS_AS) NOT IN ('both', 'push', 'pull', 'anonymous', 'all')
    BEGIN
        RAISERROR (20727, 16, -1)
        RETURN (1)
    END
    IF LOWER(@subscription_type collate SQL_Latin1_General_CP1_CS_AS) = 'both'
    begin
        EXECUTE @retcode = sys.sp_dropmergesubscription @publication = @publication,
                        @subscriber = @subscriber,
                        @subscriber_db = @subscriber_db,
                        @subscription_type = 'push',
                        @ignore_distributor = @ignore_distributor,
                        @reserved = 1
        if @retcode<>0 or @@ERROR<>0
            return (1)
        EXECUTE @retcode = sys.sp_dropmergesubscription @publication = @publication,
                        @subscriber = @subscriber,
                        @subscriber_db = @subscriber_db,
                        @subscription_type = 'pull',
                        @ignore_distributor = @ignore_distributor,
                        @reserved = 1
        if @retcode<>0 or @@ERROR<>0
            return (1)
        return (0)
    end

    IF LOWER(@subscription_type collate SQL_Latin1_General_CP1_CS_AS) = 'all'
    begin
        EXECUTE @retcode = sys.sp_dropmergesubscription @publication = @publication,
                        @subscriber = @subscriber,
                        @subscriber_db = @subscriber_db,
                        @subscription_type = 'push',
                        @ignore_distributor = @ignore_distributor,
                        @reserved = 1
        if @retcode<>0 or @@ERROR<>0
            return (1)
        EXECUTE @retcode = sys.sp_dropmergesubscription @publication = @publication,
                        @subscriber = @subscriber,
                        @subscriber_db = @subscriber_db,
                        @subscription_type = 'pull',
                        @ignore_distributor = @ignore_distributor,
                        @reserved = 1
        if @retcode<>0 or @@ERROR<>0
            return (1)
        EXECUTE @retcode = sys.sp_dropmergesubscription @publication = @publication,
                        @subscriber = @subscriber,
                        @subscriber_db = @subscriber_db,
                        @subscription_type = 'anonymous',
                        @ignore_distributor = @ignore_distributor,
                        @reserved = 1
        if @retcode<>0 or @@ERROR<>0
            return (1)
        return (0)
    end 

    IF LOWER(@subscription_type collate SQL_Latin1_General_CP1_CS_AS) = 'push'
        set @subscription_type_id = 0
    else IF LOWER(@subscription_type collate SQL_Latin1_General_CP1_CS_AS) = 'anonymous'
        set @subscription_type_id = 2
    else 
        set @subscription_type_id = 1

    /*
    ** Parameter validation (different for push and pull modes)
    */

    IF LOWER(@subscription_type collate SQL_Latin1_General_CP1_CS_AS) = 'push'
    begin
        /*
        ** Assign parameter values appropriately
        */
        if @publisher IS NULL
            set @publisher = publishingservername()
        if (@publisher_db IS NULL)
            set @publisher_db = DB_NAME()

        /*
        ** Parameter Check: @subscriber
        ** Check to make sure that the subscriber is defined
        */
        IF @subscriber IS NULL
        BEGIN
            RAISERROR (14043, 16, -1, '@subscriber', 'sp_dropmergesubscription')
            RETURN (1)
        END

        /*
        ** Parameter Check: @subscriber_db
        */
        IF @subscriber_db IS NULL
        BEGIN
            select @subscriber_db = 'all'
        END
            
    end
    else
    begin
        /*
        ** Assign parameter values appropriately
        */
        if @subscriber IS NULL
            set @subscriber = 'all'
        if @subscriber_db IS NULL
            set @subscriber_db = 'all'

    exec sys.sp_MSget_server_portinfo 
        @name = @subscriber, 
        @srvname = @subscriber OUTPUT

        /*
        ** Parameter Check: @publisher
        ** Check to make sure that the publisher is defined
        */
        IF @publisher IS NULL
        BEGIN
            RAISERROR (14043, 16, -1, '@publisher', 'sp_dropmergesubscription')
            RETURN (1)
        END

        EXECUTE @retcode = sys.sp_validname @publisher
        IF @@ERROR <> 0 OR @retcode <> 0
           RETURN (1)

        /*
        ** Parameter Check: @publisher_db
        */
        IF @publisher_db IS NULL
        BEGIN
            RAISERROR (14043, 16, -1, '@publisher_db', 'sp_dropmergesubscription')
            RETURN (1)
        END

    end        

    /*
    ** Parameter Check:     @publication.
    ** If the publication name is specified, check to make sure that it
    ** conforms to the rules for identifiers and that the publication
    ** actually exists.     Disallow NULL.
    */
    if @publication IS NULL
    BEGIN
        RAISERROR (14043, 16, -1, '@publication', 'sp_dropmergesubscription')
        RETURN (1)
    END

    IF LOWER(@publication) = 'all'
    BEGIN
        declare hC1 CURSOR LOCAL FAST_FORWARD FOR select DISTINCT name FROM dbo.sysmergepublications 
            where UPPER(publisher)=UPPER(publishingservername()) and publisher_db=db_name() 
            FOR READ ONLY
        
        OPEN hC1
        FETCH hC1 INTO @publication
        WHILE (@@fetch_status <> -1)
            BEGIN
                EXECUTE sys.sp_dropmergesubscription @publication = @publication,
                                            @subscriber = @subscriber,
                                            @subscriber_db = @subscriber_db,
                                            @subscription_type = @subscription_type,
                                            @ignore_distributor = @ignore_distributor,
                                            @reserved = 1
                FETCH hC1 INTO @publication
            END
        CLOSE hC1
        DEALLOCATE hC1
        RETURN (0)
    END
        
    if NOT EXISTS (select * FROM dbo.sysmergepublications 
        WHERE name = @publication and UPPER(publisher)=UPPER(publishingservername()) and publisher_db=db_name())
    BEGIN
        RAISERROR (20026, 16, -1, @publication)
        RETURN (1)
    END
    
    select @pubid = pubid from dbo.sysmergepublications 
        where name = @publication and UPPER(publisher)=UPPER(publishingservername()) and publisher_db=db_name()
    set @pubidstr = '''' + convert(nchar(36), @pubid) + ''''
    if @pubid is null
    BEGIN
        RAISERROR (20026, 16, -1, @publication)
        RETURN (1)
    END

       
    IF LOWER(@subscriber) = 'all'
    BEGIN
        declare hC2 CURSOR LOCAL FAST_FORWARD FOR select DISTINCT subscriber_server FROM dbo.sysmergesubscriptions
            WHERE  subid <> pubid 
                AND dbo.sysmergesubscriptions.pubid = @pubid
                AND dbo.sysmergesubscriptions.subscription_type = @subscription_type_id
            FOR READ ONLY
        OPEN hC2
        FETCH hC2 INTO @subscriber
        WHILE (@@fetch_status <> -1)
        BEGIN
            EXECUTE sys.sp_dropmergesubscription @publication = @publication,
                                        @subscriber = @subscriber,
                                        @subscriber_db = @subscriber_db,
                                        @subscription_type = @subscription_type,
                                        @ignore_distributor = @ignore_distributor,
                                        @reserved = 1
            FETCH hC2 INTO @subscriber
        END
        CLOSE hC2
        DEALLOCATE hC2
        RETURN (0)
    END

    /*
    ** NOTE: remove this batch
    */
    IF LOWER(@subscriber_db) = 'all'
    BEGIN
            declare hC3 CURSOR LOCAL FAST_FORWARD FOR select DISTINCT db_name FROM dbo.sysmergesubscriptions
            WHERE UPPER(subscriber_server) collate database_default = UPPER(@subscriber) collate database_default 
                AND subid <> pubid 
                AND dbo.sysmergesubscriptions.pubid = @pubid
                AND dbo.sysmergesubscriptions.subscription_type = @subscription_type_id
            FOR READ ONLY        

        OPEN hC3
        FETCH hC3 INTO @subscriber_db
        WHILE (@@fetch_status <> -1)
        BEGIN
            EXECUTE sys.sp_dropmergesubscription @publication = @publication,
                                        @subscriber = @subscriber,
                                        @subscriber_db = @subscriber_db,
                                        @subscription_type = @subscription_type,
                                        @ignore_distributor = @ignore_distributor,
                                        @reserved = 1

            FETCH hC3 INTO @subscriber_db
        END
        CLOSE hC3
        DEALLOCATE hC3
        RETURN (0)
    END

    select @pubid=pubid from dbo.sysmergepublications where name=@publication and UPPER(publisher)=UPPER(publishingservername()) and publisher_db=db_name()
    if @pubid is NULL 
        return (0)
    
    if exists (select * from dbo.sysmergesubscriptions where subid=@pubid 
        and pubid=@pubid and db_name<>db_name())
    RETURN (0)
    
    /*
    ** Get subscriptions from either local replicas or global replicas
    */
    select @subid = subs.subid, @subscriber_type = subs.subscriber_type from
        dbo.sysmergesubscriptions    subs,
        dbo.sysmergepublications        pubs,
        dbo.MSmerge_replinfo    rep
        where UPPER(subs.subscriber_server) collate database_default = UPPER(@subscriber) collate database_default
            and subs.db_name = @subscriber_db
            and subs.pubid <> subs.subid
            and subs.pubid = pubs.pubid
            and pubs.name = @publication
            and UPPER(pubs.publisher)=UPPER(publishingservername())
            and pubs.publisher_db=db_name()
            and subs.subscription_type = @subscription_type_id
            and rep.repid = subs.subid
            and (is_member('db_owner')=1 OR suser_sname(suser_sid())=rep.login_name)

    if @subid IS NULL
    begin
        -- raiserror (14050, 16, -1) 
        RETURN (0)
    end                    

    begin tran
    save TRAN dropmergesubscription

        /*
        ** Do not drop the subscription corresponding to the loopback subscription 
        */
        if (@subid <> @pubid) 
        begin
            /*
            ** global/republisher subscriptions have to stay for a while even after being
            ** dropped so that they won't regain lives for themselves. They would be cleanup eventually.
            */
            
            if (@subscriber_type<>1) 
            begin
                -- delete supportability settings for the subscriptions that we are about to delete.
                delete from dbo.MSmerge_supportability_settings where subid = @subid            
                delete from dbo.MSmerge_log_files where subid = @subid

                delete from dbo.sysmergesubscriptions where subid = @subid
                IF @@ERROR <> 0
                    GOTO FAILURE        
                exec sys.sp_MScleanup_subscriber_history @subid = @subid
                if @@ERROR<>0 
                    goto FAILURE    
                    
                delete dbo.MSmerge_replinfo WHERE repid = @subid 
                IF @@ERROR <> 0
                    GOTO FAILURE

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
            end
            else
            begin
                update dbo.sysmergesubscriptions set status=2 where subid=@subid
                IF @@ERROR<>0
                    GOTO FAILURE
            end 

            /* 
            ** The MobileSync registry entry needs to be dropped only for push subscriptions -    
            ** i.e - need not be called when a pull subscription is created at the 
            ** subscriber and sp_addmergesubscription is being called then.
            */
            IF LOWER(@subscription_type collate SQL_Latin1_General_CP1_CS_AS) = 'push'
            begin
                /* Call sp_MSunregistersubscription so that the reg entries get deleted */
                exec @retcode = sys.sp_MSunregistersubscription @publisher = @publishingservername,
                                @publisher_db = @publisher_db,
                                @publication = @publication,
                                @subscriber = @subscriber,
                                @subscriber_db = @subscriber_db
                IF @retcode<>0 or @@ERROR<>0
                    GOTO FAILURE

            END                
        end        

        /*
        ** if @ignore_distributor = 1, we are in bruteforce cleanup mode, don't do RPC.
        */
        -- cleanup required for 'anonymous' subscriptions as well, hence removing
        -- '@subscriber_type <>3' condition, bug 81257, sql bu
        if @ignore_distributor = 0
        begin
            /*
            ** Get distribution server information for remote RPC call.
            */
            EXECUTE @retcode = sys.sp_helpdistributor @rpcsrvname = @distributor OUTPUT,
               @distribdb    = @distribdb OUTPUT
            IF @@ERROR <> 0 or @retcode <> 0
                BEGIN
                    GOTO FAILURE
                END

            SELECT @distproc = QUOTENAME(RTRIM(@distributor)) + '.' + QUOTENAME(RTRIM(@distribdb)) + 
                '.dbo.sp_MSdrop_merge_subscription'

            EXEC @retcode = @distproc 
                @publishingservername, 
                @publisher_db, 
                @publication,
                @subscriber, 
                @subscriber_db,
                @subscription_type
            IF @@ERROR <> 0 OR @retcode <> 0
                begin    
                    goto FAILURE
                end 
        end 

        /* 
        ** If last subscription is dropped and the DB is not enabled for publishing,
        ** then remove the merge system tables
        */
        -- ignore remaining anonymous or lightweight subscriptions whose entries might be there due to subscriber tracking.
        IF (not exists (select * from dbo.sysmergesubscriptions where subscription_type <> 2 and subscription_type <> 3)) 
            AND (select category & 4 FROM master.dbo.sysdatabases WHERE name = DB_NAME() collate database_default)=0
        BEGIN
            execute @retcode = sys.sp_MSdrop_mergesystables @whattodrop=1
            if @@ERROR <> 0 or @retcode <> 0 return (1)
        END            

    COMMIT TRAN
    /*
    ** Set back original settings
    */    
    IF @reserved = 0
    BEGIN
        IF @implicit_transaction <>0 
            SET IMPLICIT_TRANSACTIONS ON
        IF @close_cursor_at_commit <>0 
            SET CURSOR_CLOSE_ON_COMMIT ON
    END
    RETURN(0)        

FAILURE:
    /* UNDONE : This code is specific to 6.X nested transaction semantics */
    RAISERROR (14056, 16, -1)
    if @@TRANCOUNT > 0
    begin
        ROLLBACK TRANSACTION dropmergesubscription
        COMMIT TRANSACTION
    end
    /*
    ** Set back original settings
    */    
    IF @reserved = 0
    BEGIN
        IF @implicit_transaction <>0 
            SET IMPLICIT_TRANSACTIONS ON
        IF @close_cursor_at_commit <>0 
            SET CURSOR_CLOSE_ON_COMMIT ON
    END
    return (1)
GO
GRANT EXECUTE ON [sys].[sp_dropmergesubscription] TO [public] AS [dbo]
GO
