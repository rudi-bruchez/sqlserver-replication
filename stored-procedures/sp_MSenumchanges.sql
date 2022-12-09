SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSenumchanges]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSenumchanges] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSenumchanges]
	@maxrows [int],
	@genlist [varchar](8000),
	@tablenick [int],
	@rowguid [uniqueidentifier],
	@pubid [uniqueidentifier],
	@oldmaxgen [bigint],
	@mingen [bigint],
	@maxgen [bigint],
	@compatlevel [int],
	@return_count_of_rows_initially_enumerated [bit],
	@enumentirerowmetadata [bit],
	@blob_cols_at_the_end [bit],
	@maxschemaguidforarticle [uniqueidentifier]
WITH EXECUTE AS CALLER
AS
declare @tnstring   nvarchar(12)
    declare @oldmaxgenstr  nvarchar(21)
    declare @retcode    smallint
    declare @procname   nvarchar(270)
    declare @generation_clause1 nvarchar(max)
    declare @generation_clause2 nvarchar(max)
    declare @generation_clause3 nvarchar(max)
    declare @error      int
    declare @count_of_rows_initially_enumerated int
    declare @rowguid_clause nvarchar(200)

    declare @objid_str  nvarchar(15)
    declare @objid      int
    declare @sync_objid int
    declare @sync_objid_str nvarchar(15)
    declare @colid      int
    declare @atpublisher  bit

    -- Security Checking 
    -- PAL user has access
    exec @retcode = sys.sp_MSrepl_PAL_rolecheck @pubid = @pubid, @tablenick = @tablenick
    if (@retcode <> 0) or (@@error <> 0)
        return 1

    select @atpublisher = sys.fn_MSmerge_islocalpubid(@pubid)
    
    select @generation_clause1 = ' '
    select @generation_clause2 = ' ' 
    select @generation_clause3 = ' '
    
    /*
    ** To public.
    */
    if (@tablenick is null)
    begin
        RAISERROR(14043, 16, -1, '@tablenick', 'sp_MSenumchanges')
-- DEBUG    insert into MSmerge_debug (okay, twhen, comment)
-- DEBUG    values (1, getdate(), 'sp_MSenumchanges: tablenick null')
        return (1)
    end
    if (@genlist is null)
    begin
        RAISERROR(14043, 16, -1, '@genlist', 'sp_MSenumchanges')
