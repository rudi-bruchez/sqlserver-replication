SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_addmergepullsubscription]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_addmergepullsubscription] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_addmergepullsubscription]
	@publication [sysname],
	@publisher [sysname],
	@publisher_db [sysname],
	@subscriber_type [nvarchar](15),
	@subscription_priority [real],
	@sync_type [nvarchar](15),
	@description [nvarchar](255)
WITH EXECUTE AS CALLER
AS
SET NOCOUNT ON

    /*
    ** Declarations.
    */
    declare @retcode                int
    declare    @subscriber_db            sysname
    declare @pubnickname            binary(6)
    declare @subnickname            binary(6)
    declare @subscriber                sysname
    declare @priority                 real
    declare @subid                     uniqueidentifier
    declare @subscriber_typeid         smallint
    declare @subscription_typeid     smallint
    declare @command                 nvarchar(255)
    declare @inactive                tinyint 
    declare @global                 tinyint        /* subscriber type is global */
    declare @push                     tinyint        /* subscription type is push */
     
    declare @sync_typeid             tinyint
    declare @nosync                 tinyint        
    declare @automatic                tinyint             
    declare @pubid                    uniqueidentifier             
    declare @parentid               uniqueidentifier
    declare @backward_comp_level    int

    SET @nosync             = 2       /* Const: synchronization type 'none' */
    SET @automatic             = 1       /* Const: synchronization type 'automatic' */
    SET @inactive             = 0
    SET @global             = 1
    SET @push                 = 0   

    set @pubid                 = newid()
    set @parentid            = '00000000-0000-0000-0000-000000000000'

    /* 
    ** Check if replication components are installed on this server
    */
    exec @retcode = sys.sp_MS_replication_installed
    if (@retcode <> 1)
    begin
        return (1)
    end
	
	if @publisher is null
		set @publisher = publishingservername()

    -- Get publisher port number
    exec sys.sp_MSget_server_portinfo 
        @name = @publisher, 
        @srvname = @publisher OUTPUT

    /*
    ** Security Check.
    */

    EXEC @retcode = sys.sp_MSreplcheck_subscribe
    if @@ERROR <> 0 or @retcode <> 0
        return(1)

    /*
    ** Assign parameter values appropriately for the local server database
    */
    set @subscriber_db = DB_NAME()
    select @subscriber = @@SERVERNAME
    --
    -- @subscriber_db cannot be master
    --
    if LOWER(@subscriber_db) = 'master'
    BEGIN
        RAISERROR (21481, 16, 1)
        RETURN (1)
    END


    /*
    ** Parameter Check: @publisher
    ** Check to make sure that the publisher is defined
    */
    IF @publisher IS NULL
    BEGIN
        RAISERROR (14043, 16, -1, '@publisher', 'sp_addmergepullsubscription')
        RETURN (1)
    END

    IF LOWER(@publisher) = 'all'
    BEGIN
        RAISERROR (14136, 16, -1)
        RETURN (1)
    END
    
    /*
    ** Parameter Check: @publisher_db
    */
    IF @publisher_db IS NULL
    BEGIN
        RAISERROR (14043, 16, -1, '@publisher_db', 'sp_addmergepullsubscription')
        RETURN (1)
    END

    IF LOWER(@publisher_db) = 'all'
    BEGIN
        RAISERROR (14136, 16, -1)
        RETURN (1)
    END


   /*
   ** Parameter Check: @sync_type.
   ** Set sync_typeid based on the @sync_type specified.
   **
   **   sync_typeid     sync_type
   **   ===========     =========
   **             1     automatic
   **             2     none
   */

   IF LOWER(@sync_type collate SQL_Latin1_General_CP1_CS_AS) NOT IN ('automatic', 'none')
   BEGIN
       RAISERROR (14052, 16, -1)
       RETURN (1)
   END


   IF LOWER(@sync_type collate SQL_Latin1_General_CP1_CS_AS) = 'automatic'
   BEGIN
        SET @sync_typeid = @automatic
   END
   ELSE
   BEGIN
        SET @sync_typeid = @nosync
   END

    /*
    ** Parameter Check: @subscriber_type.
    ** Set subscriber_typeid based on the @subscriber_type specified.
    **
    **   subscriber_type     subscriber_type
    **   =================    ===============
    **             1             global
    **             2             local
    **             3             anonymous
    **             4            lightweight
    */
    -- this really combines subscriber type and subscription type
    if LOWER(@subscriber_type collate SQL_Latin1_General_CP1_CS_AS) NOT IN ('local', 'global', 'anonymous', 'lightweight')
    BEGIN
          RAISERROR (20023, 16, -1)
        RETURN (1)
    END
       
    set @subscription_typeid = 1 /* pull by default */
    if LOWER(@subscriber_type collate SQL_Latin1_General_CP1_CS_AS) IN ('global')
        set @subscriber_typeid = 1
    else if LOWER(@subscriber_type collate SQL_Latin1_General_CP1_CS_AS) IN ('local')
        set @subscriber_typeid = 2
    else if LOWER(@subscriber_type collate SQL_Latin1_General_CP1_CS_AS) IN ('anonymous')
    begin
        set @subscriber_typeid = 3
        set @subscription_typeid = 2
    end
    else if LOWER(@subscriber_type collate SQL_Latin1_General_CP1_CS_AS) IN ('lightweight')
    begin
        set @subscriber_typeid = 3
        set @subscription_typeid = 3
    end

    /*
    **    Check to see if merge system tables exist. Create them unless they already
    **  exist.
    */
    IF object_id('sysmergesubscriptions', 'U') is NULL
    BEGIN
        if @subscription_typeid = 3
        begin
            execute @retcode = sys.sp_MScreate_mergesystables @whattocreate=2
        end
        else
        begin
            execute @retcode = sys.sp_MScreate_mergesystables @whattocreate=1
        end
        if @@ERROR <> 0 or @retcode <> 0 return (1)
    END

    if exists (select pubid from dbo.sysmergepublications where UPPER(publisher) = UPPER(publishingservername()) and publisher_db=db_name()) and @subscriber_type in ('local', 'anonymous', 'lightweight')
    begin
        declare @dbname sysname
        select @dbname = DB_NAME()
        raiserror(21258, 16, -1, @dbname)
        return (1)
    end

    select @backward_comp_level= sys.fn_MSgetmaxbackcompatlevel ()
    if @backward_comp_level > 100
        set @backward_comp_level = 100

    if @subscription_typeid = 3 -- lightweight
        set @backward_comp_level = 90

    -- we will default the backward_comp_level to 90 for beta 1 to be in sync with the default 90 changes in addmergepublication
    if not exists (select name from dbo.sysmergepublications)
        set @backward_comp_level = 90
        
    /* 
    ** When adding a pull subscription, if a push subscription for that publication already exists, 
    ** we will raise error and fail
    */
    IF EXISTS (select name from dbo.sysmergepublications where name = @publication and UPPER(publisher)=UPPER(@publisher) and publisher_db=@publisher_db)
    BEGIN
        select @pubid=pubid from dbo.sysmergepublications 
            where name = @publication and UPPER(publisher)=UPPER(@publisher) and publisher_db=@publisher_db
        IF EXISTS (select subid from dbo.sysmergesubscriptions 
                    where pubid=@pubid and subid<>@pubid and subscription_type=0 and
                    db_name = @subscriber_db and UPPER(subscriber_server) = UPPER(@subscriber))
        begin
            RAISERROR (21317, 16, -1, @publication)
            return (1)
        end

        IF EXISTS (select subid from dbo.sysmergesubscriptions 
                    where pubid=@pubid and db_name = @subscriber_db and 
                          UPPER(subscriber_server) = UPPER(@subscriber) and 
                          subid<>@pubid and status<>2)
        begin
            RAISERROR (14058, 16, -1)
            return (1)
        end
        
        IF EXISTS (select status from dbo.sysmergesubscriptions where pubid=@pubid and status =    2)
        begin
            delete dbo.MSmerge_replinfo where repid in 
                (select subid from dbo.sysmergesubscriptions where pubid=@pubid and subid<>pubid)
            delete from dbo.sysmergesubscriptions where pubid=@pubid
            delete from dbo.MSmerge_supportability_settings where pubid=@pubid
            delete from dbo.MSmerge_log_files where pubid=@pubid
            exec sys.sp_MScleanup_subscriber_history
        end
    END

    EXECUTE @retcode = sys.sp_validname @publisher
    IF @@ERROR <> 0 OR @retcode <> 0 RETURN (1)


    if UPPER(@publisher) = UPPER(publishingservername()) and @publisher_db = db_name()
    begin
        raiserror(21126, 16, -1)
        return (1)
    end


    /*
    ** Check to see if the publication name is already used in the subscription 
    ** database - This is the case where we are resubscribing to the same publication.
    ** Execute dbo.sp_MSpublicationcleanup to cleanup all all the defunct rows

    ** if exists (select * from dbo.sysmergepublications where name = @publication)
    ** begin
    **    exec @retcode = dbo.sp_MSpublicationcleanup 
    **    IF @@ERROR <> 0 OR @retcode <> 0
    **    BEGIN
    **            RAISERROR (20025, 16, -1, @publication)
    **            RETURN (1)
    **      END        
    ** end
    */

    /* 
    ** Assign priority appropriately - choose 0.99 times the minimum priority
    ** of the global replicas.
    */
    if (@subscription_priority > 100.0 or @subscription_priority < 0.0)
        set @subscription_priority = NULL        

    if (@subscription_priority IS NULL)
    begin
        select @priority = 0.99 * min(priority) from dbo.sysmergesubscriptions where subscriber_type  = 1 /* global/loopback */
        if (@priority IS NOT NULL)
            select @subscription_priority = @priority
        if (@subscription_priority IS NULL) 
            select @subscription_priority = 0.0
    end

    /*
    ** For local and anonymous subscriptions the priority is 0.0
    */
    if @subscriber_typeid = 2 or @subscriber_typeid = 3
        select @subscription_priority = 0.0


    /*
    ** UNDONE: Validate that the publisher is of type 'republisher'
    */
    begin tran
    save TRAN addmergepullsubscription

    /* Generate a guid for the Subscriber ID */
    set @subid = newid()

    /* Look for existing nickname from any other subscription */
    exec sys.sp_MSgetreplnick NULL, NULL , NULL,  @subnickname out
    if (@@error <> 0) 
    begin
        goto FAILURE
    end                 

    /* Generate a new replica nickname from the @subid */
    if (@subnickname is null)
        EXECUTE sys.sp_MSgenreplnickname 
                        @srcguid= @subid, 
                        @replnick= @subnickname output, 
                        @compatlevel= @backward_comp_level

    /* 
    ** Check to see if MSsubscription_properties table exists.
    ** If not, create it.
    */
    exec @retcode = sys.sp_MScreate_sub_tables_internal
        @tran_sub_table = 0,
        @property_table = 1,
        @sqlqueue_table = 0

    IF @@ERROR <> 0 or @retcode <> 0
        goto FAILURE

    /*
    ** The subscription doesn't exist, so let's add it to dbo.sysmergesubscriptions 
    */
    INSERT dbo.sysmergesubscriptions (subscriber_server, db_name, pubid, datasource_type,
            subid, replnickname, replicastate, status, subscriber_type, subscription_type,
            sync_type, description, priority, replica_version)
    VALUES (@subscriber, @subscriber_db, @pubid, 0, 
            @subid, @subnickname, newid(), @inactive, @subscriber_typeid, @subscription_typeid,
            @sync_typeid, @description, @subscription_priority, 90)
    if @@ERROR <> 0 goto FAILURE
            
    /*
    **  Add row for subscription in dbo.MSmerge_replinfo.
    */
    insert dbo.MSmerge_replinfo(repid, login_name)
            values (@subid, suser_sname(suser_sid()))
    if @@ERROR <> 0 goto FAILURE


    /* Generate a new replica nickname from the @pubid */
    execute @retcode = sys.sp_MSgenreplnickname 
                            @srcguid= @pubid, 
                            @replnick= @pubnickname output, 
                            @compatlevel= @backward_comp_level
    IF @@ERROR <>0 OR @retcode <> 0
    BEGIN
        RAISERROR (20077, 16, -1)
        goto FAILURE
    END

    /* Add a self-subscribed subscription to represent the publication */
    if not exists (select * from dbo.sysmergepublications where pubid = @pubid)
    begin
        insert dbo.sysmergepublications(publisher, publisher_db, pubid, name, parentid, backward_comp_level, distributor) 
            values(@publisher, @publisher_db, @pubid, @publication, @parentid, @backward_comp_level, @publisher)
    end
    if @@ERROR <> 0 goto FAILURE

    if not exists (select * from dbo.sysmergesubscriptions where pubid = @pubid and subid = pubid)
    begin
        INSERT dbo.sysmergesubscriptions (subscriber_server, db_name, pubid, datasource_type,
                subid, replnickname, replicastate, status, subscriber_type, subscription_type,
                sync_type, description, priority, replica_version)
        VALUES (@publisher, @publisher_db, @pubid, 0, 
                @pubid, @pubnickname, newid(), @inactive, @global, @push,
                @sync_typeid, @description, 100.0, 90)
    end
    if @@ERROR <> 0 goto FAILURE


    /*
    **  Add row for merge publication to dbo.MSmerge_replinfo.
    */
    insert dbo.MSmerge_replinfo(repid, login_name)
        values (@pubid, suser_sname(suser_sid()))
    if @@ERROR <> 0 goto FAILURE


    COMMIT TRAN
    return (0)

FAILURE:
    RAISERROR (14057, 16, -1)
    if @@trancount > 0
    begin
        ROLLBACK TRANSACTION addmergepullsubscription
        COMMIT TRANSACTION
    end
    RETURN (1)
GO
GRANT EXECUTE ON [sys].[sp_addmergepullsubscription] TO [public] AS [dbo]
GO
