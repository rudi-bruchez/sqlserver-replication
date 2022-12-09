SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSenumpartialdeletes]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSenumpartialdeletes] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSenumpartialdeletes]
	@maxrows [int],
	@tablenick [int],
	@rowguid [uniqueidentifier],
	@tablenotbelongs [nvarchar](255),
	@bookmark [int],
	@specified_article_only [int],
	@compatlevel [int],
	@pubid [uniqueidentifier],
	@enumentirerowmetadata [bit]
WITH EXECUTE AS CALLER
AS
declare @tnstring       nvarchar(12)
    declare @lowrangestr    nvarchar(12) 
    declare @highrangestr   nvarchar(12) 
    declare @pubidstr        varchar(40)
    declare @last_art_processing_order int
    declare @last_art_processing_order_str varchar(12)
    declare @rowguid_clause nvarchar(100)
	declare @command nvarchar(2000)

    /*
    ** do permission checking
    */
    declare @retcode             int
    exec @retcode = sys.sp_MSrepl_PAL_rolecheck @tablenick = @tablenick
    if @retcode<>0 or @@ERROR<>0 return (1)
    
    declare @selecttop nvarchar(50)
    if (@maxrows = 0)
        set @selecttop= 'select'
    else
        set @selecttop= 'select top ' + cast(@maxrows as nvarchar(9)) 

    declare @metadatacol nvarchar(200)
    declare @metadatacol2 nvarchar(200)

    if 0 = @enumentirerowmetadata
    begin
        if 1 > @tablenick or 0 = @specified_article_only
        begin
            set @metadatacol= 'sys.fn_MSgeneration_downloadonly(generation, tablenick), sys.fn_MSvector_downloadonly(lineage, tablenick)'
            set @metadatacol2= 'sys.fn_MSgeneration_downloadonly(t.generation, tablenick), sys.fn_MSvector_downloadonly(lineage, tablenick)'
        end
        else
        begin
            set @metadatacol= 'null, null'
            set @metadatacol2= 'null, null'
        end
    end
    else if @compatlevel >= 90
    begin
        set @metadatacol= 'coalesce(generation, 0), lineage'
        set @metadatacol2= 'coalesce(t.generation, 0), lineage'
    end
    else
    begin
        set @metadatacol= 'coalesce(generation, 0), {fn LINEAGE_90_TO_80(lineage)}'
        set @metadatacol2= 'coalesce(t.generation, 0), {fn LINEAGE_90_TO_80(lineage)}'
    end

    if @pubid is not null
    begin
        select @pubidstr = '''' + convert(varchar(36), @pubid) + ''''
        if @tablenick > 0
        begin
            exec sys.sp_MSget_article_processing_order @tablenick, @pubid, @last_art_processing_order output
            select @last_art_processing_order_str = convert(varchar(12), @last_art_processing_order)
        end
    end

-- DEBUG    insert into MSmerge_debug
-- DEBUG        (okay, artnick, twhen, comment)
-- DEBUG        values (0, @tablenick, getdate(), 'sp_MSenumpartialdeletes; maxrows=' + convert(nvarchar, @maxrows) 
-- DEBUG        + ', startguid=' + convert(nchar(36), @rowguid) + ', bookmark=' + convert(nvarchar, @bookmark)
-- DEBUG        + ', specified_article_only=' + convert(nchar(1), @specified_article_only))

    if (@tablenick < 1)
    begin
		if OBJECT_ID('tempdb..' + @tablenotbelongs, N'U') is NULL return (1)

		if @pubid is null
			begin
				select @command = @selecttop + ' tablenick, rowguid, ' + @metadatacol + ', type, bookmark from ' + QUOTENAME(@tablenotbelongs) + '
						order by tablenick desc, rowguid asc'
				execute (@command)
			end
        else
			begin
				select @command = @selecttop + ' t.tablenick, t.rowguid, ' + @metadatacol2 + ', t.type, t.bookmark 
						from ' + QUOTENAME(@tablenotbelongs) + ' t, dbo.sysmergearticles sma
						where t.tablenick = sma.nickname
						and sma.pubid = ' + @pubidstr + '
						order by sma.processing_order desc, t.tablenick desc, t.rowguid asc'
				execute (@command)
			end
        IF @@ERROR <>0 
        begin
-- DEBUG    insert into MSmerge_debug (okay, twhen, comment)
-- DEBUG        values (1, getdate(), 'sp_MSenumpartialdeletes: select from notbelong failed')
            return (1)  
        end