-- DEBUG    insert into MSmerge_debug (okay, twhen, comment)
-- DEBUG    values (2, getdate(), 'sp_MSenumchanges: genlist null')
        return (1)
    end
    
    create table #cont (
        tablenick int NOT NULL, 
        rowguid uniqueidentifier NOT NULL, 
        generation bigint NULL, 
        lineage varbinary(311) NULL, 
        colv1 varbinary(2953) NULL)
    
    select @procname = 'dbo.' + select_proc, @objid=objid, @sync_objid=sync_objid
        from dbo.sysmergearticles 
        where nickname=@tablenick and pubid = @pubid
     if @@rowcount=0
         return 1
     select @objid_str = convert(nvarchar, @objid)
     if @@rowcount=0
         return 1
     select @sync_objid_str = convert(nvarchar, @sync_objid)
     if @@rowcount=0
         return 1

    set @tnstring = convert(nchar, @tablenick)

    if @rowguid = '00000000-0000-0000-0000-000000000000'
        select @rowguid_clause = ' '
    else 
        select @rowguid_clause = ' and rowguid > ''' + convert(nchar(36), @rowguid) +   ''' '

    declare @selecttop nvarchar(50)
    if (@maxrows = 0)
        set @selecttop= 'select'
    else
        set @selecttop= 'select top ' + cast(@maxrows as nvarchar(9)) 

    declare @mingenstr nvarchar(21)
    declare @maxgenstr nvarchar(21)

    select @mingenstr = convert(nvarchar, @mingen)
    select @maxgenstr = convert(nvarchar, @maxgen)

    if (@maxgen = 0)
    begin
        select @generation_clause1 = ' generation in ('
        select @generation_clause2 = rtrim(ltrim(@genlist))
        select @generation_clause3 = ') '
    end
    else if @mingen = @maxgen
    begin
        select @generation_clause1 = ' generation = ' + @mingenstr + ' '
    end
    else
    begin
        -- this is always the case for 90 db, we omit @maxgenstr for blobgen since we are selecting subset from #cont
        select @generation_clause1 = ' generation >= ' + @mingenstr + ' and generation <= ' + @maxgenstr + ' and 
                         generation in ('
                select @generation_clause2 = rtrim(ltrim(@genlist))
                select @generation_clause3 = ') '
    end
    
    declare @metadatacols nvarchar(300)

    if 0 = @enumentirerowmetadata
        set @metadatacols= 'generation, null, null'
    else if @compatlevel >= 90
        set @metadatacols= 'generation, lineage, colv1'
    else if sys.fn_fIsColTracked(@tablenick) = 1
    begin
        declare @cCols int
        set @cCols= sys.fn_cColvEntries_80(@pubid, @tablenick)
        set @metadatacols= 'generation, {fn LINEAGE_90_TO_80(lineage)}, {fn COLV_90_TO_80(colv1,' + cast(@cCols as nvarchar(6)) +')}'
    end
    else
        set @metadatacols= 'generation, {fn LINEAGE_90_TO_80(lineage)}, colv1'
    
    if (@genlist is not null and rtrim(ltrim(@genlist)) <> '')
    begin
        if @oldmaxgen > 0
        begin
            set @oldmaxgenstr = convert(nvarchar, @oldmaxgen)
            execute ('insert into #cont ' +
                        @selecttop + ' tablenick, rowguid, ' + @metadatacols + '
                            from dbo.MSmerge_contents where 
                            (
                                (
                                    ' + @generation_clause1 + @generation_clause2 + @generation_clause3 + '
                                )
                                or generation = 0 or generation > ' + @oldmaxgenstr + '
                            ) 
                            and tablenick = ' + @tnstring + 
                            @rowguid_clause + ' 
                            order by tablenick, rowguid' )
        end
        else
        begin
            execute ('insert into #cont ' +
                        @selecttop + ' tablenick, rowguid, ' + @metadatacols + '
                            from dbo.MSmerge_contents where ' + @generation_clause1 + @generation_clause2 + @generation_clause3 + ' and 
                            tablenick = ' + @tnstring +
                            @rowguid_clause + ' 
                            order by tablenick, rowguid' )
        end

        select @count_of_rows_initially_enumerated = @@rowcount, @error = @@error

        if @error <>0 
        begin
    -- DEBUG    insert into MSmerge_debug 
    -- DEBUG        (okay, twhen, comment)
    -- DEBUG        values (3, getdate(), 'sp_MSenumchanges: insert into #cont failed')
            return (1)
        end
        if @return_count_of_rows_initially_enumerated = 1
            select @count_of_rows_initially_enumerated
    end

    -- Optimize: check colid is valid for the article in this publication or as currently we rely on sel_sp to pick right colid
    if (sys.fn_MSmerge_islocalpubid(@pubid) = 1) 
        exec @retcode = @procname 
                        @maxschemaguidforarticle = @maxschemaguidforarticle,
                        @type= 2,
                        @enumentirerowmetadata= @enumentirerowmetadata, --??
                        @blob_cols_at_the_end=@blob_cols_at_the_end
    else
        exec @retcode = @procname 
                        @maxschemaguidforarticle = NULL,
                        @type= 2,
                        @enumentirerowmetadata= @enumentirerowmetadata, --??
                        @blob_cols_at_the_end=@blob_cols_at_the_end
    IF @@ERROR<>0 or @retcode<>0
    
    begin
-- DEBUG    insert into MSmerge_debug 
-- DEBUG        (okay, twhen, comment)
-- DEBUG        values (4, getdate(), 'sp_MSenumchanges: select_proc failed')
        RETURN (1)
    end

-- DEBUG    insert into MSmerge_debug (okay, artnick, twhen, comment)   
-- DEBUG        values (0, @tablenick, getdate(), 'sp_MSenumchanges; maxrows=' + convert(nvarchar, @maxrows) 
-- DEBUG        + ', startguid=' + convert(nchar(36), @rowguid) 
-- DEBUG        + ', genlist=' + rtrim(ltrim(@genlist)) + ', pubid=' + convert(nchar(36), @pubid))

-- DEBUG execute ('
-- DEBUG    insert into MSmerge_debug
-- DEBUG        (okay, artnick, rowguid, generation_new, lineage_new, twhen, comment) ' +
-- DEBUG        @selecttop + ' 0, tablenick, rowguid, generation, lineage, getdate(), ''sp_MSenumchanges''
-- DEBUG        from #cont order by rowguid')

    drop table #cont
    return (0)
GO
GRANT EXECUTE ON [sys].[sp_MSenumchanges] TO [public] AS [dbo]
GO
