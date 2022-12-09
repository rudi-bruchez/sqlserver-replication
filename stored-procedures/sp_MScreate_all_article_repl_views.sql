SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MScreate_all_article_repl_views]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MScreate_all_article_repl_views] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MScreate_all_article_repl_views]
	@snapshot_application_finished [bit]
WITH EXECUTE AS CALLER
AS
declare @pubid uniqueidentifier, @artid uniqueidentifier, @retcode int

    -- security check
    exec @retcode = sys.sp_MSreplcheck_subscribe
    if @retcode<>0 or @@ERROR<>0
        return 1
    
    select @retcode = 0
    
    if object_id('sysmergesubsetfilters','U') is NULL
        return 0
    
    declare artidpubid CURSOR LOCAL FAST_FORWARD FOR 
    select artid, pubid from dbo.sysmergearticles 
    FOR READ ONLY
    
    open artidpubid
    
    fetch artidpubid into @artid, @pubid

    while (@@fetch_status <> -1)
    begin
    
        exec @retcode = sys.sp_MScreate_article_repl_view @pubid, @artid
        if @@ERROR<>0 OR @retcode<>0 
        begin
            select @retcode = 1
            goto error
        end
        
        fetch next from artidpubid into @artid, @pubid
    end

    if @snapshot_application_finished = 1
    begin
        -- potentially there can be other post snapshot steps that can be done here
        execute @retcode= sys.sp_MSrepl_ddl_triggers @type='merge', @mode='add'
        if @@ERROR <> 0 or @retcode <> 0 
        begin
            select @retcode = 1
            goto error
        end
    end

error:
    close artidpubid
    deallocate artidpubid
    return @retcode
GO
GRANT EXECUTE ON [sys].[sp_MScreate_all_article_repl_views] TO [public] AS [dbo]
GO
