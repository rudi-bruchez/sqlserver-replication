SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSenumallpublications]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSenumallpublications] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSenumallpublications]
	@publisherdb [sysname],
	@replication_type [tinyint],
	@agent_login [sysname],
	@security_check [bit],
	@vendor_name [sysname],
	@publication [sysname],
	@hrepl_pub [bit],
	@empty_tranpub [bit]
WITH EXECUTE AS CALLER
AS
BEGIN
    set nocount on
    declare @dbname         sysname
                ,@trans          tinyint
                ,@merge          tinyint
                ,@tranmerge     tinyint
                ,@3rdparty       tinyint
                ,@retcode        int
                ,@category      int
                ,@loc_server     sysname
                ,@publisher   sysname
                ,@distributor    sysname
                ,@distribdb      sysname
                ,@login          sysname
                ,@proc           nvarchar(255)
                ,@distbit        int
                ,@is_user_admin  bit
                ,@same_as_user   bit

    -- @security_check parameter is ignored.  Security is always checked.
    -- UI: If the distributor is not installed, return empty result
    if not exists
    (
        SELECT    *
        FROM    master.dbo.sysservers
        WHERE    srvstatus & 8 <> 0
    )
    begin
        return (0)
    end
    --
    -- Initializations
    --
    select @3rdparty = 0
            ,@trans = 1 
            ,@merge = 2
            ,@tranmerge = 3
            ,@login = suser_sname(suser_sid())
            ,@distbit = 16
            ,@is_user_admin = case when (is_srvrolemember('sysadmin') = 1) then 1 else 0 end
            ,@loc_server = CONVERT(sysname, ServerProperty('ServerName'))
    --
    -- If the agent login is not specified - use current login
    -- UI: Win95 subscriber will send in null agent_login
    --
    if @agent_login is null
    begin
        select @agent_login = @login
                ,@same_as_user = 1
    end
    else
    begin
        select @same_as_user = case when (suser_sid(@agent_login, 0) = suser_sid()) then 1 else 0 end
    end
    if (@publisherdb =  N'%')
    begin
        -- Temp table to enumerate the publisher dbs
        create table #pubdbs
        (
            publisher_db        sysname not null,
            category int
        )
    end
    -- Temp table to enumerate the publications
    create table #MSenumpublications 
    (
        publisher_db            sysname collate database_default not null,
        publication             sysname collate database_default not null,
        replication_type        tinyint NOT NULL, 
        immediate_sync          bit NOT NULL,
        allow_pull              bit NOT NULL,
        allow_anonymous         bit NOT NULL, 
        enabled_for_internet    bit NOT NULL,
        repl_freq               tinyint NOT NULL,
        immediate_sync_ready    bit NOT NULL, 
        allow_sync_tran         bit NOT NULL,
        independent_agent       bit NOT NULL,
        is_db_owner             int NOT NULL, 
        thirdparty_flag         bit NOT NULL,
        vendor_name             sysname collate database_default null,
        publisher               sysname collate database_default null, 
        publisher_type          sysname collate database_default null,
        description             nvarchar(255) collate database_default null,
        distribution_db         sysname collate database_default null, 
        allow_queued_tran       bit not null,
        allow_dts               bit not null,
        thirdparty_options      int null,
        queue_type              int null,
        dynamic_filters         bit not null default 0
    )

    if (@is_user_admin = 0) or (@same_as_user = 0)
    begin
        -- Temp table to enumerate the distribution dbs
        create table #distdbs
        (
            publisher    sysname collate database_default not null,
            distributor  sysname collate database_default not null,
            distribdb    sysname collate database_default not null
        )
        
        if (@is_user_admin = 0)
        begin
            -- Temp table to list publications that current login has access to
            DECLARE @curuser_publications TABLE
            (
                publisher_db 	sysname collate database_default not null, 
                publication     sysname collate database_default not null
            )
        end
        
        if (@same_as_user = 0)
        begin
            -- Temp table to list publications that agent login has access to
            DECLARE @agent_publications TABLE
            (
                publisher_db 	sysname collate database_default not null,
                publication     sysname collate database_default not null
            )
        end
    end
    --
    -- Return everything if @replication_type is not in (@3rdparty, @trans, @merge)
    --
    if @replication_type not in (@3rdparty, @trans, @merge, @tranmerge)
    begin
        select @replication_type = null
    end
    --
    -- Get published databases
    --
    if (@publisherdb =  N'%')
    begin
        insert into #pubdbs
        select name, category
        from master.dbo.sysdatabases
        where has_dbaccess(name) = 1
            and 
            (
                -- process based on replication type
                (@replication_type = @tranmerge and (category & 1 = 1 or category & 4 = 4 or (@hrepl_pub = 1 and category & @distbit = @distbit))) 
                OR
                (@replication_type = @trans and (category & 1 = 1 or (@hrepl_pub = 1 and category & @distbit = @distbit)))
                OR
                (@replication_type = @merge and category & 4 = 4)
                OR
                (@replication_type = @3rdparty and category & @distbit = @distbit)
                OR
                (@replication_type is null and (category & 1 = 1 or category & 4 = 4 or category & @distbit = @distbit)) 
            )
    end
    else
    begin
        select @dbname = name
                ,@category = category
        from master.dbo.sysdatabases
        where name = @publisherdb
            and has_dbaccess(name) = 1
            and 
            (
                -- process based on replication type
                (@replication_type = @tranmerge and (category & 1 = 1 or category & 4 = 4 or (@hrepl_pub = 1 and category & @distbit = @distbit))) 
                OR
                (@replication_type = @trans and (category & 1 = 1 or (@hrepl_pub = 1 and category & @distbit = @distbit)))
                OR
                (@replication_type = @merge and category & 4 = 4)
                OR
                (@replication_type = @3rdparty and category & @distbit = @distbit)
                OR
                (@replication_type is null and (category & 1 = 1 or category & 4 = 4 or category & @distbit = @distbit)) 
            )
    end
    --
    -- Get the publication information now
    --
    if (@publisherdb =  N'%')
    begin
        --
        -- wild card - all publications
        --
        declare #curPubDb CURSOR LOCAL FAST_FORWARD FOR
            select publisher_db, category
            from #pubdbs
        FOR READ ONLY
        
        open #curPubDb
        fetch #curPubDb into @dbname, @category
        while (@@fetch_status >= 0) 
        begin
            -- enumerate the publications based on replication type and category
            if (@replication_type is null or @replication_type in (@tranmerge,@trans))
                and (@category & 1 = 1 or (@hrepl_pub = 1 and @category & @distbit = @distbit))
            begin
                select @proc = quotename(@dbname) + N'.sys.sp_MSenumtranpublications'
                exec @retcode = @proc @publication, @category, @empty_tranpub
                if @@ERROR <> 0 or @retcode <> 0
                    return (1)
            end
            
            if (@replication_type is null or @replication_type in (@tranmerge,@merge))
                and (@category & 4 = 4)
            begin
                select @proc = quotename(@dbname) + N'.sys.sp_MSenummergepublications'
                exec @retcode = @proc @publication, @category
                if @@ERROR <> 0 or @retcode <> 0
                    return (1)
            end
            
            if (@replication_type is null or @replication_type = @3rdparty)
                and (@category & @distbit = @distbit)
            begin
                select @proc = quotename(@dbname) + N'.sys.sp_MSenum3rdpartypublications'
                exec @retcode = @proc @vendor_name, @publication
                if @@ERROR <> 0 or @retcode <> 0
                    return (1)
            end
            
            -- get next publisher db
            fetch #curPubDb into @dbname, @category
        end
        CLOSE #curPubDb
        DEALLOCATE #curPubDb
    end
    else
    begin
        -- specific publication
        -- enumerate the publications based on replication type and category
        --
        if (@replication_type is null or @replication_type in (@tranmerge,@trans))
            and (@category & 1 = 1 or (@hrepl_pub = 1 and @category & @distbit = @distbit))
        begin
            select @proc = quotename(@dbname) + N'.sys.sp_MSenumtranpublications'
            exec @retcode = @proc @publication, @category, @empty_tranpub
            if @@ERROR <> 0 or @retcode <> 0
                return (1)
        end
        
        if (@replication_type is null or @replication_type in (@tranmerge,@merge))
            and (@category & 4 = 4)
        begin
            select @proc = quotename(@dbname) + N'.sys.sp_MSenummergepublications'
            exec @retcode = @proc @publication, @category
            if @@ERROR <> 0 or @retcode <> 0
                return (1)
        end
        
        if (@replication_type is null or @replication_type = @3rdparty) 
            and (@category & @distbit = @distbit)
        begin
            select @proc = quotename(@dbname) + N'.sys.sp_MSenum3rdpartypublications'
            exec @retcode = @proc @vendor_name, @publication
            if @@ERROR <> 0 or @retcode <> 0
                return (1)
        end
    end
    --
    -- Get distributor info for local SQL server publisher (if any)
    --
    EXEC @retcode = sys.sp_MSrepl_getdistributorinfo @rpcsrvname = @distributor OUTPUT,
                                                        @distribdb = @distribdb OUTPUT
    IF @@error <> 0 OR @retcode <> 0
        RETURN (1)
    --
    -- Verify that a distributor db exists (only if not returning HREPL as well)
    --
    IF @hrepl_pub = 0 AND @distribdb IS NULL
    BEGIN
        RAISERROR (14071, 16, -1)
        RETURN (1)
    END

    IF @distribdb IS NOT NULL AND @distributor IS NOT NULL
    BEGIN
        if (@is_user_admin = 0) or (@same_as_user = 0)
        begin
            INSERT INTO #distdbs VALUES (@loc_server, @distributor, @distribdb)
        end
        
        -- Set local publisher distrib db
        UPDATE    #MSenumpublications
        SET 	distribution_db   = @distribdb
        WHERE    publisher        = @loc_server collate database_default 
    END
    --
    -- Include local heterogeneous publications
    --
    IF @hrepl_pub = 1 AND @distributor = CONVERT(sysname, ServerProperty('ServerName'))
    BEGIN
        if (@is_user_admin = 0) or (@same_as_user = 0)
        begin
            -- Get local publisher/distribution db pairs with HREPL pubs
            INSERT INTO #distdbs
            SELECT name,
                    @loc_server,
                    distribution_db
            FROM    msdb.dbo.MSdistpublishers
            WHERE    publisher_type != N'MSSQLSERVER'
              AND    sys.fn_MSrepl_istranpublished(distribution_db, 1) = 1
        end
    END
    --
    -- we will skip PAL check if sysadmin and agent login is not different
    --
    if (@is_user_admin = 0) or (@same_as_user = 0)
    begin
        -- Check publication access for each distributor db
        declare #curDistDb CURSOR LOCAL FAST_FORWARD FOR
            select publisher, distributor, distribdb
            from #distdbs
        FOR READ ONLY
        
        open #curDistDb
        fetch #curDistDb into @publisher, @distributor, @distribdb
        while (@@fetch_status >= 0) 
        BEGIN
            -- sp_MSpublication_access returns those publications that the passed login has access to.
            -- If the value passed in for @agent_login is not the same as the current user, a separate
            -- table is populated with those publications that the agent has access to.  This table is
            -- used to set the agent_access field returned.
            --
            -- Information is returned on those publications that the current user has access to.
            --
            SELECT @proc = case when (@distributor IS NOT NULL) THEN quotename(@distributor) + N'.' else N' ' end 
                                    + quotename(@distribdb) + N'.sys.sp_MSpublication_access'
            --
            -- Get accessible publication list if user is not sysadmin
            --
            if (@is_user_admin = 0)
            begin
                insert into @curuser_publications
                EXEC @retcode = @proc
                                @publisher = @publisher,
                                @operation = N'get_publications',
                                @login = @login
            end
            --
            -- If agent login is different
            -- Get accessible publication list for agent login
            --
            if (@same_as_user = 0)
            begin
                insert into @agent_publications
                EXEC @retcode = @proc
                                @publisher = @publisher,
                                @operation = N'get_publications',
                                @login = @agent_login
            end
            --
            -- commit open tran in case 
            -- insert into exec failed.
            --
            while(@@trancount <> 0)
                commit tran
            
            -- Get next dist db
            fetch #curDistDb into @publisher, @distributor, @distribdb
        END
        CLOSE #curDistDb
        DEALLOCATE #curDistDb
    end --if (@is_user_admin = 0 or @same_as_user = 0)
    --
    -- Return resultset
    --
    select pub.publisher_db,
            pub.publication,
            pub.replication_type, 
            pub.immediate_sync,
            pub.allow_pull,
            pub.allow_anonymous, 
            pub.enabled_for_internet,
            pub.repl_freq,
            pub.immediate_sync_ready, 
            pub.allow_sync_tran,
            pub.independent_agent,
            case
                when (@same_as_user = 1 or exists (select *
                                from @agent_publications as agent
                                where agent.publisher_db = pub.publisher_db
                                  and agent.publication = pub.publication)
                ) then convert(bit,1)
                else convert(bit,0)
            end as [agent_access],
            pub.thirdparty_flag,
            pub.vendor_name,
            pub.publisher,
            pub.description,
            pub.distribution_db, 
            allow_queued_tran,
            allow_dts,
            pub.thirdparty_options,
            pub.queue_type,
            pub.dynamic_filters,
            pub.publisher_type
     from #MSenumpublications as pub
     -- Choose publications if sysadmin or pub dbowner or
     -- acessible by PAL
     where @is_user_admin = 1 
        or pub.is_db_owner = 1
        or exists (select *
                     from @curuser_publications as access
                     where pub.publisher_db = access.publisher_db
                       and pub.publication = access.publication)
     order by pub.publication, pub.publisher_db
    --
    -- all done
    --
    return (0)
END
GO
GRANT EXECUTE ON [sys].[sp_MSenumallpublications] TO [public] AS [dbo]
GO
