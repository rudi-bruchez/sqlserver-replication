SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSenumpartialchangesdirect]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSenumpartialchangesdirect] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSenumpartialchangesdirect]
	@maxrows [int],
	@temp_cont [sysname],
	@tablenick [int],
	@rowguid [uniqueidentifier],
	@pubid [uniqueidentifier],
	@compatlevel [int],
	@enumentirerowmetadata [bit],
	@blob_cols_at_the_end [bit],
	@maxschemaguidforarticle [uniqueidentifier]
WITH EXECUTE AS CALLER
AS
declare @tnstring       nvarchar(12)
    , @rgstring             nvarchar(38)
    , @quoted_owner_qualified_table_name nvarchar(521) -- 258 for owner, 258 for tablename, 5 for [].[]
    , @objid                int
    , @selecttop nvarchar(50)
    , @metadatacols nvarchar(300)
    , @cCols int
    , @rowguid_clause nvarchar(200)
    , @cmd nvarchar(max)
    , @column_list nvarchar(max)
    , @column_list_blob nvarchar(max)
    , @retcode int
    , @artid uniqueidentifier
    , @currentmaxschemaguidforarticle uniqueidentifier

    -- Security Checking 
    -- PAL user access
    exec @retcode = sys.sp_MSrepl_PAL_rolecheck @pubid = @pubid, @tablenick = @tablenick
    if (@retcode <> 0) or (@@error <> 0)
        return 1

    set @tnstring = convert(nchar, @tablenick)
        
    select @objid = objid, @artid = artid from dbo.sysmergearticles where nickname = @tablenick
    select @quoted_owner_qualified_table_name = quotename(SCHEMA_NAME(schema_id)) + '.' + quotename(name)
    from sys.objects where object_id = @objid

    if (@maxrows = 0)
        set @selecttop= 'select'
    else
        set @selecttop= 'select top ' + cast(@maxrows as nvarchar(9)) 
    
    if 0 = @enumentirerowmetadata
        set @metadatacols= 'mc.generation, null, null'
    else if @compatlevel >= 90
        set @metadatacols= 'mc.generation, mc.lineage, mc.colv'
    else if sys.fn_fIsColTracked(@tablenick) = 1
    begin
        set @cCols= sys.fn_cColvEntries_80(@pubid, @tablenick)
        set @metadatacols= 'mc.generation, {fn LINEAGE_90_TO_80(mc.lineage)}, {fn COLV_90_TO_80(mc.colv,' + cast(@cCols as nvarchar(6)) +')}'
    end
    else
        set @metadatacols= 'mc.generation, {fn LINEAGE_90_TO_80(mc.lineage)}, mc.colv'
        
    if @rowguid = '00000000-0000-0000-0000-000000000000'
        select @rowguid_clause = ' '
    else
    begin
        --set @rgstring = '''' + convert(nchar(36), @rowguid) + ''''
        --select @rowguid_clause = ' and mc.rowguid > ' + @rgstring + ' and t.rowguidcol > ' + @rgstring
        select @rowguid_clause = ' and mc.rowguid > @rowguid and t.rowguidcol > @rowguid '
    end 

    select @column_list = column_list, @column_list_blob = column_list_blob from dbo.sysmergepartitioninfoview where artid = @artid and pubid = @pubid    

    -- Use the column list with blob columns in the end if the blob_cols_at_the_end is 1
    if @blob_cols_at_the_end = 1
        select @column_list = @column_list_blob

    if @column_list is NULL
    begin
        exec @retcode = sys.sp_MSgetviewcolumnlist @pubid = @pubid, @source_objid = @objid, @column_list = @column_list OUTPUT, @prefix_tablename = 't.', @blob_cols_at_the_end=@blob_cols_at_the_end
        if @@ERROR<>0 OR @retcode <> 0
            return @retcode
    end

    /* execute (@selecttop + ' mc.tablenick, mc.rowguid, ' + @metadatacols + ', ' + @column_list + ' from ' + 
                            @temp_cont + ' mc, ' +
                            @quoted_owner_qualified_table_name + ' t 
                            where mc.tablenick = ' + @tnstring + 
                            @rowguid_clause + '
                            and mc.rowguid = t.rowguidcol
                            order by mc.rowguid') */
    select @cmd = @selecttop + ' mc.tablenick, mc.rowguid, ' + @metadatacols + ', ' + @column_list + ' from ' + 
                            quotename(@temp_cont) + ' mc, ' +
                            @quoted_owner_qualified_table_name + ' t 
                            where mc.tablenick = ' + @tnstring + 
                            @rowguid_clause + '
                            and mc.rowguid = t.rowguidcol
                            order by mc.tablenick, mc.rowguid'

    select @currentmaxschemaguidforarticle = sys.fn_GetArticleSchemaVersionGuid(@artid, @pubid)
    
        /* At the publisher, if the max schema guid for article has changed and is different from the agent's schema version for article raise error */
    if ((sys.fn_MSmerge_islocalpubid(@pubid) = 1) and (@maxschemaguidforarticle IS NOT NULL) and (@currentmaxschemaguidforarticle <> @maxschemaguidforarticle))
    begin
        RAISERROR (25007, 11, -1)
        return 5
    end 

    exec sys.sp_executesql @cmd, N'@rowguid uniqueidentifier = ''00000000-0000-0000-0000-000000000000''', @rowguid = @rowguid
    if @@error <> 0
    begin
        return (1)
    end                     

    return (0)
GO
GRANT EXECUTE ON [sys].[sp_MSenumpartialchangesdirect] TO [public] AS [dbo]
GO
