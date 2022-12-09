SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSchangearticleresolver]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSchangearticleresolver] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSchangearticleresolver]
	@article_resolver [nvarchar](255),
	@resolver_clsid [nvarchar](40),
	@artid [uniqueidentifier],
	@resolver_info [nvarchar](517)
WITH EXECUTE AS CALLER
AS
declare @retcode int
    -- Security check: dbo and sysadmin only
    exec @retcode = sys.sp_MSreplcheck_publish
    if @@error <> 0 or @retcode <> 0
    begin   
        return 1
    end

    if (@resolver_clsid='') select @resolver_clsid = NULL
    UPDATE dbo.sysmergearticles
        SET article_resolver = @article_resolver, resolver_clsid = @resolver_clsid, resolver_info = @resolver_info
        WHERE artid = @artid
    if @@ERROR <> 0 
        RETURN (1)
    return (0)     
GO
GRANT EXECUTE ON [sys].[sp_MSchangearticleresolver] TO [public] AS [dbo]
GO
