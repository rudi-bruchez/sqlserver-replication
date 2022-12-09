SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_setOraclepackageversion]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_setOraclepackageversion] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_setOraclepackageversion]
	@publisher [sysname]
WITH EXECUTE AS CALLER
AS
BEGIN
    set nocount on
    DECLARE @cmd nvarchar(4000)
                ,@retcode int
                ,@publisher_type sysname

    EXEC @retcode = sys.sp_MSrepl_getpublisherinfo
        @publisher        = @publisher,
        @rpcheader        = @cmd OUTPUT,
        @publisher_type   = @publisher_type OUTPUT
    IF @retcode <> 0
        RETURN (@retcode)

    -- Reject unsupported publisher types
    IF @publisher_type NOT IN (N'ORACLE', N'ORACLE GATEWAY')
    BEGIN
        RAISERROR (21645, 16, -1, @publisher_type)
        RETURN (1)
    END                                                                     

    SELECT @publisher = UPPER(@publisher) 
            ,@cmd = @cmd + N'sys.sp_MSrepl_setOraclepackageversion'
    
    EXEC @retcode = @cmd
                    @publisher

    RETURN (@retcode)
END
GO
GRANT EXECUTE ON [sys].[sp_setOraclepackageversion] TO [public] AS [dbo]
GO
