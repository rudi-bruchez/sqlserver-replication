SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_helpmergepullsubscription]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_helpmergepullsubscription] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_helpmergepullsubscription]
	@publication [sysname],
	@publisher [sysname],
	@publisher_db [sysname],
	@subscription_type [nvarchar](10)
WITH EXECUTE AS CALLER
AS
SET NOCOUNT ON

    /*
    ** Declarations.
    */

    declare @retcode                         int
    declare @srvid                             int
    declare    @pubid                             uniqueidentifier
    declare    @subid                             uniqueidentifier
    declare @cursor_open                    int
    declare @subscriber                        sysname
    declare @subscriber_db                    sysname
    declare @publisher_local                sysname
    declare @publisher_db_local                sysname
    declare @publication_local                sysname
    declare @helpsubscriptioncursor_open    int
    declare @subtype1 smallint
    declare @subtype2 smallint
    declare @subtype3 smallint
    declare @fpullsubexists bit

    set @cursor_open = 0                    
    select @publisher_db = RTRIM(@publisher_db)
    select @publication = RTRIM(@publication)
	select @fpullsubexists = 0
	
    -- For attach
    if exists (select * from sys.objects where name = 'MSrepl_restore_stage')
        -- The database is attached from a subscription copy file without using
        -- sp_attachsubscription. Return nothing
        return 0

    /*
    **    Calling sp_help* is all right whether current database is enabled for pub/sub or not
    */

    if object_id('sysmergesubscriptions', 'U') is null
    begin
        return 0
    end
        
    /* Security check */
    EXEC @retcode = dbo.sp_MSreplcheck_subscribe
    if @@ERROR <> 0 or @retcode <> 0
        return(1)
        
    set @subscriber = @@SERVERNAME     
    set @subscriber_db = DB_NAME()
 
    /*
    ** Parameter Check: @publisher
    ** Check to make sure that the publisher is defined
    */
    IF @publisher <> '%' AND @publisher IS NOT NULL
    BEGIN
        EXECUTE @retcode = sys.sp_validname @publisher

        IF @@ERROR <> 0 OR @retcode <> 0
               RETURN (1)
    END
 
    /*
    ** Parameter Check:  @publication.
    ** If the publication name is specified, check to make sure that it
    ** conforms to the rules for identifiers and that the publication
    ** actually exists.  Disallow NULL.
    */
    if @publication IS NULL
    BEGIN
        RAISERROR (14043, 16, -1, '@publication', 'sp_helpmergepullsubscription')
        RETURN (1)
    END

    /*
    ** Parameter Check: @subscription_type.
    ** Set subscription_typeid based on the @subscription_type specified.
    **
    **   subscription_type    subscription_type
    **   =================    ===============
    **             0             push
    **           1,2,3             pull
    **              0,1            both
    */
    if LOWER(@subscription_type collate SQL_Latin1_General_CP1_CS_AS) NOT IN ('push', 'pull', 'both')
    BEGIN
          RAISERROR (14128, 16, -1)
        RETURN (1)
    END

    IF LOWER(@subscription_type collate SQL_Latin1_General_CP1_CS_AS) = 'both'
    begin
        set @subtype1 = 0
        set @subtype2 = 1
        set @subtype3 = 1
    end
    else IF LOWER(@subscription_type collate SQL_Latin1_General_CP1_CS_AS) = 'push'
    begin
        set @subtype1 = 0
        set @subtype2 = 0
        set @subtype3 = 0
    end
    else
    begin
        -- including pull subscription and pull/anonymous/lightweight subscription
        set @subtype1 = 1
        set @subtype2 = 2
        set @subtype3 = 3
    end
    
    IF object_id('MSsubscription_properties', 'U') is NULL
        RETURN (0)

    /*
    ** Get subscriptions
    */
    
    create table #helpmergepullsubscription
        (
            publication                sysname        collate database_default not null,
            publisher                sysname        collate database_default not null,
            publisher_db            sysname        collate database_default not null,
            subscriber                sysname        collate database_default not null,
            subscriber_db             sysname        collate database_default not null,
            status                    int         NOT NULL,
            subscriber_type         int            NOT NULL,
            subscription_type         int            NOT NULL,
            priority                float(8)    NOT NULL,
            sync_type                tinyint        NOT NULL,
            description                nvarchar(255)     collate database_default null,
            merge_jobid                binary(16)        NULL,
            last_updated            nvarchar(26)     collate database_default null,
            use_interactive_resolver     int            NULL,
            subid                    uniqueidentifier    not NULL,
            last_sync_status        int                NULL,
            last_sync_summary        sysname            collate database_default null
        )

    if object_id('sysmergesubscriptions', 'U') is not null
    begin
        IF @publisher IS NULL and @publisher_db IS NULL
        BEGIN
            -- show the loopback subscription            
            insert into #helpmergepullsubscription 
                select pubs.name, pubs.publisher, pubs.publisher_db, subs.subscriber_server, subs.db_name, 
                    subs.status, subs.subscriber_type, subs.subscription_type, subs.priority, 
                    subs.sync_type, subs.description, replinfo.merge_jobid, 
                    sys.fn_replformatdatetime(subs.last_sync_date), 
                    replinfo.use_interactive_resolver, subs.subid, subs.last_sync_status, subs.last_sync_summary
                FROM      sysmergesubscriptions     subs,
                          MSmerge_replinfo         replinfo,
                        sysmergepublications     pubs
                where subs.subid = subs.pubid
                    and pubs.pubid = subs.pubid
                    and replinfo.repid = subs.subid             
        END
        else
        begin
            declare #cursor cursor local FAST_FORWARD FOR select DISTINCT sub.subid, sub.pubid 
                FROM dbo.sysmergesubscriptions     sub,
                dbo.sysmergepublications         pub 
                 WHERE ((@subscriber = N'%') OR (UPPER(sub.subscriber_server) = UPPER(@subscriber) collate database_default)) 
                    AND ((@publisher = N'%') OR (UPPER(pub.publisher) = UPPER(@publisher) collate database_default)) 
                       AND pub.name LIKE  @publication  
                       AND sub.pubid = pub.pubid 
                    AND ((@subscriber_db = N'%') OR (sub.db_name = @subscriber_db collate database_default))
                    AND ((@publisher_db = N'%') OR (pub.publisher_db = @publisher_db collate database_default))
                    AND sub.subscription_type in (@subtype1, @subtype2, @subtype3) 
                FOR READ ONLY

            open #cursor
            select @cursor_open = 1                    
            fetch next from #cursor into @subid, @pubid
            while (@@fetch_status <> -1)
            begin
                insert into #helpmergepullsubscription 
                    select pubs.name, pubs.publisher, pubs.publisher_db, subs.subscriber_server, subs.db_name, 
                        subs.status, subs.subscriber_type, subs.subscription_type, subs.priority, 
                        subs.sync_type, subs.description, replinfo.merge_jobid, 
                        sys.fn_replformatdatetime(subs.last_sync_date), 
                        replinfo.use_interactive_resolver, @subid, subs.last_sync_status, subs.last_sync_summary
                    FROM      sysmergesubscriptions     subs,
                              MSmerge_replinfo         replinfo,
                            sysmergepublications     pubs
                    where subs.subid = @subid
                        and pubs.pubid = @pubid
                        and subs.pubid = @pubid
                        and @subid <> @pubid -- do not show the loopback subscription
                        and replinfo.repid = subs.subid 

                if @@ERROR <> 0
                begin
                    set @retcode = 1
                    goto DONE
                end                    
                fetch next from #cursor into @subid, @pubid
            end
        end
    end

	IF EXISTS(SELECT *
				FROM sysmergesubscriptions
				WHERE subscription_type != 0)
	BEGIN
		SELECT @fpullsubexists = 1
	END
	
    select 'subscription_name'= hs.publisher + ':' + hs.publisher_db + ':' + hs.publication collate database_default, hs.publication, hs.publisher,
            hs.publisher_db, hs.subscriber, hs.subscriber_db, hs.status, hs.subscriber_type, hs.subscription_type,
            hs.priority, hs.sync_type, hs.description, hs.merge_jobid, cast(isnull(sp.enabled_for_syncmgr,0) as int) as enabled_for_syncmgr, hs.last_updated, sp.publisher_login,
            sys.fn_repldecryptver4(sp.publisher_password), sp.publisher_security_mode, sp.distributor, sp.distributor_login, 
            sys.fn_repldecryptver4(sp.distributor_password), sp.distributor_security_mode, 'ftp_address' = null, 'ftp_port' = 0, 
            'ftp_login' = null, 'ftp_password' = null, sp.alt_snapshot_folder, sp.working_directory, sp.use_ftp, 
            sp.offload_agent, sp.offload_server, hs.use_interactive_resolver, hs.subid, 
            sp.dynamic_snapshot_location, hs.last_sync_status, hs.last_sync_summary, sp.use_web_sync,
            sp.internet_url, sp.internet_login, sys.fn_repldecryptver4(sp.internet_password), sp.internet_security_mode,
            sp.internet_timeout, sp.hostname,
            'job_login' =  sc.credential_identity,
            'job_password' = '**********'
            from #helpmergepullsubscription hs
             left outer join MSsubscription_properties sp
                  on hs.publisher = sp.publisher collate database_default
                 and hs.publisher_db = sp.publisher_db collate database_default
                 and hs.publication = sp.publication collate database_default
            left outer join msdb..sysjobsteps sj
                on sp.job_step_uid = sj.step_uid
            left outer join msdb..sysproxies p
                on sj.proxy_id = p.proxy_id
            left join sys.credentials sc
				on p.credential_id = sc.credential_id
            order by hs.publisher, hs.publisher_db, hs.publication, hs.subscriber, hs.subscriber_db
	if @@error <> 0 return 1
	
    select @retcode = 0
DONE:
    if (@cursor_open = 1)
    begin
        close #cursor
        deallocate #cursor
    end            

    return @retcode    
GO
GRANT EXECUTE ON [sys].[sp_helpmergepullsubscription] TO [public] AS [dbo]
GO
