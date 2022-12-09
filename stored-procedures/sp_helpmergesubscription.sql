SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_helpmergesubscription]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_helpmergesubscription] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_helpmergesubscription]
	@publication [sysname],
	@subscriber [sysname],
	@subscriber_db [sysname],
	@publisher [sysname],
	@publisher_db [sysname],
	@subscription_type [nvarchar](15),
	@found [int] OUTPUT
WITH EXECUTE AS CALLER
AS
SET NOCOUNT ON

    /*
    ** Declarations.
    */

    declare @db                    sysname
    declare @retcode            int
    declare @subscriber_bit        smallint
    declare @srvid                int
    declare @pubid                uniqueidentifier
    declare @subid                uniqueidentifier
    declare @cursor_open        int
    declare @no_row                bit
    declare @subscription_type_id int

    declare @distributor    sysname
    declare @distributiondb sysname
    declare @distproc        nvarchar(300)
    declare @dbname            sysname
    			,@publishingservername sysname

    select @distributor = null
    select @distributiondb = null
    select @distproc = null
    select @dbname = null     
    		,@publishingservername = publishingservername()

    /*
    ** Initializations.
    */
    set @subscriber_bit        = 4
    set @cursor_open        = 0                    

    /*
    ** Initializations of @now_row.
    */
    IF @found is NULL
    BEGIN
        SELECT @no_row=0
    END
    ELSE
    BEGIN
        SELECT @no_row=1
    END

    select @db=db_name() -- so that it can appear in dynamic query

    /*
    **    Calling sp_help* is all right whether current database is enabled for pub/sub or not
    */

    IF object_id('sysmergesubscriptions') is NULL
        RETURN (0)
    
    /* Security check */
    EXEC @retcode = sys.sp_MSreplcheck_pull @publication = @publication, 
        @raise_fatal_error = 0
    if @@ERROR <> 0 or @retcode <> 0
        return(1)

    /*
    ** Parameter Check: @subscription_type.
    ** Set subscription_typeid based on the @subscription_type specified.
    **
    **     subscription_type      subscription_type
    **     =================      ===============
    **               0            push
    **               1            pull
    **              2            both
    */
    if LOWER(@subscription_type collate SQL_Latin1_General_CP1_CS_AS) NOT IN ('push', 'pull', 'both')
        BEGIN
            RAISERROR (20079, 16, -1)
            RETURN (1)
        END
    IF LOWER(@subscription_type collate SQL_Latin1_General_CP1_CS_AS) = 'both'
        set @subscription_type_id = 2
    else IF LOWER(@subscription_type collate SQL_Latin1_General_CP1_CS_AS) = 'push'
        set @subscription_type_id = 0
    else 
        set @subscription_type_id = 1

    /*
    ** Parameter Check: @publisher
    ** Check to make sure that the publisher is defined
    */
    IF @publisher <> '%'
    BEGIN
        EXECUTE @retcode = sys.sp_validname @publisher
        IF @@ERROR <> 0 OR @retcode <> 0
            RETURN (1)
    END

    /*
    ** Parameter Check:     @subscriber.
    ** If remote server, limit the view to the remote server's subscriptions.
    ** Make sure that the name isn't NULL.
    */
    if @subscriber IS NULL
        BEGIN
            RAISERROR (14043, 16, -1, '@subscriber', 'sp_helpmergesubscription')
            RETURN (1)
        END

    /*
    ** Parameter Check:     @subscriber.
    ** Check if remote server is defined as a subscription server, and
    ** that the name conforms to the rules for identifiers.
    */

    if @subscriber <> '%'
        BEGIN
            EXECUTE @retcode = sys.sp_validname @subscriber

            if @retcode <> 0 OR @@ERROR <> 0
                RETURN (1)

        END

    /*
    ** Parameter Check:     @publication.
    ** If the publication name is specified, check to make sure that it
    ** conforms to the rules for identifiers and that the publication
    ** actually exists.     Disallow NULL.
    */
    if @publication IS NULL
        BEGIN
            RAISERROR (14043, 16, -1, '@publication', 'sp_helpmergesubscription')
            RETURN (1)
        END

    create table #helpsubscription
                (
                    publication                sysname        collate database_default not null,
                    publisher                sysname        collate database_default not null,
                    publisher_db            sysname        collate database_default not null,
                    subscriber                sysname        collate database_default not null,
                    subscriber_db            sysname        collate database_default not null,
                    status                    int            NOT NULL,
                    subscriber_type            int            NOT NULL,
                    subscription_type        int            NOT NULL,
                    priority                float(8)    NOT NULL,
                    sync_type                tinyint        NOT NULL,
                    description                nvarchar(255) collate database_default null,
                    merge_jobid                binary(16)    NULL,
                    full_publication        tinyint        NULL,
                    use_interactive_resolver    int        NULL,
                    hostname                sysname        NULL
                )


    /* 
    ** Performance Optimization: Eliminate the 'LIKE' clause for publication name.
    **                             Empirical evidence shows almost 50% speed improvement when
    **                             opening the cursor if publication name is provided.
    */
    IF (@publication <> '%')
        insert into #helpsubscription select distinct pubs.name, pubs.publisher, pubs.publisher_db, subs.subscriber_server, subs.db_name, 
                        subs.status, subs.subscriber_type, subs.subscription_type, subs.priority, 
                        subs.sync_type, subs.description, replinfo.merge_jobid, pubs.publication_type,
                        replinfo.use_interactive_resolver, replinfo.hostname

                FROM  dbo.sysmergesubscriptions        subs,
                      dbo.MSmerge_replinfo        replinfo,
                      dbo.sysmergepublications    pubs
                    where   subs.status <> 2 
                        and pubs.pubid = subs.pubid
                        and subs.pubid <> subs.subid
                        and pubs.name =     @publication 
                        and replinfo.repid = subs.subid
                        and (suser_sname(suser_sid()) = replinfo.login_name OR is_member('db_owner')=1 OR is_srvrolemember('sysadmin') = 1)
                        and ((@subscriber_db = N'%') or (subs.db_name = @subscriber_db collate database_default))
                        and ((@publisher_db = N'%') or (pubs.publisher_db = @publisher_db collate database_default))
                        and ((@subscriber = N'%') or (UPPER(subs.subscriber_server) = UPPER(@subscriber) collate database_default)) 
                        and ((@publisher = N'%') or (UPPER(pubs.publisher) = UPPER(@publisher) collate database_default))
                        and (subs.subscription_type = @subscription_type_id or @subscription_type_id = 2)
                        and (subs.subscriber_type <> 3)
    ELSE
        insert into #helpsubscription select distinct pubs.name, pubs.publisher, pubs.publisher_db, subs.subscriber_server, subs.db_name, 
                        subs.status, subs.subscriber_type, subs.subscription_type, subs.priority, 
                        subs.sync_type, subs.description, replinfo.merge_jobid, pubs.publication_type,
                        replinfo.use_interactive_resolver, replinfo.hostname

                FROM  dbo.sysmergesubscriptions        subs,
                      dbo.MSmerge_replinfo        replinfo,
                      dbo.sysmergepublications    pubs
                    where   subs.status <> 2 
                        and pubs.pubid = subs.pubid
                        and subs.pubid <> subs.subid
                        and replinfo.repid = subs.subid
                        and (suser_sname(suser_sid()) = replinfo.login_name OR is_member('db_owner')=1 OR is_srvrolemember('sysadmin') = 1)
                        and ((@subscriber_db = N'%') or (subs.db_name = @subscriber_db collate database_default))
                        and ((@publisher_db = N'%') or (pubs.publisher_db = @publisher_db collate database_default))
                        and ((@subscriber = N'%') or (UPPER(subs.subscriber_server) = UPPER(@subscriber) collate database_default)) 
                        and ((@publisher = N'%') or (UPPER(pubs.publisher) = UPPER(@publisher) collate database_default))
                        and (subs.subscription_type = @subscription_type_id or @subscription_type_id = 2)
                        and (subs.subscriber_type <> 3)
        

    if exists (select * from #helpsubscription)
        select @found = 1
    else
        select @found = 0 
        
    if @no_row = 1
        goto DONE

    CREATE TABLE #merge_agent_properties
    (
        job_id                          VARBINARY(16) NULL,
        offload_enabled                  bit NULL,
        offload_server                  sysname collate database_default null,
        subscriber_security_mode    smallint NULL,
        subscriber_login            sysname NULL,
        job_login                    sysname NULL,
        publisher_security_mode     smallint NULL,
        publisher_login             sysname NULL,
        merge_agent_name            nvarchar(100) NULL
    )

    EXEC @retcode = sys.sp_helpdistributor @rpcsrvname = @distributor OUTPUT,
                                           @distribdb = @distributiondb OUTPUT
    IF @retcode <> 0
        GOTO DONE

    SELECT @distributor = RTRIM(@distributor)

    -- Get distribution agent properties 
    IF LOWER(@@SERVERNAME) <> LOWER(@distributor)
    BEGIN
        SELECT @distproc = QUOTENAME(@distributor) + '.' + QUOTENAME(@distributiondb) + 
                           '.dbo.sp_MSenum_merge_agent_properties'
    END       
    ELSE
    BEGIN
        SELECT @distproc = QUOTENAME(@distributiondb) + 
                           '.dbo.sp_MSenum_merge_agent_properties'
    END

    SELECT @dbname = db_name()

    INSERT INTO #merge_agent_properties
      EXEC @retcode = @distproc @publisher = @publishingservername, 
                                @publisher_db = @dbname, 
                                @publication = @publication,
                                @show_security = 1

    IF LOWER(@subscription_type collate SQL_Latin1_General_CP1_CS_AS) = 'push' or LOWER(@subscription_type collate SQL_Latin1_General_CP1_CS_AS) = 'both'
        begin
            select 'subscription_name'    = subscriber + ':' + subscriber_db,
                hs.publication, hs.publisher, hs.publisher_db, 
                hs.subscriber, hs.subscriber_db, hs.status, hs.subscriber_type,
                hs.subscription_type, hs.priority, hs.sync_type, hs.description,
                ap.job_id, hs.full_publication,
                ap.offload_enabled, ap.offload_server,
                hs.use_interactive_resolver, hs.hostname,
                ap.subscriber_security_mode,
                ap.subscriber_login,
                'subscriber_password' = '**********',
                ap.job_login,
                'job_password' = '**********',
                ap.publisher_security_mode,
                ap.publisher_login,
                'publisher_password' = '**********',
                ap.merge_agent_name
                from #helpsubscription hs
                left outer join #merge_agent_properties ap
                on hs.merge_jobid = ap.job_id
                order by hs.publisher, hs.publisher_db, hs.publication, hs.subscriber, hs.subscriber_db
        end
    else 
        begin
            select 'subscription_name' = hs.publisher + ':' + hs.publisher_db + ':' + hs.publication, 
                hs.publication, hs.publisher, hs.publisher_db, 
                hs.subscriber, hs.subscriber_db, hs.status, hs.subscriber_type,
                hs.subscription_type, hs.priority, hs.sync_type, hs.description,
                ap.job_id, hs.full_publication,
                ap.offload_enabled, ap.offload_server,                   
                hs.use_interactive_resolver, hs.hostname,
                ap.subscriber_security_mode,
                ap.subscriber_login,
                'subscriber_password' = '**********',
                ap.job_login,
                'job_password' = '**********',
                ap.publisher_security_mode,
                ap.publisher_login,
                'publisher_password' = '**********',
                ap.merge_agent_name
                from #helpsubscription hs
                left outer join #merge_agent_properties ap
                on hs.merge_jobid = ap.job_id
                order by hs.publisher, hs.publisher_db, hs.publication, hs.subscriber, hs.subscriber_db
        end

    drop table #merge_agent_properties
    select @retcode = 0
DONE:
    if (@cursor_open = 1)
        begin
            close #cursor
            deallocate #cursor
        end            
    drop table #helpsubscription
    return @retcode 
GO
GRANT EXECUTE ON [sys].[sp_helpmergesubscription] TO [public] AS [dbo]
GO
