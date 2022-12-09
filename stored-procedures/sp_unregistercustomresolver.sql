SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_unregistercustomresolver]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_unregistercustomresolver] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_unregistercustomresolver]
	@article_resolver [nvarchar](255)
WITH EXECUTE AS CALLER
AS
declare @retcode  int
    
    exec @retcode = sys.sp_MSreplcheck_publish
    if (@retcode <> 0 or @@error <> 0)
        return 1

    -- check to make sure we are executing from the distribution database context
    if (sys.fn_MSrepl_isdistdb (db_name()) != 1)
    begin
        raiserror(21482, 16, -1, N'sp_unregistercustomresolver', N'distribution')
        return (1)
    end

    if @article_resolver IS NULL or @article_resolver = ''
    begin
        RAISERROR (21717, 16, -1)
        return 1
    end

    delete from dbo.MSmerge_articleresolver where article_resolver = LTRIM(RTRIM(@article_resolver))
    
    return @retcode
GO
GRANT EXECUTE ON [sys].[sp_unregistercustomresolver] TO [public] AS [dbo]
GO
