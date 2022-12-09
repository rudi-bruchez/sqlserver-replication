SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_droppublication]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_droppublication] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_droppublication]
	@publication [sysname],
	@ignore_distributor [bit],
	@publisher [sysname],
	@from_backup [bit]
WITH EXECUTE AS CALLER
AS
BEGIN
	DECLARE @cmd			nvarchar(4000)
	DECLARE @retcode		int
	DECLARE @publisher_type	sysname

	SET @retcode = 0
	
	EXEC @retcode = sys.sp_MSrepl_getpublisherinfo	@publisher		= @publisher,
													@rpcheader		= @cmd OUTPUT,
													@publisher_type	= @publisher_type OUTPUT
	
	IF @retcode <> 0
		RETURN (@retcode)

	-- Add sp
	SET @publisher = UPPER(@publisher) COLLATE DATABASE_DEFAULT
	set @cmd = @cmd + N'sys.sp_MSrepl_droppublication'

	EXEC @retcode = @cmd
					@publication,
					@ignore_distributor,
					@publisher,
					@publisher_type,
                    @from_backup

	RETURN (@retcode)
END
GO
GRANT EXECUTE ON [sys].[sp_droppublication] TO [public] AS [dbo]
GO
