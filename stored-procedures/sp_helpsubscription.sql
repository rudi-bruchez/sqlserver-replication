SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_helpsubscription]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_helpsubscription] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_helpsubscription]
	@publication [sysname],
	@article [sysname],
	@subscriber [sysname],
	@destination_db [sysname],
	@found [int] OUTPUT,
	@publisher [sysname]
WITH EXECUTE AS CALLER
AS
BEGIN
	DECLARE @cmd			nvarchar(4000)
	DECLARE @retcode		int
	DECLARE @publisher_type	sysname

	SET @retcode = 0

    EXEC @retcode = sys.sp_MSrepl_getpublisherinfo	@publisher			= @publisher,
													@publisher_type		= @publisher_type OUTPUT,
													@rpcheader			= @cmd OUTPUT,
													@skipSecurityCheck	= 1

    IF @retcode <> 0
        RETURN (@retcode)

	SET @publisher = UPPER(@publisher) COLLATE DATABASE_DEFAULT
    set @cmd = @cmd + N'sys.sp_MSrepl_helpsubscription'
	
    EXEC @retcode = @cmd
					@publication,
					@article,
					@subscriber,
					@destination_db,
					@found OUTPUT,
					@publisher,
					@publisher_type

	RETURN (@retcode)
END
GO
GRANT EXECUTE ON [sys].[sp_helpsubscription] TO [public] AS [dbo]
GO
