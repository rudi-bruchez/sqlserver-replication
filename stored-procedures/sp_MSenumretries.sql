SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSenumretries]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSenumretries] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSenumretries]
	@tname [nvarchar](126),
	@maxrows [int],
	@tablenick [int],
	@rowguid [uniqueidentifier],
	@pubid [uniqueidentifier]
WITH EXECUTE AS CALLER
AS
declare @tnstring nvarchar(12)
    declare @rgstring nvarchar(38)
    declare @retcode int
    declare @pubidstr varchar(38)
    declare @last_art_processing_order int
    declare @last_art_processing_order_str varchar(12)

    declare @quotedtname nvarchar(744) -- 386 * 2 + 2

    /*
    ** do permission checking
    */
    exec @retcode = sys.sp_MSrepl_PAL_rolecheck @tablenick = @tablenick
    if @retcode<>0 or @@ERROR<>0 return (1)

    /*
    ** Modify temp table, granted to public.
    */

    declare @selecttop nvarchar(50)

    select @quotedtname = quotename(@tname)

    if (@maxrows = 0)
        set @selecttop= 'select'
    else
        set @selecttop= 'select top ' + cast(@maxrows as nvarchar(9)) 
    
        if @pubid is null
        begin
                if (@tablenick < 1)
                begin
                execute (@selecttop + ' * from ' + @quotedtname + 
                                        ' order by tablenick, rowguidcol')
                        IF @@ERROR <>0 RETURN (1)        
                end
                else
                begin
                set @tnstring = convert(nchar, @tablenick)
                        set @rgstring = '''' + convert(nchar(36), @rowguid) + ''''
                        execute (@selecttop + ' * from ' + @quotedtname + 
                                        ' where (tablenick = ' + @tnstring + ' and  rowguidcol > ' + @rgstring + ') or
                                                tablenick > ' + @tnstring + ' order by tablenick, rowguidcol' )
                        if @@ERROR <> 0 RETURN (1)
                end
        end
        else
        begin
                select @pubidstr = '''' + convert(varchar(36), @pubid) + ''''
                if (@tablenick < 1)
                begin
                execute (@selecttop + ' t.* 
                                        from ' + @quotedtname + ' t, dbo.sysmergearticles sma 
                                        where sma.nickname = t.tablenick 
                                        and sma.pubid = ' + @pubidstr + '
                                        order by sma.processing_order, sma.nickname, t.rowguidcol')
                        IF @@ERROR <>0 RETURN (1)        
                end
                else
                begin
                set @tnstring = convert(nchar, @tablenick)
                        set @rgstring = '''' + convert(nchar(36), @rowguid) + ''''
                        exec sys.sp_MSget_article_processing_order @tablenick, @pubid, @last_art_processing_order output
                        select @last_art_processing_order_str = convert(varchar, @last_art_processing_order)

                        execute (@selecttop + ' t.* 
                                        from ' + @quotedtname + ' t, dbo.sysmergearticles sma
                                        where sma.nickname = t.tablenick
                                        and sma.pubid = ' + @pubidstr + '
                                        and 
                                        (
                                                (t.tablenick = ' + @tnstring + ' and  t.rowguidcol > ' + @rgstring + ') or
                                                (sma.processing_order = ' + @last_art_processing_order_str + ' and t.tablenick > ' + @tnstring + ') or
                                                sma.processing_order > ' + @last_art_processing_order_str + '
                                        )
                                        order by sma.processing_order, sma.nickname, t.rowguidcol' )
                        if @@ERROR <> 0 RETURN (1)
                end
        end

        return (0)  
GO
GRANT EXECUTE ON [sys].[sp_MSenumretries] TO [public] AS [dbo]
GO
