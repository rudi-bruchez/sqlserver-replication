SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSmakesystableviews]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSmakesystableviews] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSmakesystableviews]
	@publication [sysname],
	@dynamic_snapshot_views_table_name [sysname],
	@create_dynamic_views [bit],
	@max_bcp_gen [bigint]
WITH EXECUTE AS CALLER
AS
declare @guidstr        nvarchar(40)
    declare @pubid          uniqueidentifier
    declare @contentsview_80    sysname 
    declare @tombstoneview  sysname
    declare @genhistoryview_80  sysname
    declare @filtersview_80    sysname
    declare @filtersview_90    sysname
    declare @contentsview_90    sysname
    declare @contentsview_90_forall    sysname
    declare @contentsview_90_forglobal    sysname
    declare @rowtrackview    sysname
    declare @genhistoryview_90  sysname 
    declare @retcode smallint
    declare @dbname         sysname
    declare @command        nvarchar(4000)
    declare @dynamic_filters bit
    declare @view_creation_command nvarchar(4000)
    declare @newid  uniqueidentifier
    declare @dynsnap_views bit
    declare @compatlevel int
    declare @need_ctsview_rowtrack bit
    declare @need_ctsview_forglobal bit

    /*
    ** Check to see if current publication has permission
    */
    exec @retcode=sys.sp_MSreplcheck_publish
    if @retcode<>0 or @@ERROR<>0 return (1)

    if (@dynamic_snapshot_views_table_name is not null and @dynamic_snapshot_views_table_name <> N'')
        select @dynsnap_views = 1
    else
        select @dynsnap_views = 0

    select @pubid = pubid, @dynamic_filters = dynamic_filters, 
           @compatlevel = backward_comp_level
       from dbo.sysmergepublications where name = @publication and UPPER(publisher)=UPPER(publishingservername()) and publisher_db=db_name()
    if @pubid is null
    BEGIN
        RAISERROR (20026, 16, -1, @publication)
        RETURN (1)
    END
    
    set @need_ctsview_rowtrack= sys.fn_MSmerge_mightneedrowtrackbcp(@pubid)
    set @need_ctsview_forglobal= sys.fn_MSmerge_hasdownloadonlyarticles(@pubid)

    -- check if there are any generations higher than what 80 can understand
    -- if so return and not do any snapshot
    if @compatlevel < 90
    begin
        declare @maxgen_80 int
        set @maxgen_80= 2147483647
        if exists (select generation from dbo.MSmerge_genhistory where generation > @maxgen_80)
        begin
            raiserror(21521,16,1,@maxgen_80)
            return(1)
        end
    end

    create table #temp_table_for_systable_view
    (
        id int identity(1,1),
        contentsview sysname NULL, 
        tombstoneview sysname NULL, 
        genhistoryview sysname NULL, 
        filtersview sysname NULL, 
        contentsview_90_forall sysname NULL, 
        contentsview_90_forglobal sysname NULL, 
        genhistoryview_90 sysname NULL, 
        filtersview_90 sysname NULL,
        contentsview_90 sysname NULL,
        rowtrackview sysname NULL
    )

    -- use pubid to generate the view names only if we are not generating
    -- dynamic snapshot views
    if @dynsnap_views = 1 or @create_dynamic_views = 1
        set @newid = newid()
    else
        set @newid = @pubid
        
    exec @retcode = sys.sp_MSguidtostr @newid, @guidstr out
    if @@ERROR<>0 OR @retcode<>0 return (1)

    select @contentsview_80 = 'MSmerge_cont' + @guidstr
    select @contentsview_90 = 'MSmerge_cont' + @guidstr + '_90'
    select @contentsview_90_forall = 'MSmerge_cont' + @guidstr + '_90_forall'
    select @contentsview_90_forglobal = 'MSmerge_cont' + @guidstr + '_90_forglobal'
    select @tombstoneview = 'MSmerge_ts' + @guidstr
    select @genhistoryview_80 = 'MSmerge_gh' + @guidstr
    select @genhistoryview_90 = 'MSmerge_gh' + @guidstr + '_90'
    select @filtersview_80 = 'MSmerge_filt' + @guidstr
    select @filtersview_90 = 'MSmerge_filt' + @guidstr + '_90'
    select @rowtrackview = 'MSmerge_cont' + @guidstr + '_rowtrack'

    insert #temp_table_for_systable_view 
    (
    contentsview,
    tombstoneview, 
    genhistoryview, 
    filtersview, 
    contentsview_90_forall, 
    contentsview_90_forglobal, 
    genhistoryview_90, 
    filtersview_90,
    contentsview_90,
    rowtrackview
    )
    values
    (
        @contentsview_80,
        @tombstoneview,
        @genhistoryview_80,
        @filtersview_80,
        @contentsview_90_forall,
        @contentsview_90_forglobal,
        @genhistoryview_90,
        @filtersview_90,
        @contentsview_90,
        @rowtrackview
    )

