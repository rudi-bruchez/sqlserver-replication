SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_articlefilter]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_articlefilter] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_articlefilter]
	@publication [sysname],
	@article [sysname],
	@filter_name [nvarchar](517),
	@filter_clause [nvarchar](max),
	@force_invalidate_snapshot [bit],
	@force_reinit_subscription [bit],
	@publisher [sysname]
WITH EXECUTE AS CALLER
AS
BEGIN
    DECLARE @cmd            nvarchar(4000)
                ,@retcode        int
                ,@publisher_type    sysname


    EXEC @retcode = sys.sp_MSrepl_getpublisherinfo    @publisher        = @publisher,
                                                    @publisher_type    = @publisher_type OUTPUT,
                                                    @rpcheader        = @cmd OUTPUT
    IF @retcode <> 0
        RETURN (@retcode)

    IF @publisher IS NULL
        select @publisher = publishingservername()

    -- Add sp
    select @publisher = UPPER(@publisher)
            ,@cmd = @cmd + N'sys.sp_MSrepl_articlefilter'
    
    EXEC @retcode = @cmd
                    @publication,
                    @article,
                    @filter_name,
                    @filter_clause,
                    @force_invalidate_snapshot,
                    @force_reinit_subscription,
                    @publisher,
                    @publisher_type

    RETURN (@retcode)
END
GO
GRANT EXECUTE ON [sys].[sp_articlefilter] TO [public] AS [dbo]
GO
