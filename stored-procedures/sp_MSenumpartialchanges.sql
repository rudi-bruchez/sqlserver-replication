SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSenumpartialchanges]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSenumpartialchanges] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSenumpartialchanges]
	@maxrows [int],
	@temp_cont [sysname],
	@tablenick [int],
	@rowguid [uniqueidentifier],
	@pubid [uniqueidentifier],
	@compatlevel [int],
	@return_count_of_rows_initially_enumerated [bit],
	@enumentirerowmetadata [bit],
	@blob_cols_at_the_end [bit],
	@maxschemaguidforarticle [uniqueidentifier]
WITH EXECUTE AS CALLER
AS
declare @retcode        smallint
    declare @tnstring       nvarchar(12)
    -- Owner qualified
    declare @procname       nvarchar(270)
    declare @error          int
    declare @count_of_rows_initially_enumerated int

    declare @objid              int
    declare @objid_str  nvarchar(15)
    declare @sync_objid int
    declare @sync_objid_str nvarchar(15)
    declare @colid              int
    declare @rowguid_clause nvarchar(200)

    -- Security Checking 
    -- PAL user has access
    exec @retcode = sys.sp_MSrepl_PAL_rolecheck @pubid = @pubid, @tablenick = @tablenick
    if (@retcode <> 0) or (@@error <> 0)
        return 1

    if (@tablenick is null)
    begin
    RAISERROR(14043, 16, -1, '@tablenick', 'sp_MSenumpartialchanges')
-- DEBUG    insert into MSmerge_debug 
-- DEBUG        (okay, twhen, comment)
-- DEBUG        values (1, getdate(), 'sp_MSenumpartialchanges: tablenick null')
    return (1)
    end

    set @tnstring = convert(nchar, @tablenick)

    if @rowguid is null or @rowguid = '00000000-0000-0000-0000-000000000000'
        select @rowguid_clause = ' '
    else
        select @rowguid_clause = ' and rowguid > ''' + convert(nchar(36), @rowguid) + ''' '

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

    declare @selecttop nvarchar(50)
    if (@maxrows = 0)
        set @selecttop= 'select'
    else
        set @selecttop= 'select top ' + cast(@maxrows as nvarchar(9)) 
    
    declare @metadatacols nvarchar(300)

    if 0 = @enumentirerowmetadata
        set @metadatacols= 'generation, null, null'
    else if @compatlevel >= 90
        set @metadatacols= 'generation, lineage, colv'
    else if sys.fn_fIsColTracked(@tablenick) = 1
    begin
        declare @cCols int
        set @cCols= sys.fn_cColvEntries_80(@pubid, @tablenick)
        set @metadatacols= 'generation, {fn LINEAGE_90_TO_80(lineage)}, {fn COLV_90_TO_80(colv,' + cast(@cCols as nvarchar(6)) +')}'
    end
    else
        set @metadatacols= 'generation, {fn LINEAGE_90_TO_80(lineage)}, colv'

    execute ('insert into #cont(tablenick, rowguid, generation,lineage,colv1) ' +
                @selecttop + ' tablenick, rowguid, ' + @metadatacols + ' from ' + @temp_cont + ' where
                        tablenick = ' + @tnstring + @rowguid_clause 
                        + ' order by rowguid')
  
    select @count_of_rows_initially_enumerated = @@rowcount, @error = @@error
    if @error <> 0
    begin
        return (1)
    end                     

    if @return_count_of_rows_initially_enumerated = 1
        select @count_of_rows_initially_enumerated

        -- Optimize: check colid is valid for the article in this publication or as currently we rely on sel_sp to pick right colid
        

        exec @retcode= @procname 
                                        @maxschemaguidforarticle = @maxschemaguidforarticle,
                                                @type= 3,  -- for partial changes (horizontal filter)
                                                @enumentirerowmetadata= @enumentirerowmetadata,
                                                @blob_cols_at_the_end=@blob_cols_at_the_end
                                        
    IF @@ERROR<>0 or @retcode<>0 
    begin
-- DEBUG    insert into MSmerge_debug 
-- DEBUG        (okay, twhen, comment)
-- DEBUG        values (3, getdate(), 'sp_MSenumpartialchanges: select_proc failed')
        RETURN (1)
    end

-- DEBUG    insert into MSmerge_debug
-- DEBUG        (okay, artnick, twhen, comment)
-- DEBUG        values (0, @tablenick, getdate(), 'sp_MSenumpartialchanges; maxrows=' + convert(nvarchar, @maxrows) 
-- DEBUG        + ', startguid=' + convert(nchar(36), @rowguid) + ', pubid=' + convert(nchar(36), @pubid))  

-- DEBUG execute ('
-- DEBUG    insert into MSmerge_debug
-- DEBUG        (okay, artnick, rowguid, generation_new, lineage_new, twhen, comment) ' +
-- DEBUG        @selecttop + ' 0, tablenick, rowguid, generation, lineage, getdate(), ''sp_MSenumpartialchanges''
-- DEBUG        from #cont order by rowguid')

    drop table #cont
    return (0)
GO
GRANT EXECUTE ON [sys].[sp_MSenumpartialchanges] TO [public] AS [dbo]
GO
