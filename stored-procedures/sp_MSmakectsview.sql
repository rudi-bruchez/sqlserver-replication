SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSmakectsview]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSmakectsview] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSmakectsview]
	@publication [sysname],
	@ctsview [sysname],
	@dynamic_snapshot_views_table_name [sysname],
	@create_dynamic_views [bit],
	@max_bcp_gen [bigint]
WITH EXECUTE AS CALLER
AS
set nocount on
    declare @pubid          uniqueidentifier
    declare @artid          uniqueidentifier
    declare @pubidstr       nvarchar(40)
    declare @artidstr       nvarchar(40)
    declare @objid      int
    declare @tablenick  int
    declare @new_inactive int
    declare @new_active int
    declare @tablenickstr nvarchar(12)
    declare @command_piece nvarchar(2000)           -- used if @generate_per_article=0
    declare @command_piece_forall nvarchar(2000)    -- used if @generate_per_article=1
    declare @command_piece_forglobal nvarchar(2000) -- used if @generate_per_article=1
    declare @command_piece_rowtrack nvarchar(2000)  -- used if @generate_per_article=1
    declare @rowguidcolname nvarchar(258)
    declare @view_type  int
    declare @view_name  nvarchar(270)
    declare @or_after_first nvarchar(100)
    declare @select_command nvarchar(4000)
    declare @retcode int 
    declare @generate_per_article bit 
    declare @newidstr       nvarchar(40)
    declare @newid          uniqueidentifier
    declare @ctsview_80     sysname -- used if @generate_per_article=1
    declare @ctsview_90_forall     sysname -- used if @generate_per_article=1
    declare @ctsview_90_forglobal     sysname -- used if @generate_per_article=1
    declare @ctsview_rowtrack     sysname -- used if @generate_per_article=1
    declare @tempidstr       nvarchar(40)
    declare @drop_views bit
    declare @need_ctsview_rowtrack bit
    declare @dynsnap_views bit
    declare @upload_options tinyint
    declare @compatlevel int
    declare @is_coltracked int
    declare @colv_entries int

    -- Security Checking 
    -- sysadmin or db_owner or replication agent have access    
    exec @retcode=sys.sp_MSreplcheck_publish
    if @@error<>0 or @retcode<>0
        return 1
    
    if (@dynamic_snapshot_views_table_name is not null and @dynamic_snapshot_views_table_name <> '')
        select @dynsnap_views = 1
    else
        select @dynsnap_views = 0
    
    set @drop_views = 1

    
    /* By default the @generate_per_article is OFF */
    set @generate_per_article = 0

    set @new_inactive = 5 /* value of SQLDMOArtStat_New_Inactive */
    set @new_active = 6 /* value of SQLDMOArtStat_New_Active */

    -- if the view name is not specified we do a per article view generation and
    -- return a table containing the list of view names
    if @ctsview IS NULL
        set @generate_per_article = 1
    
    select @retcode = 0
    set @or_after_first = ''

    select @pubid = pubid, @compatlevel = backward_comp_level
        from dbo.sysmergepublications where name = @publication 
        and UPPER(publisher)=UPPER(publishingservername()) and publisher_db=db_name()
    if @pubid is null
    BEGIN
        RAISERROR (20026, 16, -1, @publication)
        RETURN (1)
    END

    set @need_ctsview_rowtrack= sys.fn_MSmerge_mightneedrowtrackbcp(@pubid)

    select @newid = newid()
    exec @retcode = sys.sp_MSguidtostr @newid, @newidstr out
    if @@ERROR <>0 OR @retcode <> 0
        return (1)
    exec @retcode = sys.sp_MSguidtostr @pubid, @pubidstr out
    if @@ERROR <>0 OR @retcode <> 0 
        return (1)

    if @generate_per_article = 1
    begin
        /* create temp table to insert into and select commands out of */
        declare @temp_cts_views table
        (
            step int identity NOT NULL,
            ctsvw sysname collate database_default null, 
            ctsvw_90_forall sysname collate database_default null,
            ctsvw_90_forglobal sysname collate database_default null,
            ctsview_rowtrack sysname collate database_default null,
            ctsvw_80 sysname collate database_default null,
            tablenickname int
        )
        if @@ERROR <> 0
            return (1)
    
        -- the view name was not passed in. We will generate the view names using the article id and the pubid
        -- this code was added to be able to reuse existing views when generating a dynamic snapshot
        -- by having definite view names constructed from pubid and artid we can reuse the views
        -- we will use newid if @dynamic_snapshot_views_table_name is passed in and use pubid otherwise
        if @create_dynamic_views = 1 or @dynsnap_views = 1
            set @tempidstr = @newidstr
        else
            set @tempidstr = @pubidstr
        
        select @tablenick = min(nickname) from dbo.sysmergearticles where pubid = @pubid and status<>@new_active and status<>@new_inactive
        while @tablenick is not null
        begin
            select @artid = artid, @upload_options = upload_options from dbo.sysmergearticles where nickname = @tablenick and pubid = @pubid
            exec @retcode = sys.sp_MSguidtostr @artid, @artidstr out
            if @@ERROR <>0 OR @retcode <> 0 return (1)

            set @ctsview = 'MSmerge_cont_' + @tempidstr + '_' + @artidstr

            -- if there are no contents row for the current article there is not need to create these views
            if exists (select 1 from dbo.MSmerge_contents where tablenick = @tablenick)
            begin
                if @upload_options<>1 and @upload_options<>2
                begin
                    set @ctsview_90_forall = 'MSmerge_cont_90_forall_' + @tempidstr + '_' + @artidstr
                    set @ctsview_90_forglobal = null
                end
                else
                begin
                    set @ctsview_90_forall = NULL
                    set @ctsview_90_forglobal = 'MSmerge_cont_90_forglobal_' + @tempidstr + '_' + @artidstr
                end

                if 1=@need_ctsview_rowtrack and @upload_options<>1 and @upload_options<>2
                    set @ctsview_rowtrack = 'MSmerge_cont_rowtrack_' + @tempidstr + '_' + @artidstr
                else
                    set @ctsview_rowtrack = null

                if @compatlevel < 90
                    set @ctsview_80 = 'MSmerge_cont_' + @tempidstr + '_' + @artidstr + '_80'
                else
                    set @ctsview_80 = NULL
            end
            else
            begin
                select @ctsview_90_forall = NULL
                select @ctsview_90_forglobal = NULL
                select @ctsview_rowtrack = NULL
                select @ctsview_80 = NULL
            end
            -- insert the view name into the temp table created in this proc
            insert into @temp_cts_views (ctsvw, ctsvw_90_forall, ctsvw_90_forglobal, ctsview_rowtrack, ctsvw_80, tablenickname) 
                                  values(@ctsview, @ctsview_90_forall, @ctsview_90_forglobal, @ctsview_rowtrack, @ctsview_80, @tablenick)

            /* Advance to next article and repeat the loop */
            select @tablenick = min(nickname) from dbo.sysmergearticles where
                pubid = @pubid and nickname > @tablenick and status<>@new_active and status<>@new_inactive
        end
    end
    else
    begin
        -- this is the regular case (called from sp_MSmakesystableviews)
        declare @tempcmd table 
        (
            phase int NOT NULL, 
            step int identity NOT NULL,
            cmdtext nvarchar(2600) collate database_default null
        )
    end

    -- drop the views if they already exist and if we need to drop the views
    -- do this only when generating per article views
    if @generate_per_article = 1 and @drop_views = 1
    begin
        select @tablenick = min(tablenickname) from @temp_cts_views
        while @tablenick is not null
        begin
            select  @ctsview = ctsvw, 
                    @ctsview_90_forall = ctsvw_90_forall, 
                    @ctsview_90_forglobal = ctsvw_90_forglobal, 
                    @ctsview_rowtrack = ctsview_rowtrack, 
                    @ctsview_80 = ctsvw_80 
            from @temp_cts_views where tablenickname = @tablenick

            exec @retcode = sp_MSdropview_internal @ctsview
            if @@ERROR<>0 OR @retcode<>0 return (1)

            exec @retcode = sp_MSdropview_internal @ctsview_90_forall
            if @@ERROR<>0 OR @retcode<>0 return (1)

            exec @retcode = sp_MSdropview_internal @ctsview_90_forglobal
            if @@ERROR<>0 OR @retcode<>0 return (1)

            exec @retcode = sp_MSdropview_internal @ctsview_rowtrack
            if @@ERROR<>0 OR @retcode<>0 return (1)

            exec @retcode = sp_MSdropview_internal @ctsview_80
            if @@ERROR<>0 OR @retcode<>0 return (1)

            select @tablenick = min(tablenickname) from @temp_cts_views where tablenickname > @tablenick
        end
    end

    /* pubidstr is needed in GUID format */
    set @pubidstr = '''' + convert(nchar(36), @pubid) + ''''

    -- beginning of actual makectsview. After this point is where the actual views get
    -- created or the view creation command is built up as the case may be for per article
    -- cts view and overall cts view respectively.
    if not exists (select * from dbo.sysmergesubsetfilters where pubid = @pubid and (filter_type & 1) = 1) and
       not exists (select * from dbo.sysmergearticles where pubid = @pubid and
                    len(subset_filterclause) > 0)
    begin
        -- Non-filtered case
        if @generate_per_article = 0
        begin
            -- If @generate_per_article = 0, an entire view is returned in @command_piece.
            set @command_piece = 'create view dbo.' + QUOTENAME(@ctsview) + ' as select * from dbo.MSmerge_contents '
                                    + ' where generation <= ' + convert(nvarchar, @max_bcp_gen)

            --5 and 6 are the new article statuses - they indicate new_inactive and new_active
            set @command_piece = @command_piece + ' and tablenick in
                (select nickname from dbo.sysmergearticles where status<>5 and status<>6 and pubid = ' + @pubidstr + ')'

            insert into @tempcmd (phase, cmdtext) values (1, @command_piece)
        end
        else
        begin
            -- per article contents view for unfiltered publication
            select @tablenick = min(nickname) from dbo.sysmergearticles where pubid = @pubid and status<>@new_active and status<>@new_inactive
            while @tablenick is not null
            begin
                if not exists(select * from @temp_cts_views where tablenickname = @tablenick)
                    return (1)

                select @is_coltracked = sys.fn_fIsColTracked(@tablenick) 
                select @colv_entries = sys.fn_cColvEntries_80(@pubid, @tablenick)
                
                select  @ctsview = ctsvw, 
                        @ctsview_90_forall = ctsvw_90_forall, 
                        @ctsview_90_forglobal = ctsvw_90_forglobal, 
                        @ctsview_rowtrack = ctsview_rowtrack, 
                        @ctsview_80 = ctsvw_80 
                from @temp_cts_views where tablenickname = @tablenick
                
                set @tablenickstr = convert(nchar(12), @tablenick)

                set @command_piece='create view dbo.' + QUOTENAME(@ctsview) + ' as select * from dbo.MSmerge_contents where tablenick = ' + @tablenickstr 
                                    + ' and generation <= ' + convert(nvarchar, @max_bcp_gen)
                exec (@command_piece)
                if @@ERROR <>0 return (1)

                exec @retcode = sys.sp_MS_marksystemobject @ctsview 
                if @@ERROR<>0 or @retcode<>0 return (1)

                if @ctsview_90_forall is not NULL
                begin
                    set @command_piece_forall = 'create view dbo.' + QUOTENAME(@ctsview_90_forall) + ' as select * from dbo.MSmerge_contents '
                                        + ' where generation <= ' + convert(nvarchar, @max_bcp_gen)
                    set @command_piece_forall = @command_piece_forall + ' and (tablenick = ' + @tablenickstr + ')'
                    exec ( @command_piece_forall )
                    if @@ERROR <>0 return (1)

                    -- mark all the views as system objects
                    exec @retcode = sys.sp_MS_marksystemobject @ctsview_90_forall 
                    if @@ERROR<>0 or @retcode<>0 return (1)
                end

                if @ctsview_90_forglobal is not NULL
                begin
                    set @command_piece_forglobal = 'create view dbo.' + QUOTENAME(@ctsview_90_forglobal) + ' as select * from dbo.MSmerge_contents ' 
                                                    + ' where generation <= ' + convert(nvarchar, @max_bcp_gen)
                    set @command_piece_forglobal = @command_piece_forglobal + ' and (tablenick = ' + @tablenickstr + ')'
                    exec ( @command_piece_forglobal )
                    if @@ERROR <>0 return (1)
                    exec @retcode = sys.sp_MS_marksystemobject @ctsview_90_forglobal 
                    if @@ERROR<>0 or @retcode<>0 return (1)
                end

                if @ctsview_rowtrack is not NULL
                begin
                    set @command_piece_rowtrack = 
                        'create view dbo.' + QUOTENAME(@ctsview_rowtrack) + ' 
                         as 
                            select 
                                tablenick, 
                                rowguid, 
                                changetype=cast(11 as tinyint), -- @METADATA_TYPE_UpsertLightweightProcessed
                                changed=cast(sys.fn_MSdayasnumber(getdate()) as int),
                                rowvector=substring(lineage, 1, 10) + 0xFF,
                                changedcolumns=cast(null as varbinary),
                                columns_enumeration='
                    if @is_coltracked = 1
                        select @command_piece_rowtrack = @command_piece_rowtrack + 'cast(0 as tinyint)' -- @COLUMNS_ENUMERATED_ChangedOnly
                    else
                        select @command_piece_rowtrack = @command_piece_rowtrack + 'cast(2 as tinyint)' -- @COLUMNS_ENUMERATED_AllOnOtherReason

                    select @command_piece_rowtrack = @command_piece_rowtrack + ',
                                sync_cookie=null
                            from dbo.MSmerge_contents
                            where generation <= ' + convert(nvarchar, @max_bcp_gen)
                    set @command_piece_rowtrack = @command_piece_rowtrack + ' and (tablenick = ' + @tablenickstr + ')'
                    exec ( @command_piece_rowtrack )
                    if @@ERROR <>0 return (1)
                    exec @retcode = sys.sp_MS_marksystemobject @ctsview_rowtrack 
                    if @@ERROR<>0 or @retcode<>0 return (1)
                end

                -- note here that ctsview_90_forall will be null for a downloadonly article. But download only articles are a 90 only feature.
                -- hence the following if should be false since when creating the ctsview names above we check whether the pub compat level is <90
                -- if so only then create this name.
                if @ctsview_80 is not NULL
                begin
                    set @command_piece= 'create view dbo.' + QUOTENAME(@ctsview_80) + ' as 
                    select tablenick, rowguid, 
                    generation = case when abs(generation) > 2147483647 then 0 else isnull(convert(int, generation),0) end, 
                    partchangegen = case when abs(partchangegen) > 2147483647 then 0 else convert(int, case when partchangegen < 0 then NULL else partchangegen end) end, 
                    joinchangegen = case when abs(partchangegen) > 2147483647 then 0 else convert(int, case when partchangegen < 0 then (-partchangegen) else partchangegen end) end, 
                    lineage = {fn LINEAGE_90_TO_80(lineage)}, 
                    colv1 = '
                    if @is_coltracked = 1
                        set @command_piece = @command_piece + '{fn COLV_90_TO_80(colv1, ' + convert(nvarchar(8), @colv_entries) + ')}'
                    else
                        set @command_piece = @command_piece + 'cast(null as varbinary)'
                        
                    set @command_piece = @command_piece + '
                    from ' + @ctsview
                    
                    exec @retcode= sys.sp_executesql @command_piece
                    if @@error <> 0 or @retcode <> 0 return 1
                    
                    exec @retcode = sys.sp_MS_marksystemobject @ctsview_80 
                    if @@ERROR<>0 or @retcode<>0 return (1)
                end
                
                /* Advance to next article and repeat the loop */
                select @tablenick = min(nickname) from dbo.sysmergearticles where
                    pubid = @pubid and nickname > @tablenick and status<>@new_active and status<>@new_inactive
            end
        end        
        goto Finish
    end
    else
    begin
        -- Filtered case.
        
        if @generate_per_article = 0
        begin
            set @command_piece = 'create view dbo.' + QUOTENAME(@ctsview) + ' as select * from dbo.MSmerge_contents where ' +
                                       ' generation <= ' + convert(nvarchar, @max_bcp_gen) + 
                                       ' and ({fn ISPALUSER(' + @pubidstr + ')} = 1) and '
            insert into @tempcmd (phase, cmdtext) values (1, @command_piece)
        end         

        /* Initialize for loop over articles in this publication */
        select @tablenick = min(nickname) from dbo.sysmergearticles where pubid = @pubid and status<>@new_active and status<>@new_inactive
        while @tablenick is not null
        begin
            select @is_coltracked = sys.fn_fIsColTracked(@tablenick) 
            select @colv_entries = sys.fn_cColvEntries_80(@pubid, @tablenick)
            
            if @dynamic_snapshot_views_table_name is null or @dynamic_snapshot_views_table_name = N''
            begin
                select @objid = objid, @view_type = view_type, @view_name = object_name(sync_objid) from 
                    dbo.sysmergearticles where pubid = @pubid and nickname = @tablenick 
            end
            else
            begin
                select @select_command = '
                    select @objid = sma.objid, 
                    @view_type = sma.view_type, 
                           @view_name = dsvt.dynamic_snapshot_view_name 
                      from dbo.sysmergearticles sma
                    inner join ' + quotename(@dynamic_snapshot_views_table_name) + ' dsvt 
                        on dsvt.artid = sma.artid            
                     where pubid = @pubid 
                       and nickname = @tablenick'
                exec sys.sp_executesql @select_command,
                                   N'@objid int output, 
                                     @view_type int output, 
                                     @view_name nvarchar(270) output,
                                     @pubid uniqueidentifier,
                                     @tablenick int',
                                   @objid = @objid output,
                                   @view_type = @view_type output, 
                                   @view_name = @view_name output,
                                   @pubid = @pubid,
                                   @tablenick = @tablenick  
                if @@error<>0 return(1)
            end
            select @rowguidcolname = name from sys.columns where object_id = @objid and is_rowguidcol=1 

            set @rowguidcolname = QUOTENAME(@rowguidcolname)
            set @view_name = QUOTENAME(@view_name)
            set @tablenickstr = convert(nchar(12), @tablenick)
                        
            if @generate_per_article = 0
            begin
                if @view_type <> 0
                begin
                    set @command_piece = @or_after_first + ' 
                    (tablenick = ' + @tablenickstr + ' and rowguid in
                        (select ' + @rowguidcolname + ' from ' + @view_name + '))'
                end
                else
                begin
                    set @command_piece = @or_after_first + ' 
                    (tablenick = ' + @tablenickstr + ')'
                end
                
                insert into @tempcmd (phase, cmdtext) values (2, @command_piece)
            end
            else
            begin
                -- by the time we reach this point we have already pregenerated the view names that should
                -- be used and stored them in the temp table @temp_cts_views
                -- check here to make sure that this article exists in the temp table
                if not exists(select * from @temp_cts_views where tablenickname = @tablenick)
                    return (1)
                
                select  @ctsview = ctsvw, 
                                @ctsview_90_forall = ctsvw_90_forall, 
                                @ctsview_90_forglobal = ctsvw_90_forglobal, 
                                @ctsview_rowtrack = ctsview_rowtrack, 
                                @ctsview_80 = ctsvw_80 
                    from @temp_cts_views where tablenickname = @tablenick

                if @view_type <> 0
                begin
                    set @command_piece = 'create view dbo.' + QUOTENAME(@ctsview) + 
                    ' as select * from dbo.MSmerge_contents 
                        where generation <= ' + convert(nvarchar, @max_bcp_gen) + '
                             and (tablenick = ' + @tablenickstr + ' and 
                            rowguid in (select ' + @rowguidcolname + ' from ' + @view_name + ')) '
                    exec ( @command_piece )
                    if @@ERROR <>0 return (1)

                    if @ctsview_90_forall is not NULL
                    begin
                        set @command_piece_forall = 'create view dbo.' + QUOTENAME(@ctsview_90_forall) + 
                        ' as select * from dbo.MSmerge_contents 
                            where generation <= ' + convert(nvarchar, @max_bcp_gen) + '
                                 and (tablenick = ' + @tablenickstr + ' and 
                                rowguid in (select ' + @rowguidcolname + ' from ' + @view_name + '))'
                        exec ( @command_piece_forall )
                        if @@ERROR <>0 return (1)
                    end

                    if @ctsview_90_forglobal is not NULL
                    begin
                        set @command_piece_forglobal = 'create view dbo.' + QUOTENAME(@ctsview_90_forglobal) + 
                        ' as select * from dbo.MSmerge_contents 
                            where generation <= ' + convert(nvarchar, @max_bcp_gen) + '
                             and (tablenick = ' + @tablenickstr + ' and 
                                rowguid in (select ' + @rowguidcolname + ' from ' + @view_name + ')) '
                        exec ( @command_piece_forglobal )
                        if @@ERROR <>0 return (1)
                    end

                    if @ctsview_rowtrack is not NULL
                    begin
                        set @command_piece_rowtrack = 'create view dbo.' + QUOTENAME(@ctsview_rowtrack) + 
                        ' as select 
                                tablenick, 
                                rowguid, 
                                changetype=cast(11 as tinyint), -- @METADATA_TYPE_UpsertLightweightProcessed
                                changed=cast(sys.fn_MSdayasnumber(getdate()) as int),
                                rowvector=substring(lineage, 1, 10) + 0xFF,
                                changedcolumns=cast(null as varbinary),
                                columns_enumeration='
                    if @is_coltracked = 1
                        select @command_piece_rowtrack = @command_piece_rowtrack + 'cast(0 as tinyint)' -- @COLUMNS_ENUMERATED_ChangedOnly
                    else
                        select @command_piece_rowtrack = @command_piece_rowtrack + 'cast(2 as tinyint)' -- @COLUMNS_ENUMERATED_AllOnOtherReason

                    select @command_piece_rowtrack = @command_piece_rowtrack + ',
                                sync_cookie=null
                            from dbo.MSmerge_contents
                            where generation <= ' + convert(nvarchar, @max_bcp_gen) + '
                             and (tablenick = ' + @tablenickstr + ' and 
                                rowguid in (select ' + @rowguidcolname + ' from ' + @view_name + ')) '
                        exec ( @command_piece_rowtrack )
                        if @@ERROR <>0 return (1)
                    end

                    if @ctsview_80 is not NULL
                    begin
                        set @command_piece = 'create view dbo.' + QUOTENAME(@ctsview_80) + ' as 
    select tablenick, rowguid, 
    generation = case when abs(generation) > 2147483647 then 0 else isnull(convert(int, generation),0) end, 
    partchangegen = case when abs(partchangegen) > 2147483647 then 0 else convert(int, case when partchangegen < 0 then NULL else partchangegen end) end, 
    joinchangegen = case when abs(partchangegen) > 2147483647 then 0 else convert(int, case when partchangegen < 0 then (-partchangegen) else partchangegen end) end, 
    lineage = {fn LINEAGE_90_TO_80(lineage)}, 
    colv1 = '
                        if @is_coltracked = 1
                            set @command_piece = @command_piece + '{fn COLV_90_TO_80(colv1, ' + convert(nvarchar(8), @colv_entries) + ')}'
                        else
                            set @command_piece = @command_piece + 'cast(null as varbinary)'
                            
                        set @command_piece = @command_piece + '
    from ' + QUOTENAME(@ctsview)
                        exec (@command_piece)
                        if @@ERROR <>0 return (1)
                    end
                end
                else
                begin
                    -- we get here if we find an unfiltered article in a publication which has some
                    -- subset filters
                    set @command_piece = 'create view dbo.' + QUOTENAME(@ctsview) + 
                    ' as select * from dbo.MSmerge_contents 
                        where generation <= ' + convert(nvarchar, @max_bcp_gen) + '
                             and (tablenick = ' + @tablenickstr + ')'
                    exec ( @command_piece )
                    if @@ERROR <>0 return (1)

                    if @ctsview_90_forall is not NULL
                    begin
                        set @command_piece_forall = 'create view dbo.' + QUOTENAME(@ctsview_90_forall) + 
                        ' as select * from dbo.MSmerge_contents 
                            where generation <= ' + convert(nvarchar, @max_bcp_gen) + '
                                 and (tablenick = ' + @tablenickstr + ') '
                        exec ( @command_piece_forall )
                        if @@ERROR <>0 return (1)
                    end
                    
                    if @ctsview_90_forglobal is not NULL
                    begin
                        set @command_piece_forglobal = 'create view dbo.' + QUOTENAME(@ctsview_90_forglobal) + 
                        ' as select * from dbo.MSmerge_contents 
                            where generation <= ' + convert(nvarchar, @max_bcp_gen) + '
                             and (tablenick = ' + @tablenickstr + ') '
                        exec ( @command_piece_forglobal )
                        if @@ERROR <>0 return (1)
                    end

                    if @ctsview_rowtrack is not NULL
                    begin
                        set @command_piece_rowtrack = 'create view dbo.' + QUOTENAME(@ctsview_rowtrack) + 
                        ' as select
                                tablenick, 
                                rowguid, 
                                changetype=cast(11 as tinyint), -- @METADATA_TYPE_UpsertLightweightProcessed
                                changed=cast(sys.fn_MSdayasnumber(getdate()) as int),
                                rowvector=substring(lineage, 1, 10) + 0xFF,
                                changedcolumns=cast(null as varbinary),
                                columns_enumeration='
                        if @is_coltracked = 1
                            select @command_piece_rowtrack = @command_piece_rowtrack + 'cast(0 as tinyint)' -- @COLUMNS_ENUMERATED_ChangedOnly
                        else
                            select @command_piece_rowtrack = @command_piece_rowtrack + 'cast(2 as tinyint)' -- @COLUMNS_ENUMERATED_AllOnOtherReason

                        select @command_piece_rowtrack = @command_piece_rowtrack + ',
                                sync_cookie=null
                            from dbo.MSmerge_contents 
                            where generation <= ' + convert(nvarchar, @max_bcp_gen) + '
                             and (tablenick = ' + @tablenickstr + ') '
                        exec ( @command_piece_rowtrack )
                        if @@ERROR <>0 return (1)
                    end

                    if @ctsview_80 is not NULL
                    begin
                        set @command_piece = 'create view dbo.' + QUOTENAME(@ctsview_80) + ' as 
    select tablenick, rowguid, 
    generation = case when abs(generation) > 2147483647 then 0 else isnull(convert(int, generation),0) end, 
    partchangegen = case when abs(partchangegen) > 2147483647 then 0 else convert(int, case when partchangegen < 0 then NULL else partchangegen end) end, 
    joinchangegen = case when abs(partchangegen) > 2147483647 then 0 else convert(int, case when partchangegen < 0 then (-partchangegen) else partchangegen end) end, 
    lineage = {fn LINEAGE_90_TO_80(lineage)}, 
    colv1 = '
                        if @is_coltracked = 1
                            set @command_piece = @command_piece + '{fn COLV_90_TO_80(colv1, ' + convert(nvarchar(8), @colv_entries) + ')}'
                        else
                            set @command_piece = @command_piece + 'cast(null as varbinary)'
                            
                        set @command_piece = @command_piece + '
    from ' + QUOTENAME(@ctsview)
                         exec (@command_piece)
                         if @@ERROR <>0 return (1)
                    end
                end
                
                -- mark all the views as system objects
                exec @retcode = sys.sp_MS_marksystemobject @ctsview 
                if @@ERROR<>0 or @retcode<>0 return (1)

                if @ctsview_90_forall is not NULL
                begin
                    exec @retcode = sys.sp_MS_marksystemobject @ctsview_90_forall 
                    if @@ERROR<>0 or @retcode<>0 return (1)
                end

                if @ctsview_90_forglobal is not NULL
                begin
                    exec @retcode = sys.sp_MS_marksystemobject @ctsview_90_forglobal 
                    if @@ERROR<>0 or @retcode<>0 return (1)
                end

                if @ctsview_rowtrack is not NULL
                begin
                    exec @retcode = sys.sp_MS_marksystemobject @ctsview_rowtrack 
                    if @@ERROR<>0 or @retcode<>0 return (1)
                end

                if @ctsview_80 is not NULL
                begin
                    exec @retcode = sys.sp_MS_marksystemobject @ctsview_80 
                    if @@ERROR<>0 or @retcode<>0 return (1)
                end
            end                 
            
            /* Advance to next article and repeat the loop */
            select @tablenick = min(nickname) from dbo.sysmergearticles where
                pubid = @pubid and nickname > @tablenick and status<>@new_active and status<>@new_inactive

            /* make it so that any subsequent selects in the view are preceded by the word UNION */
            /* using OR to replace 'UNION ALL', which is equivalent */
            set @or_after_first = ' OR '
        end -- end while @tablenick is not null
    end  -- end Filtered case if


Finish:
    /* final steps: select out the text and drop the temp table */
    if @generate_per_article = 0
    begin
        select cmdtext from @tempcmd order by phase, step
        -- don't drop table variable!
        --drop table @tempcmd
    end         
    else
    begin
        /* Select the view names so that the caller can query them so they can be BCP'd out and dropped later */
        -- to see how this is read and used look at CMergePublication::GenerateContentsBcpFile
        select ctsvw, ctsvw_90_forall, ctsvw_90_forglobal, ctsvw_80, ctsview_rowtrack from @temp_cts_views order by step
        -- don't drop table variable!
        --drop table @temp_cts_views
    end

    return(0)
GO
GRANT EXECUTE ON [sys].[sp_MSmakectsview] TO [public] AS [dbo]
GO