-- DEBUG    execute ('insert into MSmerge_debug (okay, artnick, rowguid, generation_new, lineage_new, twhen, comment) ' +
-- DEBUG                @selecttop + ' 0, tablenick, rowguid, COALESCE (generation, 0), lineage, getdate(), ''sp_MSenumpartialdeletes'' 
-- DEBUG                from ' + @tablenotbelongs + ' order by tablenick desc, rowguid asc' )
    end
    else 
    begin
        set @tnstring = convert(nchar, @tablenick)
        if @rowguid is NULL or @rowguid = '00000000-0000-0000-0000-000000000000'
            select @rowguid_clause = ' '
        else
            select @rowguid_clause = ' and rowguid > ''' + convert(nchar(36), @rowguid) + ''' '

        /* 
        ** If a 7.0 SP1 Merge agent is calling this sp, it passed a valid bookmark parameter 
        ** Use the bookmark column in the ##belongs_<> table to retrieve the next batch of rows
        */
        if @bookmark is NOT NULL 
        begin
            set @lowrangestr = convert(nchar, @bookmark)
            set @highrangestr = convert(nchar, (@bookmark + @maxrows))

            if (@specified_article_only = 1)
            begin
				if OBJECT_ID('tempdb..' + @tablenotbelongs, N'U') is NULL return (1)

				-- don't rely on @highrangestr since it will be equal to @lowrangestr if @maxrows=0.
				select @command = @selecttop + ' tablenick, rowguid, ' + @metadatacol + ', type, bookmark from ' + QUOTENAME(@tablenotbelongs) + '
                            where  tablenick = ' + @tnstring + ' and 
                            bookmark > ' + @lowrangestr + ' 
                            order by tablenick, rowguid'
				execute (@command)
                if @@ERROR<>0
                begin
-- DEBUG            insert into MSmerge_debug (okay, twhen, comment)
-- DEBUG            values (2, getdate(), 'sp_MSenumpartialdeletes: select from notbelong failed')
                    return (1)
                end                     

-- DEBUG        execute ('insert into MSmerge_debug (okay, artnick, rowguid, generation_new, lineage_new, type, twhen, comment) ' + 
-- DEBUG                    @selecttop + ' 0, tablenick, rowguid, COALESCE (generation, 0), lineage, type, getdate(), ''sp_MSenumpartialdeletes: @specified_article_only = 1''
-- DEBUG                    from ' + @tablenotbelongs + '
-- DEBUG                    where  tablenick = ' + @tnstring + ' and 
-- DEBUG                    bookmark > ' + @lowrangestr + ' 
-- DEBUG                    order by rowguid' )

            end
            else
            begin
				if OBJECT_ID('tempdb..' + @tablenotbelongs, N'U') is NULL return (1)

                if @pubid is null
					begin
						select @command = 'select tablenick, rowguid, ' + @metadatacol + ', type, bookmark from ' + QUOTENAME(@tablenotbelongs) + '
								where  ((tablenick = ' + @tnstring + ' and 
								bookmark > ' + @lowrangestr + ' and bookmark <= ' + @highrangestr + ') or
								tablenick < ' + @tnstring + ') 
								order by tablenick desc, rowguid asc'
						execute (@command)
					end
                else
					begin
						select @command = 'select t.tablenick, t.rowguid, ' + @metadatacol2 + ', t.type, t.bookmark 
								from ' + QUOTENAME(@tablenotbelongs) + ' t, dbo.sysmergearticles sma
								where t.tablenick = sma.nickname
								and sma.pubid = ' + @pubidstr + '
								and
								(
									(t.tablenick = ' + @tnstring + ' and t.bookmark > ' + @lowrangestr + ' and t.bookmark <= ' + @highrangestr + ') or
									(sma.processing_order = ' + @last_art_processing_order_str + ' and t.tablenick < ' + @tnstring + ')  or
									sma.processing_order < ' + @last_art_processing_order_str + '
								)
								order by sma.processing_order desc, t.tablenick desc, t.rowguid asc'
						execute (@command)
					end
                if @@ERROR<>0
                begin
-- DEBUG            insert into MSmerge_debug (okay, twhen, comment)
-- DEBUG                values (3, getdate(), 'sp_MSenumpartialdeletes: select from notbelong failed')
                    return (1)
                end                     

-- DEBUG        execute ('insert into MSmerge_debug (okay, artnick, rowguid, generation_new, lineage_new, type, twhen, comment)
-- DEBUG                    select 0, tablenick, rowguid, COALESCE (generation, 0), lineage, type, getdate(), ''sp_MSenumpartialdeletes: @specified_article_only <> 1'' 
-- DEBUG                    from ' + @tablenotbelongs + '
-- DEBUG                    where  ((tablenick = ' + @tnstring + ' and 
-- DEBUG                    bookmark > ' + @lowrangestr + ' and bookmark <= ' + @highrangestr + ') or
-- DEBUG                    tablenick < ' + @tnstring + ') 
-- DEBUG                    order by tablenick desc, rowguid asc' )
            end
        end

        /* 
        ** Backward compatibilty mode : If a 7.0 Merge agent is calling this sp, it will pass a NULL bookmark parameter 
        ** Use the rowguid and set rowcount to retrieve the next batch of rows
        */
        else
        begin
            if (@specified_article_only = 1)
            begin
				if OBJECT_ID('tempdb..' + @tablenotbelongs, N'U') is NULL return (1)

                select @command = @selecttop + ' tablenick, rowguid, ' + @metadatacol + ', type from ' + QUOTENAME(@tablenotbelongs) + '
                            where  tablenick = ' + @tnstring + @rowguid_clause + '
                            order by tablenick, rowguid' 
				execute (@command)
                IF @@ERROR <>0 
                begin
-- DEBUG                insert into MSmerge_debug (okay, twhen, comment)
-- DEBUG                values (4, getdate(), 'sp_MSenumpartialdeletes: select from notbelong failed')
                    return (1)  
                end

-- DEBUG                execute ('insert into MSmerge_debug (okay, artnick, rowguid, generation_new, lineage_new, type, twhen, comment) ' + 
-- DEBUG                    @selecttop + ' 0, tablenick, rowguid, COALESCE (generation, 0), lineage, type, getdate(), ''sp_MSenumpartialdeletes: @specified_article_only = 0''
-- DEBUG                    from ' + @tablenotbelongs + '
-- DEBUG                    where  tablenick = ' + @tnstring + ' and 
-- DEBUG                    rowguid > ' + @rgstring + ' 
-- DEBUG                    order by rowguid' )
            end
            else
            begin
				if OBJECT_ID('tempdb..' + @tablenotbelongs, N'U') is NULL return (1)

                if @pubid is null
					begin
						select @command = @selecttop + ' tablenick, rowguid, ' + @metadatacol + ', type from ' + QUOTENAME(@tablenotbelongs) + '
								where  ((tablenick = ' + @tnstring + @rowguid_clause + ') or tablenick < ' + @tnstring + ') 
								order by tablenick desc, rowguid asc'
						execute (@command)
					end
                else
					begin
						select @command = @selecttop + ' t.tablenick, t.rowguid, ' + @metadatacol2 + ', t.type 
						        from ' + QUOTENAME(@tablenotbelongs) + ' t, dbo.sysmergearticles sma
						        where t.tablenick = sma.nickname
						        and sma.pubid = ' + @pubidstr + '
						        and
						        (
						            (tablenick = ' + @tnstring + @rowguid_clause + ') or 
						            (sma.processing_order = ' + @last_art_processing_order_str + ' and t.tablenick < ' + @tnstring + ')  or
						            sma.processing_order < ' + @last_art_processing_order_str + '
						        )

						        order by sma.processing_order desc, t.tablenick desc, t.rowguid asc'
						execute (@command)
					end
                IF @@ERROR <>0 
                begin
-- DEBUG                insert into MSmerge_debug (okay, twhen, comment)
-- DEBUG                values (5, getdate(), 'sp_MSenumpartialdeletes: select from notbelong failed')
                    return (1)  
                end

-- DEBUG                execute ('insert into MSmerge_debug (okay, artnick, rowguid, generation_new, lineage_new, type, twhen, comment) ' + 
-- DEBUG                    @selecttop + ' 0, tablenick, rowguid, COALESCE (generation, 0), lineage, type, getdate(), ''sp_MSenumpartialdeletes: @specified_article_only = 0''
-- DEBUG                    from ' + @tablenotbelongs + '
-- DEBUG                    where  ((tablenick = ' + @tnstring + ' and 
-- DEBUG                    rowguid > ' + @rgstring + ') or tablenick < ' + @tnstring + ')
-- DEBUG                    order by tablenick desc, rowguid asc' )
            end
        end
    end
    return (0)
GO
GRANT EXECUTE ON [sys].[sp_MSenumpartialdeletes] TO [public] AS [dbo]
GO
