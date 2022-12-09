SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSenumdeletes_forpartition]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSenumdeletes_forpartition] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSenumdeletes_forpartition]
	@partition_id [int],
	@maxrows [int],
	@genlist [varchar](8000),
	@tablenick [int],
	@rowguid [uniqueidentifier],
	@pubid [uniqueidentifier],
	@mingen [bigint],
	@maxgen [bigint],
	@enumentirerowmetadata [bit]
WITH EXECUTE AS CALLER
AS
declare @generation_clause nvarchar(max)    
    declare @generation_declare_list nvarchar(max)
    declare @generation_select_list nvarchar(max)
    declare @generation_union_list nvarchar(max)  
    declare @genlist_innerjoin_clause nvarchar(max)
    declare @ts_gen_clause nvarchar(max)
    declare @command    nvarchar(max)  
    declare @selecttop  nvarchar(50)
    declare @last_art_processing_order int
    declare @metadatacols nvarchar(200)
    declare @retcode int
    declare @dbname nvarchar(258)
    declare @allow_partition_realignment bit
    declare @ts_rowguid_clause nvarchar(100)
    declare @pcpm_rowguid_clause nvarchar(100)
    declare @logical_record_clause nvarchar(400)
    declare @publication_number smallint
    declare @orderby_clause nvarchar(200)

    
    -- Security Checking 
    -- PAL user has access
    exec @retcode = sys.sp_MSrepl_PAL_rolecheck @pubid = @pubid, @tablenick = @tablenick, @partition_id = @partition_id
    if (@retcode <> 0) or (@@error <> 0)
        return 1
        
    exec sys.sp_MSmerge_parsegenlist @genlist, @generation_declare_list output, @generation_select_list output, @generation_union_list output    
	
    select @dbname = quotename(db_name())
    
    select @generation_clause = N' '
    select @ts_gen_clause = N' '
    select @genlist_innerjoin_clause = N' '
    
    select @command = @generation_declare_list + @generation_select_list

    if (@maxrows = 0)
    begin
        set @selecttop= N' 
    select distinct '
        set @orderby_clause = N' order by sma.processing_order desc, ts.tablenick desc' 
        end
    else
    begin
        set @selecttop= N' 
    select distinct top ' + cast(@maxrows as nvarchar(9)) 
        set @orderby_clause = N' order by sma.processing_order desc, ts.tablenick desc, ts.rowguid asc' 
    end

    if 1 = @enumentirerowmetadata
        set @metadatacols= N'pcpm.generation, ts.lineage'
    else
        set @metadatacols= N'sys.fn_MSgeneration_downloadonly(pcpm.generation, ts.tablenick), sys.fn_MSvector_downloadonly(ts.lineage, ts.tablenick)'
    
   if @rowguid is NULL or @rowguid = '00000000-0000-0000-0000-000000000000'
    begin
        select @ts_rowguid_clause = N' '
        select @pcpm_rowguid_clause = N' '
    end
    else
    begin
        select @pcpm_rowguid_clause = N' and pcpm.rowguid > @rowguid '
        select @ts_rowguid_clause = N' and ts.rowguid > @rowguid '
    end

    select top 1 @publication_number = publication_number,
        @allow_partition_realignment=allow_partition_realignment from dbo.sysmergepublications where pubid = @pubid

    if exists (select 1 from dbo.sysmergepartitioninfoview where logical_record_view is not NULL)
        select @logical_record_clause = N'
                        and (ts.tablenick in 
                                (select nickname from dbo.sysmergepartitioninfoview where pubid = @pubid
                                and logical_record_view is null)
                                or
                                ts.logical_record_parent_rowguid is null
                                )'
    else 
        select @logical_record_clause = N''
    
    if (@genlist is not null and rtrim(ltrim(@genlist)) <> '')
    begin    
        if (@maxgen = 0)
        begin                
                select @ts_gen_clause = N' '
                select @genlist_innerjoin_clause = N'
                inner join ( ' + @generation_union_list + '  
                ) as genlist
                  on pcpm.generation = genlist.gen
                  and genlist.gen is not NULL'
        end
        else if @mingen = @maxgen
        begin
                select @generation_clause = N' and pcpm.generation = @mingen '
                select @ts_gen_clause = N' and ts.generation = @mingen '
        end
        else
        begin            
                select @generation_clause = N' and pcpm.generation >= @mingen and pcpm.generation <= @maxgen '
                select @ts_gen_clause = N' and ts.generation >= @mingen and ts.generation <= @maxgen '
                select @genlist_innerjoin_clause = N'
                inner join ( ' + @generation_union_list + '                      
                ) as genlist
                  on pcpm.generation = genlist.gen
                  and genlist.gen is not NULL'                
        end
                
        if @tablenick = 0
        begin
            -- the processing order in the select is not needed. It is only being selected so that we can use distict
            select @command = @command + @selecttop + N' ts.tablenick, ts.rowguid, pcpm.generation, ts.lineage, ts.type, sma.processing_order
                        from ' + @dbname + N'.[dbo].[MSmerge_tombstone] ts
                            inner join ' + @dbname + N'.[dbo].[sysmergearticles] sma 
                                on ts.tablenick = sma.nickname ' + @ts_rowguid_clause + N'
                            inner join ' + @dbname + N'.[dbo].[MSmerge_past_partition_mappings] pcpm 
                                on pcpm.tablenick = ts.tablenick and pcpm.rowguid = ts.rowguid ' + @pcpm_rowguid_clause + N'
                        ' + @generation_clause + @ts_gen_clause + N'
                        and sma.pubid = @pubid
                        and 
                        (
                            (pcpm.partition_id = @partition_id and pcpm.publication_number = @publication_number) or
                            (pcpm.partition_id = @partition_id and pcpm.publication_number = 0) or
                            (pcpm.partition_id = -1 and pcpm.publication_number = @publication_number) or
                            (pcpm.partition_id = -1 and pcpm.publication_number = 0)
                        ) '
                        + @logical_record_clause
            if (@allow_partition_realignment = 0)
            begin
                    select @command = @command + N' and pcpm.reason = 1'
            end
            select @command = @command + N'
                        ' + @genlist_innerjoin_clause
            select @command = @command + @orderby_clause
        end
        else
        begin
            exec sys.sp_MSget_article_processing_order @tablenick, @pubid, @last_art_processing_order output

            -- the processing order in the select is not needed. It is only being selected so that we can use distict
            select @command = @command + @selecttop + N' ts.tablenick, ts.rowguid, pcpm.generation, ts.lineage, ts.type, sma.processing_order
                        from ' + @dbname + N'.[dbo].[MSmerge_tombstone] ts
                            inner join ' + @dbname + N'.[dbo].[sysmergearticles] sma on ts.tablenick = sma.nickname 
                            inner join ' + @dbname + N'.[dbo].[MSmerge_past_partition_mappings] pcpm 
                                on pcpm.tablenick = ts.tablenick and pcpm.rowguid = ts.rowguid
                        ' + @generation_clause + @ts_gen_clause + N'
                        and 
                        ( 
                            (ts.tablenick = @tablenick' + @ts_rowguid_clause + N') or 
                            (sma.processing_order = @last_art_processing_order and ts.tablenick < @tablenick) or
                            sma.processing_order < @last_art_processing_order
                        )
                        and sma.pubid = @pubid
                        and
                        (
                            (pcpm.partition_id = @partition_id and pcpm.publication_number = @publication_number) or
                            (pcpm.partition_id = @partition_id and pcpm.publication_number = 0) or
                            (pcpm.partition_id = -1 and pcpm.publication_number = @publication_number) or
                            (pcpm.partition_id = -1 and pcpm.publication_number = 0)
                        ) '
                        + @logical_record_clause
            if (@allow_partition_realignment = 0)
            begin
                    select @command = @command + N' and pcpm.reason = 1'
            end
            select @command = @command + N'
                        ' + @genlist_innerjoin_clause
            select @command = @command + @orderby_clause
        end

        exec sys.sp_executesql @command, N'@tablenick int = 0, @rowguid uniqueidentifier = ''00000000-0000-0000-0000-000000000000'', @pubid uniqueidentifier = ''00000000-0000-0000-0000-000000000000'', @publication_number smallint = 0, @partition_id int = 0, @mingen bigint = 0, @maxgen bigint = 0, @last_art_processing_order int = 0',            
            @tablenick=@tablenick, @rowguid=@rowguid, @pubid=@pubid, @publication_number=@publication_number, @partition_id=@partition_id, @mingen=@mingen, @maxgen=@maxgen, @last_art_processing_order = @last_art_processing_order            
        if @@error <> 0
            return 1
    end
    
-- DEBUG    insert into MSmerge_debug (okay, artnick, twhen, comment)   
-- DEBUG        values (0, @tablenick, getdate(), 'sp_MSenumdeletes_forpartition; maxrows=' + convert(nvarchar, @maxrows) 
-- DEBUG        + ', startguid=' + convert(nchar(36), @rowguid) 
-- DEBUG        + ', genlist=' + rtrim(ltrim(@genlist)) + ', pubid=' + convert(nchar(36), @pubid))

    return (0)
GO
GRANT EXECUTE ON [sys].[sp_MSenumdeletes_forpartition] TO [public] AS [dbo]
GO
