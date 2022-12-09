SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_getsubscription_status_hsnapshot]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_getsubscription_status_hsnapshot] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_getsubscription_status_hsnapshot]
	@publication [sysname],
	@article [sysname],
	@publisher [sysname]
WITH EXECUTE AS CALLER
AS
BEGIN
	DECLARE @cmd			nvarchar(4000)
	DECLARE @retcode		int
	DECLARE @publisher_type	sysname

	SET @retcode = 0

    EXEC @retcode = sys.sp_MSrepl_getpublisherinfo
        @publisher = @publisher,
        @publisher_type = @publisher_type OUTPUT,
        @rpcheader = @cmd OUTPUT,
        @skipSecurityCheck	= 1

    IF @retcode <> 0
        RETURN (@retcode)

    -- This procedue is only to be used with heterogeneous publishers    
    IF @publisher_type = N'MSSQLSERVER'
    BEGIN
        RAISERROR (21659, 16, -1)
        RETURN (1)
    END

	SET @publisher = UPPER(@publisher) COLLATE DATABASE_DEFAULT
    set @cmd = @cmd + N'sys.sp_MSrepl_getsubscription_status_hsnapshot'
	
    EXEC @retcode = @cmd
        @publication,
        @article,
        @publisher

	RETURN (@retcode)
END
GO
GRANT EXECUTE ON [sys].[sp_getsubscription_status_hsnapshot] TO [public] AS [dbo]
GO
