SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_addscriptexec]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_addscriptexec] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_addscriptexec]
	@publication [sysname],
	@scriptfile [nvarchar](4000),
	@skiperror [bit],
	@publisher [sysname]
WITH EXECUTE AS CALLER
AS
BEGIN
    DECLARE @cmd        nvarchar(4000)
    DECLARE @retcode    int

    SET @retcode = 0
    
    EXEC @retcode = sys.sp_MSrepl_getpublisherinfo    @publisher    = @publisher,
                                                    @rpcheader    = @cmd OUTPUT
    
    IF @retcode <> 0
        RETURN (@retcode)

    -- Add sp
	SET @publisher = UPPER(@publisher) COLLATE DATABASE_DEFAULT
    set @cmd = @cmd + N'sys.sp_MSrepl_addscriptexec'

    EXEC @retcode = @cmd
                    @publication,
                    @scriptfile,
                    @skiperror

    RETURN (@retcode)
END
GO
GRANT EXECUTE ON [sys].[sp_addscriptexec] TO [public] AS [dbo]
GO
