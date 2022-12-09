SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSenumchangesdirect]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSenumchangesdirect] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSenumchangesdirect]
	@maxrows [int],
	@genlist [varchar](2000),
	@tablenick [int],
	@rowguid [uniqueidentifier],
	@pubid [uniqueidentifier],
	@oldmaxgen [bigint],
	@mingen [bigint],
	@maxgen [bigint],
	@compatlevel [int],
	@enumentirerowmetadata [bit],
	@blob_cols_at_the_end [bit],
	@maxschemaguidforarticle [uniqueidentifier]
WITH EXECUTE AS CALLER
AS
declare @tnstring   nvarchar(12)
    , @oldmaxgenstr  nvarchar(21)
    , @rgstring   nvarchar(38)
    , @generation_clause nvarchar(max)
    , @generation_declare_list nvarchar(max)
    , @generation_select_list nvarchar(max)
    , @generation_union_list nvarchar(max)   
    , @genlist_innerjoin_clause nvarchar(max)
    , @quoted_owner_qualified_table_name nvarchar(776) -- 128*2 for dbname, 128*2 for owner, 128*2 for tablename, 8 for [].[].[]
    , @objid        int
    , @selecttop nvarchar(50)
    , @mingenstr nvarchar(21)
    , @maxgenstr nvarchar(21)
    , @metadatacols nvarchar(300)
    , @cCols int
    , @rowguid_clause nvarchar(200)
    , @cmd nvarchar(max)
    , @column_list nvarchar(max)
    , @column_list_blob nvarchar(max)
    , @retcode smallint
    , @artid uniqueidentifier
    , @dbname nvarchar(258)
    , @currentmaxschemaguidforarticle uniqueidentifier

   
    -- Security Checking 
    -- PAL user access
    exec @retcode = sys.sp_MSrepl_PAL_rolecheck @pubid = @pubid, @tablenick = @tablenick
    if (@retcode <> 0) or (@@error <> 0)
        return 1
    
    exec sys.sp_MSmerge_parsegenlist @genlist, @generation_declare_list output, @generation_select_list output, @generation_union_list output    

    select @generation_clause = ' '
    select @genlist_innerjoin_clause = ' '
    
    select @dbname = quotename(db_name())
    
    set @tnstring = convert(nchar, @tablenick)
    select @objid = objid, @artid = artid from dbo.sysmergearticles where nickname = @tablenick
    select @quoted_owner_qualified_table_name = @dbname + '.' + quotename(SCHEMA_NAME(schema_id)) + '.' + quotename(name)
    from sys.objects where object_id = @objid

    select @cmd = @generation_declare_list + @generation_select_list

    if (@maxrows = 0)
        set @selecttop= ' 
    select'
    else
        set @selecttop= ' 
    select top ' + cast(@maxrows as nvarchar(9)) 

    select @mingenstr = convert(nvarchar, @mingen)
    select @maxgenstr = convert(nvarchar, @maxgen)
                                                                        
        if @rowguid = '00000000-0000-0000-0000-000000000000'
                select @rowguid_clause = ' '
        else
        begin
                --set @rgstring = '''' + convert(nchar(36), @rowguid) + ''''
                --select @rowguid_clause = ' and mc.rowguid > ' + @rgstring + ' and t.rowguidcol > ' + @rgstring
                select @rowguid_clause = ' and mc.rowguid > @rowguid and t.rowguidcol > @rowguid '
        end 

    if 0 = @enumentirerowmetadata
        set @metadatacols= 'mc.generation, null, null'
    else if @compatlevel >= 90
        set @metadatacols= 'mc.generation, mc.lineage, mc.colv1'
    else if sys.fn_fIsColTracked(@tablenick) = 1
    begin
        set @cCols= sys.fn_cColvEntries_80(@pubid, @tablenick)
        set @metadatacols= 'mc.generation, {fn LINEAGE_90_TO_80(mc.lineage)}, {fn COLV_90_TO_80(mc.colv1,' + cast(@cCols as nvarchar(6)) +')}'
    end
    else
        set @metadatacols= 'mc.generation, {fn LINEAGE_90_TO_80(mc.lineage)}, mc.colv1'

    select @column_list = column_list, @column_list_blob = column_list_blob from dbo.sysmergepartitioninfoview where artid = @artid and pubid=@pubid    

    -- Use the column list with blob columns in the end if the blob_cols_at_the_end is 1
    if @blob_cols_at_the_end = 1
        select @column_list = @column_list_blob

    if @column_list is NULL
    begin
        exec @retcode = sys.sp_MSgetviewcolumnlist @pubid = @pubid, @source_objid = @objid, @column_list = @column_list OUTPUT, @prefix_tablename = 't.', @blob_cols_at_the_end=@blob_cols_at_the_end
        if @@ERROR<>0 OR @retcode <> 0
            return @retcode
    end

    if (@genlist is not null and rtrim(ltrim(@genlist)) <> '')
    begin
        if (@maxgen = 0)
        begin
                                
                select @genlist_innerjoin_clause = N'
                inner join ( ' + @generation_union_list + '                    
                ) as genlist
				  on mc.generation = genlist.gen
                  and genlist.gen is not NULL'
        end
        else if @maxgen = @mingen
                select @generation_clause = ' mc.generation = ' + @mingenstr + ' '
        else
        begin
                
                select @generation_clause = N' mc.generation >= ' + @mingenstr + N' and mc.generation <= ' + @maxgenstr + N' '
                select @genlist_innerjoin_clause = N'
                inner join ( ' + @generation_union_list + '                    
                ) as genlist
				  on mc.generation = genlist.gen
                  and genlist.gen is not NULL'              
        end

        if @oldmaxgen > 0
        begin
                set @oldmaxgenstr = convert(nvarchar, @oldmaxgen)
			    select @cmd = @cmd + @selecttop + N' mc.tablenick, mc.rowguid, ' + @metadatacols + N', ' + @column_list + N'
                        from   ' + @dbname + N'.[dbo].[MSmerge_contents] mc
                    inner join ' + @quoted_owner_qualified_table_name + N' t
                        on mc.rowguid = t.rowguidcol
                    ' + @genlist_innerjoin_clause + N'
                    where (
                        (' + @generation_clause + N')
                        or mc.generation = 0 or mc.generation > ' + @oldmaxgenstr + N'
                        )
                        and mc.tablenick = ' + @tnstring + 
                        @rowguid_clause + N'
                        order by mc.tablenick, mc.rowguid'                 
        end
        else
        begin
                select @cmd = @cmd + @selecttop + N' mc.tablenick, mc.rowguid, ' + @metadatacols + N', ' + @column_list + N'
                        from  ' + @dbname + N'.[dbo].[MSmerge_contents] mc
                    inner join ' + @quoted_owner_qualified_table_name + N' t
                        on mc.rowguid = t.rowguidcol
                    ' + @genlist_innerjoin_clause + N'
                    where ' + @generation_clause + N'
                        and mc.tablenick = ' + @tnstring + 
                        @rowguid_clause + N'
                        order by mc.tablenick, mc.rowguid'         
        end


        select @currentmaxschemaguidforarticle = sys.fn_GetArticleSchemaVersionGuid(@artid, @pubid)

        /* At the publisher, if the max schema guid for article has changed and is different from the agent's schema version for article raise error */
        if ((sys.fn_MSmerge_islocalpubid(@pubid) = 1) and (@maxschemaguidforarticle IS NOT NULL) and (@currentmaxschemaguidforarticle <> @maxschemaguidforarticle))
        begin
            RAISERROR (25007, 11, -1)
            return 5
        end 

        exec sys.sp_executesql @cmd, N'@rowguid uniqueidentifier = ''00000000-0000-0000-0000-000000000000''', @rowguid=@rowguid            
        if @@error <>0 
        begin
            return (1)
        end
    end

    return (0)
GO
GRANT EXECUTE ON [sys].[sp_MSenumchangesdirect] TO [public] AS [dbo]
GO
