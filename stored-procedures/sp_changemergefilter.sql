SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_changemergefilter]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_changemergefilter] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_changemergefilter]
	@publication [sysname],
	@article [sysname],
	@filtername [sysname],
	@property [sysname],
	@value [nvarchar](1000),
	@force_invalidate_snapshot [bit],
	@force_reinit_subscription [bit]
WITH EXECUTE AS CALLER
AS
set nocount on

    declare @pre_command        int
    declare @qual_object        nvarchar(258)
    declare @qual_join_object    nvarchar(258)
    declare @owner				nvarchar(258)
    declare @join_object_owner	nvarchar(258)
    declare @join_articlename    nvarchar(4000)
    declare @db_name            sysname
    declare @pubid                uniqueidentifier
    declare @artid                uniqueidentifier
    declare @objid                int
    declare @object                sysname
    declare @join_object        sysname
    declare @retcode            int
    declare @join_filterid        int
    declare @join_objid            int
    declare @join_nickname        int
    declare @art_nickname        int
    declare @snapshot_ready        int
    declare @filter_type        tinyint
    declare @join_unique_key    int
    declare @join_filterclause    nvarchar(1000)
    declare @automatic_reinitialization_policy bit
    declare @regenerate_triggers bit
    declare @got_merge_admin_applock bit

    select @got_merge_admin_applock = 0
    
    /*
    ** Security Check.
    ** Only the System Administrator (SA) or the Database Owner (dbo) can
    ** call this procedure
    */
    exec @retcode = sys.sp_MSreplcheck_publish
    if @@ERROR <> 0 or @retcode <> 0
        return(1)

    select @regenerate_triggers = 0
    /*
    ** Parameter Check: @join_articlename.
    ** The join_articlename cannot be NULL 
    */
    if @filtername is NULL
    begin
        raiserror (14043, 11, -1, '@filtername', 'sp_changemergefilter')
        return (1)
    end

    if @value is NULL or @value = ''
    begin
        raiserror (14043, 11, -1, '@value', 'sp_changemergefilter')
        return (1)
    end

    /*
    ** Parameter Check: @publication.
    ** The @publication id cannot be NULL and must conform to the rules
    ** for identifiers.
    */
    if @publication is NULL
    begin
        raiserror (14043, 11, -1, '@publication', 'sp_changemergefilter')
        return (1)
    end
    /*
    ** Get the pubid and make sure the publication exists
    */
    select @pubid = pubid, 
           @snapshot_ready=snapshot_ready,
           @automatic_reinitialization_policy = automatic_reinitialization_policy
       from dbo.sysmergepublications where 
       name = @publication and UPPER(publisher)=UPPER(publishingservername()) and publisher_db=db_name()
    if @pubid is NULL
    begin
        raiserror (20026, 16, -1, @publication)
        return (1)
    end

    select @db_name = db_name from dbo.sysmergesubscriptions
        where (pubid=@pubid) and (subid=@pubid)
    IF @db_name <> db_name()
    BEGIN
        RAISERROR (20047, 16, -1)
        RETURN (1)
    END

    /*
    ** Parameter Check: @article.
    ** Check to see that the @article is valid and does exist 
    */
    if @article is NULL
    begin
        raiserror (20045, 16, -1)
        return (1)
    end
        
    select    @artid = artid, @object = object_name(objid), @objid = objid, 
            @pre_command = pre_creation_command, @art_nickname = nickname
    from dbo.sysmergearticles 
    where name = @article and pubid = @pubid  
    if @artid is NULL
        begin
            raiserror (20046, 16, -1)
            return (1)
        end
    
    select @join_filterid=join_filterid, @join_articlename=join_articlename, @join_nickname = join_nickname,
            @join_unique_key = join_unique_key, @join_filterclause = join_filterclause
    from dbo.sysmergesubsetfilters
    where pubid=@pubid and artid=@artid and filtername=@filtername
    if @join_filterid is null
        begin
            raiserror (21362, 16, -1, @filtername) 
            return (1)
        end
        
    select @join_object = object_name(objid), @join_objid = objid from dbo.sysmergearticles 
        where nickname = @join_nickname and pubid=@pubid

    IF @property IS NULL
    BEGIN
        CREATE TABLE #temp (properties sysname collate database_default)
        INSERT INTO #temp VALUES ('filtername')
        INSERT INTO #temp VALUES ('join_filterclause')
        INSERT INTO #temp VALUES ('join_articlename')
        INSERT INTO #temp VALUES ('join_unique_key')
        INSERT INTO #temp VALUES ('filter_type')
        select * FROM #tab1
        RETURN (0)
    END 


    if @value is null
    begin
        RAISERROR (14043, 16, -1, @property, 'sp_changemergefilter')
        return (1)
    end

    begin TRAN
    save TRAN change_filter

    exec @retcode = sys.sp_MSgetmergeadminapplock @timeout = 0, -- no wait
                                                  @lockowner = N'Transaction'
    if @retcode<>0 or @@error<>0
    begin
        raiserror(20713, 16, -1, 'sp_changemergefilter', @publication)
        goto FAILURE            
    end

    select @got_merge_admin_applock = 1

    if LOWER(@property collate SQL_Latin1_General_CP1_CS_AS) in 
            ('join_filterclause','join_articlename','join_unique_key', 'filter_type')
        and @snapshot_ready>0
    begin
            -- 1 means'drop': which is the only option that support reintialization
            if @pre_command<>1                
                begin
                    raiserror(21419, 16, -1, @filtername, @article)
                    goto FAILURE            
                end
            /*
            ** make sure we know we really want to do this.
            */
            if @force_invalidate_snapshot = 0 and @snapshot_ready = 1
                begin
                    raiserror(20607, 16, -1)
                    goto FAILURE
                end
            if @force_reinit_subscription = 0
                begin
                    raiserror(20608, 16, -1)
                    goto FAILURE
                end

            select @regenerate_triggers = 1
            
            update dbo.sysmergepublications 
                set snapshot_ready=2,
                use_partition_groups = case when use_partition_groups = 1 then 2 else use_partition_groups end
            where pubid=@pubid
            if @@ERROR<>0 goto FAILURE

            exec @retcode = sys.sp_MSreinitmergepublication 
                                    @publication = @publication,
                                    @upload_first = @automatic_reinitialization_policy
            if @retcode<>0 or @@ERROR<>0 goto FAILURE

    end
    
    IF LOWER(@property collate SQL_Latin1_General_CP1_CS_AS)='join_filterclause'
    BEGIN
        
        -- check if the join_filterclause contains any column of type that is not supported in
        --  a join filter.

        if exists    (
                        select * from sys.columns 
                        where object_id = @objid and 
                        (
                            --(sys.fn_IsTypeBlob(sc.system_type_id,sc.max_length) = 1) -- Blob type text,ntext,xml
                              (system_type_id in (type_id('image'), type_id('text'), type_id('ntext'), type_id('xml')))
                              or max_length = -1
                              or system_type_id = 240    -- CLR-UDTs
                        )
                        and sys.fn_MSisfilteredcolumn(@value, name, @objid) = 1 
                    )
        begin
                raiserror(22518, 16, -1, @object)
                goto FAILURE
        end

        update dbo.sysmergesubsetfilters set join_filterclause=@value
                where join_filterid=@join_filterid
        execute @retcode = sys.sp_MSsubsetpublication @publication
        if @@ERROR <> 0 or @retcode<>0
            goto FAILURE
    END

    IF LOWER(@property collate SQL_Latin1_General_CP1_CS_AS)='join_unique_key'
    BEGIN
        IF LOWER(@value collate SQL_Latin1_General_CP1_CS_AS) NOT IN ('true','false')
        BEGIN
             RAISERROR(14137,16,-1)
             goto FAILURE
        END
        if LOWER(@value collate SQL_Latin1_General_CP1_CS_AS) = 'true'
            update dbo.sysmergesubsetfilters set join_unique_key=1 where join_filterid=@join_filterid
        else
            update dbo.sysmergesubsetfilters set join_unique_key=0 where join_filterid=@join_filterid
        if @@ERROR <> 0 or @retcode<>0
            goto FAILURE
    END

    IF LOWER(@property collate SQL_Latin1_General_CP1_CS_AS)='filtername'
    BEGIN
        update dbo.sysmergesubsetfilters set filtername=@value
            where join_filterid=@join_filterid
        if @@ERROR<>0
            goto FAILURE
    END

    IF LOWER(@property collate SQL_Latin1_General_CP1_CS_AS)='join_articlename'
    BEGIN

        -- consistency check join_articlename should not be the same as @article
        if @article = @value
        begin
            raiserror(21599, 16, -1)
            goto FAILURE
        end

        select @join_objid = objid from dbo.sysmergearticles where name = @value and pubid = @pubid
        
        IF @join_objid is NULL
        BEGIN
            raiserror (14027, 11, -1, @value)
            goto FAILURE
        END

        select @join_nickname = nickname from dbo.sysmergearticles 
        where pubid = @pubid AND objid = @join_objid 
        if @join_nickname is NULL
        begin
            raiserror (20001, 11, -1, @article, @publication)
            goto FAILURE
        end
        
        update dbo.sysmergesubsetfilters set join_articlename=@value, join_nickname=@join_nickname
            where join_filterid=@join_filterid
        if @@ERROR<>0
            goto FAILURE
    END
        
    IF LOWER(@property collate SQL_Latin1_General_CP1_CS_AS)='filter_type'
    BEGIN
        if LOWER(@value collate SQL_Latin1_General_CP1_CS_AS) = '1'
            select @filter_type = 1
        else if LOWER(@value collate SQL_Latin1_General_CP1_CS_AS) = '2'
            select @filter_type = 2
        else if LOWER(@value collate SQL_Latin1_General_CP1_CS_AS) = '3'
            select @filter_type = 3 -- (1 | 2)=3
        else
        begin
            raiserror (21575, 16, -1)
            goto FAILURE
        end
                    
        update dbo.sysmergesubsetfilters set filter_type = @filter_type
            where join_filterid=@join_filterid
        if @@ERROR<>0
            goto FAILURE
    END
    
    -- Do a final validation. This needs to be done irrespective of which property is being set.    
    select @join_filterid=join_filterid, @join_articlename=join_articlename, @join_nickname = join_nickname,
            @join_unique_key = join_unique_key, @join_filterclause = join_filterclause, @filter_type = filter_type
    from dbo.sysmergesubsetfilters
    where pubid=@pubid and artid=@artid and filtername=@filtername
            
    select @join_object = object_name(objid), @join_objid = objid from dbo.sysmergearticles 
        where nickname = @join_nickname and pubid=@pubid
        
    if LOWER(@property collate SQL_Latin1_General_CP1_CS_AS) in 
            ('join_filterclause','join_articlename')
    begin
        select @qual_object=QUOTENAME(@object)
        select @qual_join_object=QUOTENAME(@join_object)
        
        select @owner = quotename(SCHEMA_NAME(schema_id)) from sys.objects where object_id = @objid
		select @join_object_owner = quotename(SCHEMA_NAME(schema_id)) from sys.objects where object_id = @join_objid
    
        exec ('declare @test int select @test=1 from ' + @owner + '.' + @qual_object + ' ' + @qual_object 
						+ ', ' + @join_object_owner + '.' + @qual_join_object + ' ' + @qual_join_object + ' where ' + @join_filterclause)
        if @@ERROR<>0
        begin
            raiserror(21256, 16, -1, @join_filterclause, @object)
            goto FAILURE
        end
    end
        
    if (@filter_type & 2) = 2
    begin
        declare @pubname_lessthan90compat sysname
        declare @owner_qualified_art_name nvarchar(517)
        declare @owner_qualified_join_name nvarchar(517)

        select @pubname_lessthan90compat = NULL
        
        -- Only supported with publications that have 90 compatibility level.
        select top 1 @pubname_lessthan90compat = name from dbo.sysmergepublications 
        where backward_comp_level < 90
        and pubid in 
            (select pubid from dbo.sysmergearticles where nickname = @art_nickname)
            
        if @pubname_lessthan90compat is not null
        begin
            raiserror(21574, 16, -1, @article, @pubname_lessthan90compat)
            goto FAILURE
        end
                
        select @pubname_lessthan90compat = NULL
        
        -- Only supported with publications that have 90 compatibility level.
        select top 1 @pubname_lessthan90compat = name from dbo.sysmergepublications 
        where backward_comp_level < 90
        and pubid in 
            (select pubid from dbo.sysmergearticles where nickname = @join_nickname)
            
        if @pubname_lessthan90compat is not null
        begin
            raiserror(21574, 16, -1, @join_articlename, @pubname_lessthan90compat)
            goto FAILURE
        end

        if @join_unique_key = 0
        begin
            -- logical record relation only supported with join_unique_key=1
            raiserror(21539, 16, -1)
            goto FAILURE
        end 
        
        -- Cannot use Logical records and BusinessLogicResolvers at the same time.
        if exists (select * from dbo.sysmergearticles where ((nickname = @art_nickname) or 
                                                            (nickname = @join_nickname)) and 
                                                            (resolver_clsid = '00000000-0000-0000-0000-000000000000'))
        begin
            raiserror(20708, 16, -1)
            goto FAILURE
        end

        if exists (select * from dbo.sysmergepublications where pubid = @pubid and allow_web_synchronization = 1)
        begin
            raiserror(22545, 16, -1, @publication)
            goto FAILURE
        end
        
        if exists (select * from dbo.sysmergepublications where pubid = @pubid and sync_mode = 1)
        begin
            raiserror(22541, 16, -1, @publication)
            goto FAILURE
        end
                
        if exists (select * from dbo.sysmergesubsetfilters 
                                                where art_nickname = @art_nickname
                                                and join_nickname <> @join_nickname
                                                and (filter_type & 2) = 2)
        begin
            -- there cannot be two parents of a child in a logical record relationship
            raiserror (21538, 16, -1, @object, @join_object)
            goto FAILURE
        end
        
        if @filter_type & 1 = 1 and exists (select * from dbo.sysmergepublications 
                                            where pubid = @pubid and use_partition_groups <= 0)
        begin
            raiserror(21571, 16, -1, @publication)
            goto FAILURE
        end

        -- We do not allow logical records to be used if the articles involved in a join filter
        -- have cascading constraints defined on them
        -- yiche
        if exists (select * from sys.foreign_keys fks
        where fks.parent_object_id in (@join_objid, @objid) and
        	(ObjectProperty(fks.object_id, 'CnstIsDeleteCascade') = 1  -- on delete cascade
        	or ObjectProperty(fks.object_id, 'CnstIsUpdateCascade') = 1 -- on update cascade
           	or fks.delete_referential_action = 2 -- on delete set null
		or fks.delete_referential_action = 3 -- on delete set default
		or fks.update_referential_action = 2  -- on update set null
		or fks.update_referential_action = 3 -- on update set default
        	))
        begin
            select @owner_qualified_art_name = quotename(SCHEMA_NAME(schema_id)) + '.' + quotename(name)
            from sys.objects
            where object_id = @objid
            
            select @owner_qualified_join_name = quotename(SCHEMA_NAME(schema_id)) + '.' + quotename(name)
            from sys.objects
            where object_id = @join_objid
            
            raiserror(25019, 16, -1, @owner_qualified_art_name, @owner_qualified_join_name)
            goto FAILURE
        end        
                
        -- Enforce DRI relation
        exec @retcode = sys.sp_MScheck_joinfilter_using_dri @publication,
                                                            @article,
                                                            @objid,
                                                            @join_objid,
                                                            1,
                                                            @join_filterclause
        if @@error <> 0 or @retcode <> 0
            goto FAILURE
            
        -- based on usability feeback, we should set the allow_subscriber_initiated_snapshot
        -- option to 1 rather than raise an error.
        update dbo.sysmergepublications set allow_subscriber_initiated_snapshot = 1
            where pubid = @pubid
    end
    
    exec @retcode = sys.sp_MSvalidate_wellpartitioned_articles @publication
    if @@error <> 0 or @retcode <> 0
        goto FAILURE
        
    if (@regenerate_triggers = 1)
    begin
        exec @retcode = sys.sp_MSpublicationview @publication = @publication, @force_flag = 1
        if @@ERROR<>0 or @retcode <>0
            goto FAILURE

        exec @retcode = sp_MSregenerate_mergetriggers @publication = @publication
        if @@ERROR<>0 or @retcode<>0
            goto FAILURE
    end
        
    exec sys.sp_MSreleasemergeadminapplock @lockowner = N'Transaction'
    Commit TRAN
    return(0)

FAILURE:
    if @@TRANCOUNT > 0
    begin
        if @got_merge_admin_applock=1
            exec sys.sp_MSreleasemergeadminapplock @lockowner = N'Transaction'
        ROLLBACK TRANSACTION change_filter
        COMMIT TRANSACTION
    end
    RAISERROR (20038, 16, -1, @article, @publication)
    return(1)
 
GO
GRANT EXECUTE ON [sys].[sp_changemergefilter] TO [public] AS [dbo]
GO
