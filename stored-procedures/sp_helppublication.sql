SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_helppublication]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_helppublication] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_helppublication]
	@publication [sysname],
	@found [int] OUTPUT,
	@publisher [sysname]
WITH EXECUTE AS CALLER
AS
BEGIN
    SET NOCOUNT ON
    DECLARE @cmd nvarchar(4000)
                ,@retcode int
                ,@publisher_type sysname

    EXEC @retcode = sys.sp_MSrepl_getpublisherinfo
                                            @publisher = @publisher,
                                            @publisher_type = @publisher_type OUTPUT,
                                            @rpcheader = @cmd OUTPUT,
                                            @skipSecurityCheck = 1
    IF @retcode <> 0
        RETURN (@retcode)

    SELECT   @publisher = UPPER(@publisher)
                ,@cmd = case when (@publisher_type = N'MSSQLSERVER') 
                            then @cmd + N'sys.sp_MSrepl_helppublication' 
                            else @cmd + N'sys.sp_IHhelppublication' end
    EXEC @retcode = @cmd
                                @publication,
                                @found OUTPUT,
                                @publisher,
                                @publisher_type
    RETURN (@retcode)
END
GO
GRANT EXECUTE ON [sys].[sp_helppublication] TO [public] AS [dbo]
GO
