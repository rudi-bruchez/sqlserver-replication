SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSenumchanges_notbelongtopartition]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSenumchanges_notbelongtopartition] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSenumchanges_notbelongtopartition]
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
    declare @command    nvarchar(max)  
    declare @selecttop  nvarchar(50)
    declare @last_art_processing_order int
    declare @metadatacols nvarchar(200)
    declare @retcode int
    declare @dbname nvarchar(258)
    declare @publication_number smallint
    declare @allow_partition_realignment bit
    declare @cpm_rowguid_clause nvarchar(100)
    declare @pcpm_rowguid_clause nvarchar(100)
    declare @mc_rowguid_clause nvarchar(100)
    declare @orderby_clause nvarchar(200)


    -- Security Checking 
    -- PAL user has access
    exec @retcode = sys.sp_MSrepl_PAL_rolecheck @pubid = @pubid, @tablenick = @tablenick, @partition_id = @partition_id
    if (@retcode <> 0) or (@@error <> 0)
        return 1
        
    select top 1 @publication_number = publication_number, @allow_partition_realignment = allow_partition_realignment 
        from dbo.sysmergepublications where pubid = @pubid

    exec sys.sp_MSmerge_parsegenlist @genlist, @generation_declare_list output, @generation_select_list output, @generation_union_list output    

    select @generation_clause = N' '    
    select @genlist_innerjoin_clause = N' '

    select @dbname = quotename(db_name())

    select @command = @generation_declare_list + @generation_select_list
    
    if (@maxrows = 0)
    begin
        set @selecttop= N' 
    select'
        set @orderby_clause = N' order by sma.processing_order desc, mc.tablenick desc' 
    end
    else
    begin
        set @selecttop= N'	
    select top ' + cast(@maxrows as nvarchar(9)) 
        set @orderby_clause = N' order by sma.processing_order desc, mc.tablenick desc, mc.rowguid asc' 
    end

    if 1 = @enumentirerowmetadata
        set @metadatacols= N'pcpm.generation, mc.lineage'
    else
        set @metadatacols= N'sys.fn_MSgeneration_downloadonly(pcpm.generation, mc.tablenick), sys.fn_MSvector_downloadonly(mc.lineage, mc.tablenick)'
    
    if @rowguid is NULL or @rowguid = '00000000-0000-0000-0000-000000000000'
    begin
        select @cpm_rowguid_clause = N' '
        select @pcpm_rowguid_clause = N' '
        select @mc_rowguid_clause = N' '
    end
    else
    begin
        select @cpm_rowguid_clause = N' and cpm.rowguid > @rowguid '
        select @pcpm_rowguid_clause = N' and pcpm.rowguid > @rowguid '
        select @mc_rowguid_clause = N' and mc.rowguid > @rowguid '
    end

    if (@genlist is not null and rtrim(ltrim(@genlist)) <> '')
    begin
        
        if (@maxgen = 0)
        begin
                            
            select @genlist_innerjoin_clause = N'
            inner join ( ' + @generation_union_list + '                                  
            ) as genlist
            on pcpm.generation = genlist.gen
            and genlist.gen is not NULL'
        
        end
        else if @mingen = @maxgen
        begin
            select @generation_clause = N' and pcpm.generation = @mingen '
        end
        else
        begin
            select @generation_clause = N' and pcpm.generation >= @mingen and pcpm.generation <= @maxgen '               
            select @genlist_innerjoin_clause = N'
            inner join ( ' + @generation_union_list + '                     
            ) as genlist
            on pcpm.generation = genlist.gen
            and genlist.gen is not NULL'                
        end
           
        if @tablenick = 0
        begin
            select @command = @command + @selecttop + N' mc.tablenick, mc.rowguid, pcpm.generation, mc.lineage, 5
                        from ' + @dbname + N'.[dbo].[MSmerge_contents] mc
                            inner join ' + @dbname + N'.[dbo].[sysmergearticles] sma 
                                    on mc.tablenick = sma.nickname and
                                       sma.pubid = @pubid ' + @mc_rowguid_clause + '
                            inner join ' + @dbname + N'.[dbo].[MSmerge_past_partition_mappings] pcpm 
                                    on pcpm.tablenick = mc.tablenick and 
                                       pcpm.rowguid = mc.rowguid and 
                                       (
                                           (pcpm.partition_id = @partition_id and pcpm.publication_number = @publication_number) or
                                           (pcpm.partition_id = @partition_id and pcpm.publication_number = 0) or
                                           (pcpm.partition_id = -1 and pcpm.publication_number = @publication_number) or
                        (pcpm.partition_id = -1 and pcpm.publication_number = 0))
                        ' + @generation_clause + 
                        @pcpm_rowguid_clause + N'
                        ' + @genlist_innerjoin_clause + N'
                        -- use the left outer join to find what partition changes need to enumerated as deletes (yiche)
                            left outer join ' + @dbname + N'.[dbo].[MSmerge_current_partition_mappings] cpm 
                                on cpm.tablenick = pcpm.tablenick and 
                                   cpm.rowguid = pcpm.rowguid and 
                                   (
                                         (cpm.partition_id = @partition_id and cpm.publication_number = @publication_number) or
                                         (cpm.partition_id = @partition_id and cpm.publication_number = 0) or
                                         (cpm.partition_id = -1 and cpm.publication_number = @publication_number) or
                                         (cpm.partition_id = -1 and cpm.publication_number = 0)
                                   )
                        where cpm.rowguid is NULL '
            if (@allow_partition_realignment = 0)
            begin
                select @command = @command + N' and pcpm.reason = 1'
            end

            select @command = @command + @orderby_clause
        end
        else
        begin
            exec sys.sp_MSget_article_processing_order @tablenick, @pubid, @last_art_processing_order output

            select @command = @command + @selecttop + N' mc.tablenick, mc.rowguid, pcpm.generation, mc.lineage, 5
                        from ' + @dbname + N'.[dbo].[MSmerge_contents] mc
                            inner join ' + @dbname + N'.[dbo].[sysmergearticles] sma 
                                on mc.tablenick = sma.nickname and 
                                   sma.pubid = @pubid
                                   and 
                                    ( 
                                        (mc.tablenick = @tablenick ' + @mc_rowguid_clause + N' ) or 
                        				(sma.processing_order = @last_art_processing_order and mc.tablenick < @tablenick) or
                        				sma.processing_order < @last_art_processing_order
                                    )
                            and
                            inner join ' + @dbname + N'.[dbo].[MSmerge_past_partition_mappings] pcpm 
                                on pcpm.tablenick = mc.tablenick and 
                                   pcpm.rowguid = mc.rowguid and 
                                   (
                                           (pcpm.partition_id = @partition_id and pcpm.publication_number = @publication_number) or
                                           (pcpm.partition_id = @partition_id and pcpm.publication_number = 0) or
                                           (pcpm.partition_id = -1 and pcpm.publication_number = @publication_number) or
                                           (pcpm.partition_id = -1 and pcpm.publication_number = 0)
                                   )
                            ' + @generation_clause + N'
                            ' + @genlist_innerjoin_clause + N'
                              -- use the left outer join to find what partition changes need to enumerated as deletes  (yiche)
                               left outer join ' + @dbname + N'.dbo.MSmerge_current_partition_mappings cpm
                               on cpm.tablenick = pcpm.tablenick and
                                   cpm.rowguid = pcpm.rowguid and
                                   (
                                           (cpm.partition_id = @partition_id and cpm.publication_number = @publication_number) or
                                           (cpm.partition_id = @partition_id and cpm.publication_number = 0) or
                                           (cpm.partition_id = -1 and cpm.publication_number = @publication_number) or
                                           (cpm.partition_id = -1 and cpm.publication_number = 0)
                                   )
                        where cpm.rowguid is NULL '

            if (@allow_partition_realignment = 0)
            begin
                    select @command = @command + N' and pcpm.reason = 1'
            end

            select @command = @command + @orderby_clause
        end

        exec sys.sp_executesql @command, N'@tablenick int = 0, @rowguid uniqueidentifier = ''00000000-0000-0000-0000-000000000000'', @pubid uniqueidentifier = ''00000000-0000-0000-0000-000000000000'', @publication_number smallint = 0, @partition_id int = 0, @mingen bigint = 0, @maxgen bigint = 0, @last_art_processing_order int = 0',             
            @tablenick=@tablenick, @rowguid=@rowguid, @pubid=@pubid, @publication_number=@publication_number, @partition_id=@partition_id, @mingen=@mingen, @maxgen=@maxgen, @last_art_processing_order = @last_art_processing_order            
        if @@error <> 0
            return 1
       
    end
    
-- DEBUG    insert into MSmerge_debug (okay, artnick, twhen, comment)   
-- DEBUG        values (0, @tablenick, getdate(), 'sp_MSenumchanges_notbelongtopartition; maxrows=' + convert(nvarchar, @maxrows) 
-- DEBUG        + ', startguid=' + convert(nchar(36), @rowguid) 
-- DEBUG        + ', genlist=' + rtrim(ltrim(@genlist)) + ', pubid=' + convert(nchar(36), @pubid))

    return (0)
GO
GRANT EXECUTE ON [sys].[sp_MSenumchanges_notbelongtopartition] TO [public] AS [dbo]
GO
