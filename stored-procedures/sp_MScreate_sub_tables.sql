SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MScreate_sub_tables]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MScreate_sub_tables] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MScreate_sub_tables]
	@tran_sub_table [bit],
	@property_table [bit],
	@sqlqueue_table [bit],
	@subscription_articles_table [bit],
	@p2p_table [bit]
WITH EXECUTE AS CALLER
AS
BEGIN
    set nocount on
    declare @retcode int
    --
    -- security check
    --
    exec @retcode = sys.sp_MSreplcheck_subscribe 
    if @retcode <> 0 or @@error <> 0
        return 1
    --
    -- now invoke the internal routine
    --
    exec @retcode = sys.sp_MScreate_sub_tables_internal 
                            @tran_sub_table  = @tran_sub_table,
                            @property_table = @property_table,
                            @sqlqueue_table = @sqlqueue_table,
                            @subscription_articles_table = @subscription_articles_table,
                            @p2p_table = @p2p_table
    return @retcode
END
GO
GRANT EXECUTE ON [sys].[sp_MScreate_sub_tables] TO [public] AS [dbo]
GO
