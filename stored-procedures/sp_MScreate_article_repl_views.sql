SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MScreate_article_repl_views]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MScreate_article_repl_views] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MScreate_article_repl_views]
	@publication [sysname]
WITH EXECUTE AS CALLER
AS
declare @pubid uniqueidentifier, @artid uniqueidentifier, @retcode int

    -- security check
    exec @retcode = sys.sp_MSreplcheck_publish
    if @retcode<>0 or @@ERROR<>0
        return 1
    
    select @retcode = 0

    exec @retcode = sys.sp_MSmerge_validate_publication_presence @publication, NULL, NULL, @pubid output
    if @retcode <> 0 or @@error <> 0
        return 1    
        
    declare artidcursor CURSOR LOCAL FAST_FORWARD FOR 
    select artid from dbo.sysmergearticles where pubid = @pubid
    FOR READ ONLY
    
    open artidcursor
    fetch artidcursor into @artid
    while (@@fetch_status <> -1)
    begin
    
        exec @retcode = sys.sp_MScreate_article_repl_view @pubid, @artid
        if @@ERROR<>0 OR @retcode<>0 
        begin
            select @retcode = 1
            goto error
        end
        
        fetch next from artidcursor into @artid
    end

error:
    close artidcursor
    deallocate artidcursor
    return @retcode
GO
GRANT EXECUTE ON [sys].[sp_MScreate_article_repl_views] TO [public] AS [dbo]
GO
