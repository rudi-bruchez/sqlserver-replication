SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSenumchanges_belongtopartition]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSenumchanges_belongtopartition] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSenumchanges_belongtopartition]
	@partition_id [int],
	@maxrows [int],
	@genlist [varchar](8000),
	@tablenick [int],
	@rowguid [uniqueidentifier],
	@pubid [uniqueidentifier],
	@mingen [bigint],
	@maxgen [bigint],
	@enumentirerowmetadata [bit],
	@blob_cols_at_the_end [bit],
	@maxschemaguidforarticle [uniqueidentifier]
WITH EXECUTE AS CALLER
AS
declare @generation_clause nvarchar(max)
    declare @generation_declare_list nvarchar(max)
    declare @generation_select_list nvarchar(max)
    declare @generation_union_list nvarchar(max)      
    declare @contents2_innerjoin_clause nvarchar(max)
    declare @genlist_innerjoin_clause nvarchar(max)
    declare @qualified_repl_view_name nvarchar(776) -- 258*3 + 2 for '.'
    declare @command    nvarchar(max)  
    declare @column_list nvarchar(max)
    declare @column_list_blob nvarchar(max)
    declare @objid int
    declare @selecttop nvarchar(50)
    declare @retcode int
    declare @dbname nvarchar(258)
    declare @cpm_rowguid_clause nvarchar(100)
    declare @mc_rowguid_clause nvarchar(100)
    declare @currentmaxschemaguidforarticle uniqueidentifier
    declare @artid uniqueidentifier
    declare @inner_orderby_clause nvarchar(100)
    declare @outer_orderby_clause nvarchar(100)

  
    -- Security Checking 
    -- PAL user has access
    exec @retcode = sys.sp_MSrepl_PAL_rolecheck @pubid = @pubid, @tablenick = @tablenick, @partition_id = @partition_id
    if (@retcode <> 0) or (@@error <> 0)
        return 1
	
    select @dbname = quotename(db_name())

    select @artid = artid from dbo.sysmergearticles where nickname = @tablenick

    exec sys.sp_MSmerge_parsegenlist @genlist, @generation_declare_list output, @generation_select_list output, @generation_union_list output    
    
    select @generation_clause = N' '    
    select @contents2_innerjoin_clause = N' '
    select @genlist_innerjoin_clause = N' '
    
    select @command = @generation_declare_list + @generation_select_list

    if (@maxrows = 0)
    begin
        set @selecttop= N' select distinct '
        set @inner_orderby_clause = N''
        set @outer_orderby_clause = N''
    end
    else
    begin
        set @selecttop= N' select distinct top ' + cast(@maxrows as nvarchar(9)) 
        set @inner_orderby_clause = N' order by mc.tablenick, mc.rowguid '
        set @outer_orderby_clause = N' order by t.rowguidcol '
    end
    
    select @qualified_repl_view_name = @dbname + N'.' + 
        (select quotename(SCHEMA_NAME(o.schema_id)) from sys.objects o where o.object_id = v.repl_view_id) + N'.' +
            quotename(object_name(v.repl_view_id)), 
        @column_list = v.column_list,
        @column_list_blob = v.column_list_blob,
        @objid = objid
    from dbo.sysmergepartitioninfoview v
    where v.nickname = @tablenick 
    and v.pubid = @pubid
    
    -- Use the column list with blob columns in the end if the blob_cols_at_the_end is 1
    if @blob_cols_at_the_end = 1
        select @column_list = @column_list_blob
        
    declare @publication_number smallint
    select top 1 @publication_number = publication_number from dbo.sysmergepublications where pubid = @pubid

    declare @metadatacolumns nvarchar(100)
    if 1=@enumentirerowmetadata
    begin
        set @metadatacolumns= 'mc.generation as generation, mc2.lineage as lineage, mc2.colv1 as colv '
        -- since columns lineage and colv1 are not in covering in index, add a 2nd join with contents to force reordering of joins and 
        -- avoid base table lookup for these two columns
        set @contents2_innerjoin_clause = '
            inner join ' + @dbname + N'.[dbo].[MSmerge_contents] mc2
            on mc2.tablenick = mc.tablenick
            and mc2.rowguid = mc.rowguid'
    end	
    else
        set @metadatacolumns= 'mc.generation as generation, null as lineage, null as colv '

    if @rowguid is NULL or @rowguid = '00000000-0000-0000-0000-000000000000'
    begin
        select @cpm_rowguid_clause = ' '
        select @mc_rowguid_clause = ' '
    end
    else
    begin
        select @cpm_rowguid_clause = ' and cpm.rowguid > @rowguid '
        select @mc_rowguid_clause = ' and mc.rowguid > @rowguid '
    end

    if (@genlist is not null and rtrim(ltrim(@genlist)) <> '')
    begin           
        if (@maxgen = 0)
        begin             
                select @genlist_innerjoin_clause = N'
                inner join ( ' + @generation_union_list + '        
                ) as genlist
                  on genlist.gen = mc.generation
                  and genlist.gen is not NULL'
        end
        else if @mingen = @maxgen
                select @generation_clause = N' mc.generation = @mingen and '
        else
        begin
                select @generation_clause = N' mc.generation >= @mingen and mc.generation <= @maxgen and '
                select @genlist_innerjoin_clause = N'
                inner join ( ' + @generation_union_list + '                     
                ) as genlist
                    on mc.generation = genlist.gen
                    and genlist.gen is not NULL'
        end
        
        select @command = @command + ' 
		select rows.tablenick, rows.rowguid, rows.generation, rows.lineage, rows.colv, ' + @column_list + N'
        from (
                ' + @selecttop + N' mc.tablenick as tablenick, mc.rowguid as rowguid, ' + @metadatacolumns + N'
                                from ' + @dbname + N'.[dbo].[MSmerge_contents] mc
                                        inner join ' + @dbname + N'.[dbo].[MSmerge_current_partition_mappings] cpm 
                                        on cpm.tablenick = mc.tablenick 
                                        and cpm.rowguid = mc.rowguid 
                                        and cpm.tablenick = @tablenick
                                        and mc.tablenick = @tablenick
                                        ' + @contents2_innerjoin_clause + N'
                                        ' + @genlist_innerjoin_clause + N'
                                where ' + @generation_clause + N'
                                mc.tablenick = @tablenick
                                and cpm.tablenick = @tablenick'
                                + @mc_rowguid_clause + @cpm_rowguid_clause + N'
                                and 
                                (
                                        (cpm.partition_id = @partition_id and cpm.publication_number = @publication_number) or
                                        (cpm.partition_id = @partition_id and cpm.publication_number = 0) or
                                        (cpm.partition_id = -1 and cpm.publication_number = @publication_number) or
                                        (cpm.partition_id = -1 and cpm.publication_number = 0)
                                )
                        ' + @inner_orderby_clause + N'
                ) as rows
                inner join ' + @qualified_repl_view_name + N' t on t.rowguidcol = rows.rowguid
                ' + @outer_orderby_clause 

        select @currentmaxschemaguidforarticle = sys.fn_GetArticleSchemaVersionGuid(@artid, @pubid)

        /* At the publisher, if the max schema guid for article has changed and is different from the agent's schema version for article raise error */
        if ((sys.fn_MSmerge_islocalpubid(@pubid) = 1) and (@maxschemaguidforarticle IS NOT NULL) and (@currentmaxschemaguidforarticle <> @maxschemaguidforarticle))
        begin
            RAISERROR (25007, 11, -1)
            return 5
        end

        exec sys.sp_executesql @command, N'@tablenick int = 0, @rowguid uniqueidentifier = ''00000000-0000-0000-0000-000000000000'', @pubid uniqueidentifier = ''00000000-0000-0000-0000-000000000000'', 
            @publication_number smallint = 0, @partition_id int = 0, @mingen bigint = 0, @maxgen bigint = 0',             
            @tablenick=@tablenick, @rowguid=@rowguid, @pubid=@pubid, @publication_number=@publication_number, @partition_id=@partition_id, @mingen=@mingen, @maxgen=@maxgen            
            

        if @@error <> 0
            return 1
    end
    
    return (0)
GO
GRANT EXECUTE ON [sys].[sp_MSenumchanges_belongtopartition] TO [public] AS [dbo]
GO