CreateViews:
    -- if we generating a regular snapshot we need to drop the views if they exist
    if @dynsnap_views = 0 and @create_dynamic_views = 0
    begin
        exec @retcode = sys.sp_MSdropsystableviews @pubid
        if @@ERROR<>0 OR @retcode<>0 return (1)
    end

    set @guidstr = '''' + convert(nchar(36), @pubid) + ''''

    /* generate view for MSmerge_contents qualified by the pubid */
    /* For dynamically filtered publication, security check is performed in
       the sync view of the base table */
    -- only generate the views if there are rows in the MSmerge_contents table
    if exists (select * from MSmerge_contents)
    begin
        set @command = 'sys.sp_MSmakectsview ' + QUOTENAME(@publication) + ' , ' + quotename(@contentsview_90)
                            + ' , ' + COALESCE(quotename(@dynamic_snapshot_views_table_name) collate database_default, N'null' collate database_default)
                            + ' , ' + convert(nvarchar, @dynsnap_views) + ' , ' + convert(nvarchar,@max_bcp_gen)
        set @dbname = db_name()

        exec @retcode = sys.xp_execresultset @command, @dbname
        if @@ERROR<>0 OR @retcode <>0 return (1)
    end
    else
    begin
        set @command = 'create view dbo.' + quotename(@contentsview_90) + ' as select * from MSmerge_contents where 1 = 2'
		exec(@command)
                if @@ERROR<>0
                        return (1)
    end
    exec @retcode = sys.sp_MS_marksystemobject  @contentsview_90 
    if @@ERROR<>0 or @retcode<>0  return (1)


    -- Create the view on MSmerge_contents that contains rows which are updateable at every subscriber.
    select @view_creation_command = 'create view dbo.' + quotename(@contentsview_90_forall) + ' as 
    select * from ' + quotename(@contentsview_90) + '
        where tablenick in (select nickname from dbo.sysmergearticles where upload_options <> 1 and upload_options <> 2)  
            and generation <= ' + convert(nvarchar, @max_bcp_gen)

    exec (@view_creation_command)
    if @@ERROR <>0 return (1)
    exec @retcode = sys.sp_MS_marksystemobject  @contentsview_90_forall 
    if @@ERROR<>0 or @retcode<>0  return (1)

    if 1=@need_ctsview_forglobal
    begin
        -- Create the view on MSmerge_contents that contains rows which are only updateable at global subscribers.
        select @view_creation_command = 'create view dbo.' + quotename(@contentsview_90_forglobal) + ' as 
        select * from ' + quotename(@contentsview_90) + '
            where tablenick in (select nickname from dbo.sysmergearticles where upload_options = 1 or upload_options = 2)
            and generation <= ' + convert(nvarchar, @max_bcp_gen)
        
        exec (@view_creation_command)
        if @@ERROR <>0 return (1)
        exec @retcode = sys.sp_MS_marksystemobject  @contentsview_90_forglobal 
        if @@ERROR<>0 or @retcode<>0  return (1)
    end

    /* Create the view on MSmerge_contents that has the same format as the SQL2000 MSmerge_contents */
    /*  dont convert. let mdac do all the conversion. we anyway raise an error above incase the generation greater than max_int
    select @view_creation_command = 'create view dbo.' + @contentsview_80 + ' as 
    select tablenick, rowguid, 
    generation = case when abs(generation) > 2147483647 then 0 else convert(int, generation) end, 
    partchangegen = case when abs(partchangegen) > 2147483647 then 0 else convert(int, case when partchangegen < 0 then NULL else partchangegen end) end, 
    joinchangegen = case when abs(partchangegen) > 2147483647 then 0 else convert(int, case when partchangegen < 0 then (-partchangegen) else partchangegen end) end, 
    lineage = {fn LINEAGE_90_TO_80(lineage)}, 
    colv1 = case 
        when colv1 is null or sys.fn_fIsColTracked(tablenick) = 0 then colv1 
        else {fn COLV_90_TO_80(colv1, sys.fn_cColvEntries_80(''' + cast(@pubid as nvarchar(36)) + ''', tablenick))} end
    from ' + @contentsview_90
    */

    select @view_creation_command = 'create view dbo.' + quotename(@contentsview_80) + ' as 
    select tablenick, rowguid, generation = isnull(convert(int, generation),0), 
    partchangegen = case when partchangegen < 0 then NULL else convert(int, partchangegen) end, 
    joinchangegen = case when partchangegen < 0 then convert(int, (-partchangegen)) else convert(int, partchangegen) end, 
    lineage = {fn LINEAGE_90_TO_80(lineage)}, 
    colv1 = case 
        when colv1 is null or sys.fn_fIsColTracked(tablenick) = 0 then colv1 
        else {fn COLV_90_TO_80(colv1, sys.fn_cColvEntries_80(''' + cast(@pubid as nvarchar(36)) + ''', tablenick))} end
    from ' + quotename(@contentsview_90)

    exec (@view_creation_command)
    if @@ERROR <>0 return (1)
    exec @retcode = sys.sp_MS_marksystemobject  @contentsview_80 
    if @@ERROR<>0 or @retcode<>0  return (1)

    /* 
    ** generate the view for dbo.MSmerge_tombstone. In SP2 and Shiloh, the change was made to make the view 
    ** return 0 rows since it is unnecessary and expensive to propagate the tombstones.
    ** In order to leave all the other moving parts unchanged, we decided to let the view 
    ** return 0 rows.
    */

    select @view_creation_command = 'create view dbo.' + quotename(@tombstoneview) + ' as select * from dbo.MSmerge_tombstone where 1= 2'

    if @dynamic_filters = 1
    begin
        select @view_creation_command = @view_creation_command + ' and ({ fn ISPALUSER(''' + convert(nvarchar(36), @pubid) + ''') } = 1)'
    end

    exec (@view_creation_command)
    if @@ERROR <>0 
    begin
        return (1)
    end
    exec @retcode = sys.sp_MS_marksystemobject  @tombstoneview 
    if @@ERROR<>0 or @retcode<>0  return (1)

    -- Yukon genhistory view
    select @view_creation_command = 'create view dbo.' + quotename(@genhistoryview_90) + '(guidsrc, pubid, generation,
            art_nick, nicknames, coldate, genstatus, changecount, subscriber_number) as select DISTINCT guidsrc, CONVERT(uniqueidentifier, ' 
            + @guidstr + '), generation, art_nick, nicknames, coldate, genstatus, changecount, subscriber_number from dbo.MSmerge_genhistory gh
            where genstatus in (1,2) and 
                (art_nick = 0 or art_nick is NULL or art_nick in (select nickname from dbo.sysmergearticles where pubid = ' + @guidstr + ')) and 
                (pubid is null or pubid=(select top 1 pubid from dbo.MSmerge_genhistory where guidsrc=gh.guidsrc))  
            and generation <= ' + convert(nvarchar, @max_bcp_gen)

    if @dynamic_filters = 1
    begin
        select @view_creation_command = @view_creation_command + ' and ({ fn ISPALUSER(''' + convert(nvarchar(36), @pubid) + ''') } = 1)'
    end

    exec (@view_creation_command)
    if @@ERROR <>0
    begin
        return (1)
    end
    exec @retcode = sys.sp_MS_marksystemobject  @genhistoryview_90 
    if @@ERROR<>0 or @retcode<>0  return (1)

    /* Create the view on MSmerge_genhistory that has the same format as the SQL2000 MSmerge_genhistory */
    select @view_creation_command = 'create view dbo.' + quotename(@genhistoryview_80) + ' as 
    select guidsrc, guidlocal = newid(), pubid, generation = isnull(convert(int, generation),0), art_nick, nicknames= {fn REPLNICKARRAY_90_TO_80(nicknames)}, coldate from ' + quotename(@genhistoryview_90)

    exec (@view_creation_command)
    if @@ERROR <>0 
    begin
        return (1)
    end
    exec @retcode = sys.sp_MS_marksystemobject  @genhistoryview_80 
    if @@ERROR<>0 or @retcode<>0  return (1)

    select @view_creation_command = 'create view dbo.' + quotename(@filtersview_80) + ' as 
        select filtername, join_filterid, pubid, artid, art_nickname, join_articlename, 
                join_nickname, join_unique_key, expand_proc, join_filterclause 
        from dbo.sysmergesubsetfilters where pubid = ' + @guidstr + ' 
            and artid in (select artid from dbo.sysmergearticles where pubid = ' + @guidstr + ' and status <> 5 and status <> 6)'

    if @dynamic_filters = 1
    begin
        select @view_creation_command = @view_creation_command + ' and ({ fn ISPALUSER(''' + convert(nvarchar(36), @pubid) + ''') } = 1)'
    end
    
    exec (@view_creation_command)
    if @@ERROR <>0
    begin
        return (1)
    end
    exec @retcode = sys.sp_MS_marksystemobject  @filtersview_80 
    if @@ERROR<>0 or @retcode<>0  return (1)
        
    select @view_creation_command = 'create view dbo.' + quotename(@filtersview_90) + ' as 
        select filtername, join_filterid, pubid, artid, art_nickname, join_articlename, 
                join_nickname, join_unique_key, expand_proc, join_filterclause, filter_type 
        from dbo.sysmergesubsetfilters where pubid = ' + @guidstr + ' 
            and artid in (select artid from dbo.sysmergearticles where pubid = ' + @guidstr + ' and status <> 5 and status <> 6)'

    if @dynamic_filters = 1
    begin
        select @view_creation_command = @view_creation_command + ' and ({ fn ISPALUSER(''' + convert(nvarchar(36), @pubid) + ''') } = 1)'
    end
    
    exec (@view_creation_command)
    if @@ERROR <>0
    begin
        return (1)
    end
    exec @retcode = sys.sp_MS_marksystemobject  @filtersview_90
    if @@ERROR<>0 or @retcode<>0  return (1)

    if 1=@need_ctsview_rowtrack
    begin
        -- Create the view on MSmerge_contents for lightweight subscribers.
        select @view_creation_command = 'create view dbo.' + quotename(@rowtrackview) + ' as 
        
        select 
            tablenick, 
            rowguid, 
            changetype=cast(11 as tinyint), -- @METADATA_TYPE_UpsertLightweightProcessed
            changed=cast(sys.fn_MSdayasnumber(getdate()) as int),
            rowvector=substring(lineage, 1, 10) + 0xFF,
            changedcolumns=cast(null as varbinary),
            columns_enumeration=cast((case sys.fn_fIsColTracked(tablenick) 
                                        when 1 then 0 -- @COLUMNS_ENUMERATED_ChangedOnly
                                        else 2 -- @COLUMNS_ENUMERATED_AllOnOtherReason
                                     end) as tinyint),
            sync_cookie=null
        from ' + quotename(@contentsview_90) + '
            where tablenick in (select nickname from dbo.sysmergearticles where upload_options<>1 and upload_options<>2)'
        
        if @dynamic_filters = 1
        begin
            select @view_creation_command = @view_creation_command + ' and ({ fn ISPALUSER(''' + convert(nvarchar(36), @pubid) + ''') } = 1)'
        end
        
        exec (@view_creation_command)
        if @@ERROR <>0 return (1)
        exec @retcode = sys.sp_MS_marksystemobject  @rowtrackview 
        if @@ERROR<>0 or @retcode<>0  return (1)
    end

        -- set security for dynamic filters    
    if @dynamic_filters = 1
    begin

        set @command = 'grant select on ' + quotename(@contentsview_80) + ' to public'
		exec(@command)
        if @@error<>0 return(1)
        set @command = 'grant select on ' + quotename(@contentsview_90) + ' to public'
		exec(@command)
        if @@error<>0 return(1)
        set @command = 'grant select on ' + quotename(@contentsview_90_forall) + ' to public'
		exec(@command)
        if @@error<>0 return(1)
        if 1=@need_ctsview_forglobal
        begin
            set @command = 'grant select on ' + quotename(@contentsview_90_forglobal) + ' to public'
			exec(@command)
            if @@error<>0 return(1)
        end
        set @command = 'grant select on ' + quotename(@tombstoneview) + ' to public'
		exec(@command)
        if @@error<>0 return(1)
        set @command = 'grant select on ' + quotename(@genhistoryview_80) + ' to public'
		exec(@command)
        if @@error<>0 return(1)
        set @command = 'grant select on ' + quotename(@genhistoryview_90) + ' to public'
		exec(@command)
        if @@error<>0 return(1)
        set @command = 'grant select on ' + quotename(@filtersview_80) + ' to public'        
		exec(@command)
        if @@error<>0 return(1)
        set @command = 'grant select on ' + quotename(@filtersview_90) + ' to public'           
		exec(@command)
        if @@error<>0 return(1)
        if 1=@need_ctsview_rowtrack
        begin
            set @command = 'grant select on ' + quotename(@rowtrackview) + ' to public'
			exec(@command)
            if @@error<>0 return(1)
        end
    end

Finish:
    set nocount on
    /* we only generate per-article contents view for static publications */
    exec @retcode = sys.sp_MSgettablecontents @pubid, @dynamic_snapshot_views_table_name, @need_ctsview_rowtrack, @create_dynamic_views, @max_bcp_gen
    if @@ERROR<>0 OR @retcode <>0 return (1)
        
    exec('select     
    contentsview,
    tombstoneview, 
    genhistoryview, 
    filtersview, 
    contentsview_90_forall, 
    contentsview_90_forglobal, 
    genhistoryview_90, 
    filtersview_90,
    contentsview_90,
    rowtrackview
    from #temp_table_for_systable_view 
    order by id')
    
    drop table #temp_table_for_systable_view

    return (0)
GO
GRANT EXECUTE ON [sys].[sp_MSmakesystableviews] TO [public] AS [dbo]
GO
