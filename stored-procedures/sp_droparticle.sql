SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_droparticle]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_droparticle] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_droparticle]
	@publication [sysname],
	@article [sysname],
	@ignore_distributor [bit],
	@force_invalidate_snapshot [bit],
	@publisher [sysname],
	@from_drop_publication [bit]
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
	set @cmd = @cmd + N'sys.sp_MSrepl_droparticle'
	
	EXEC @retcode = @cmd
					@publication,
					@article,
					@ignore_distributor,
					@force_invalidate_snapshot,
					@publisher,
					@from_drop_publication,
					@publisher_type

	RETURN (@retcode)
END
GO
GRANT EXECUTE ON [sys].[sp_droparticle] TO [public] AS [dbo]
GO
