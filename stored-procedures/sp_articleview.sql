SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_articleview]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_articleview] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_articleview]
	@publication [sysname],
	@article [sysname],
	@view_name [nvarchar](386),
	@filter_clause [nvarchar](max),
	@change_active [int],
	@force_invalidate_snapshot [bit],
	@force_reinit_subscription [bit],
	@publisher [sysname],
	@refreshsynctranprocs [bit],
	@internal [bit]
WITH EXECUTE AS CALLER
AS
BEGIN
    set nocount on
    DECLARE @cmd            nvarchar(4000)
                ,@retcode        int
                ,@publisher_type    sysname

    if (@publisher is NULL)
    begin
        EXEC @retcode = sys.sp_MSrepl_articleview
                    @publication,
                    @article,
                    @view_name,
                    @filter_clause,
                    @change_active,
                    @force_invalidate_snapshot,
                    @force_reinit_subscription,
                    @refreshsynctranprocs,
                    @internal
    end
    else
    begin
        -- Heterogeneous articles are handled directly by sp_IHarticleview
        EXEC @retcode = sys.sp_MSrepl_getpublisherinfo   @publisher        = @publisher,
                                                                            @publisher_type    = @publisher_type OUTPUT,
                                                                            @rpcheader        = @cmd OUTPUT
        IF @retcode <> 0
            RETURN (@retcode)
            
        SET @publisher = UPPER(@publisher)
        
        set @cmd = @cmd + N'dbo.sp_IHarticleview '
        EXEC @retcode = @cmd
                    @publication,
                    @article,
                    @view_name,
                    @filter_clause,
                    @change_active,
                    @force_invalidate_snapshot,
                    @force_reinit_subscription,
                    @publisher,
                    @publisher_type
    end    

    RETURN (@retcode)
END
GO
GRANT EXECUTE ON [sys].[sp_articleview] TO [public] AS [dbo]
GO
