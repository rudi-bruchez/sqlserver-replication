SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_helpmergearticle]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_helpmergearticle] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_helpmergearticle]
	@publication [sysname],
	@article [sysname]
WITH EXECUTE AS CALLER
AS
SET NOCOUNT ON

    /*
    ** Declarations.
    */
    declare @retcode            int
    declare @max_nickname        int
    /*
    ** Create a temporary table to hold all information.
    */
    declare @helpmergearticle TABLE
        (
            id                      int                identity NOT NULL,
            name                    sysname            collate database_default not null,
            source_owner            sysname            collate database_default not null,
            source_object           sysname            collate database_default not null,        /* converted from objid */
            sync_object_owner       sysname            collate database_default null,
            sync_object             sysname            collate database_default null,        /* converted from sync_objid */
            description             nvarchar(255)      collate database_default null,
            status                    tinyint            NULL,
            creation_script            nvarchar(255)    collate database_default null,
            conflict_table            nvarchar(270)    collate database_default null,
            article_resolver        nvarchar(255)    collate database_default null,
            subset_filterclause        nvarchar(1000)    collate database_default null,
            pre_creation_command    tinyint            NULL, 
            schema_option            binary(8)        NULL,
            type                    smallint        NULL,
            column_tracking            int                NULL,
            resolver_info            nvarchar(517)    collate database_default null,
            vertical_partition        bit                NULL,
            destination_owner        sysname            collate database_default null,
            identity_support        int                NULL,
            pub_identity_range        bigint            NULL,
            identity_range            bigint            NULL,
            threshold                int                NULL,
            verify_resolver_signature int            NULL default 1,
            destination_object        sysname            collate database_default not null,
            allow_interactive_resolver    int            NULL,
            fast_multicol_updateproc    int            NULL,
            check_permissions        int                NULL,
            processing_order        int                NOT NULL default 0,
            upload_options            tinyint            NOT NULL default 0,
            identityrangemangementoption    int     not NULL default 0,
            delete_tracking        bit                default 1,
            compensate_for_errors    bit                not null default 0,
            partition_options        tinyint not null default 0,
            artid                    uniqueidentifier    NULL,
            pubid                    uniqueidentifier    NULL,
            stream_blob_columns        bit                NOT NULL default 0
        )   

        
    /*
    ** Running sp_help is OK from everywhere, whether enabled for publishing or not
    */
    IF object_id('sysmergesubscriptions') is NULL
        RETURN (0)

    /*
    ** Parameter Check:  @publication.
    ** Check to make sure that the publication exists, that it conforms
    ** to the rules for identifiers, and that it isn't NULL.
    */

    if @publication IS NULL
    BEGIN
        RAISERROR (14043, 16, -1, '@publication', 'sp_helpmergearticle')
        RETURN (1)
    END

    if @publication <> '%'
    BEGIN
        if (is_member('db_owner') = 1 or is_member('replmonitor') = 1)
        begin
            if NOT EXISTS (select pubid FROM dbo.sysmergepublications
                            WHERE name = @publication and UPPER(publisher)=UPPER(publishingservername()) and publisher_db=db_name())
            BEGIN
                RAISERROR (20026, 16, -1, @publication)
                RETURN (1)
            END
        end
        else
        begin
            if NOT EXISTS (select pubid FROM dbo.sysmergepublications
                            WHERE name = @publication and UPPER(publisher)=UPPER(publishingservername()) 
                                and publisher_db=db_name() and ({fn ISPALUSER(pubid)} = 1))
            BEGIN
                select * from @helpmergearticle
                RETURN (0)
            END
        end        
    END

    /*
    ** Parameter Check:     @article.
    ** Check to make sure that the article exists, that it conforms
    ** to the rules for identifiers, and that it isn't NULL.
    */

    if @article IS NULL
    BEGIN
        RAISERROR (14043, 16, -1, '@article', 'sp_helpmergearticle')
        RETURN (1)
    END

    if @article <> '%'
    BEGIN
        if NOT EXISTS (select *
                       FROM dbo.sysmergeextendedarticlesview
                       WHERE name = @article
                       AND pubid IN (select pubid 
                                     FROM dbo.sysmergepublications 
                                     WHERE name like @publication  
                                        and UPPER(publisher)=UPPER(publishingservername()) and publisher_db=db_name()))
        BEGIN
            RAISERROR (20027, 16, -1, @article)
            RETURN (1)
        END

    END

    select @max_nickname = max(nickname) from dbo.sysmergearticles
    
    INSERT INTO @helpmergearticle 
        (name, 
        source_owner,
        source_object, 
        sync_object_owner,
        sync_object, 
        description, 
        status, 
        creation_script, 
        conflict_table, 
        pre_creation_command, 
        schema_option, 
        type, 
        column_tracking, 
        article_resolver, 
        subset_filterclause,
        resolver_info,
        vertical_partition,
        destination_owner,
        identity_support,
        pub_identity_range,
        identity_range,
        threshold,
        verify_resolver_signature,
        destination_object,
        allow_interactive_resolver,
        fast_multicol_updateproc,
        check_permissions,
        processing_order,
        upload_options,
        identityrangemangementoption,
        delete_tracking,
        compensate_for_errors,
        partition_options,
        artid,
        pubid,
        stream_blob_columns)
    select  art.name,
            users1.name,
            objects.name, 
            users2.name,
            syncobjects.name, 
            art.description, 
            art.status, 
            art.creation_script, 
            art.conflict_table, 
            art.pre_creation_command,
            art.schema_option, 
            case 
                when objectproperty(art.objid, 'IsSchemaBound') = 1 and art.type <> 0x80 then 0x0100 | convert(smallint, art.type) 
                else convert(smallint, ISNULL(art.type,0x0a)) 
                end,
            art.column_tracking, 
            art.article_resolver, 
            art.subset_filterclause,
            art.resolver_info,
            art.vertical_partition,
            art.destination_owner,
            art.identity_support,
            ABS(art.pub_range),
            ABS(art.range),
            art.threshold,
            art.verify_resolver_signature,
            art.destination_object,
            art.allow_interactive_resolver,
            art.fast_multicol_updateproc,
            art.check_permissions,
            art.processing_order,
            art.upload_options,
            case when art.identity_support = 1 then 1 else 0 end,
            art.delete_tracking,
            art.compensate_for_errors,
            0,
            art.artid,
            art.pubid,
            art.stream_blob_columns
    FROM    sysmergeextendedarticlesview art 
            inner join dbo.sysmergepublications pubs on art.pubid = pubs.pubid
            inner join sys.objects objects on objects.object_id = art.objid
            left outer join sys.objects syncobjects on art.sync_objid = syncobjects.object_id 
            inner join sys.schemas users1 on objects.schema_id = users1.schema_id
            left outer join sys.schemas users2 on syncobjects.schema_id = users2.schema_id
            WHERE art.name LIKE @article
                AND pubs.name LIKE @publication
                AND UPPER(pubs.publisher) = UPPER(publishingservername())
                AND pubs.publisher_db = db_name()
                and (1 = {fn ISPALUSER(pubs.pubid)} or
                     1 = is_member('db_owner') or
                     1 = isnull(is_member('replmonitor'),0))
            order by art.processing_order, isnull(art.nickname, @max_nickname+1), art.name
        
    update hma set hma.partition_options = 3
    from @helpmergearticle hma join dbo.sysmergearticles sma
    on hma.artid = sma.artid
    and hma.pubid = sma.pubid
    and sma.lightweight = 1
    and sma.well_partitioned_lightweight = 1
    
    if exists (select * from sys.objects where name = 'sysmergepartitioninfo')
    begin
        update hma set hma.partition_options = smpi.partition_options
        from @helpmergearticle hma join dbo.sysmergepartitioninfo smpi
        on hma.artid = smpi.artid
        and hma.pubid = smpi.pubid
    end


    declare @source_owner sysname
    declare @source_object sysname
    declare @identityrangemangementoption int
    declare @objid int
    declare @artid uniqueidentifier
    declare @status int
    declare #arts CURSOR LOCAL FAST_FORWARD FOR 
        select source_owner, source_object, identityrangemangementoption, name, artid, status from @helpmergearticle
    open #arts
    fetch #arts into @source_owner, @source_object, @identityrangemangementoption, @article, @artid, @status
    while (@@fetch_status <> -1)
    begin
        select @objid = object_id(quotename(@source_owner) + '.' + quotename(@source_object))
        if @identityrangemangementoption = 0 and
            exists (select * from sys.columns where object_id = @objid and 
                    is_identity = 1 and 
                    ColumnProperty(object_id, name, 'IsIdNotForRepl') = 1)
        begin
            update @helpmergearticle 
            set identityrangemangementoption = 2
            where source_owner = @source_owner and source_object = @source_object
        end

        -- pick only active articles - articles which have been prepared
        /*
        if @identityrangemangementoption = 1 and (@status = 2 or @status = 6)
        begin
            -- do the adjust identity range only if this is not a republisher of that article
            if not exists (select * from dbo.sysmergearticles where artid = @artid and sys.fn_MSmerge_islocalpubid(pubid)=0)
            begin
                -- adjust the identity range on the publisher for the article if needed
                exec @retcode = sys.sp_adjustpublisheridentityrange @table_name=@source_object, @table_owner=@source_owner
                if @retcode<>0 or @@error<>0
                begin
                    raiserror(20676, 11, -1, @article)
                end
            end
        end*/
        fetch #arts into @source_owner, @source_object, @identityrangemangementoption, @article, @artid, @status
    end
    close #arts
    deallocate #arts

    select * from @helpmergearticle order by id
    
    RETURN (0)
GO
GRANT EXECUTE ON [sys].[sp_helpmergearticle] TO [public] AS [dbo]
GO
