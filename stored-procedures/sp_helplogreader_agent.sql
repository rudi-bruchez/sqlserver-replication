SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_helplogreader_agent]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_helplogreader_agent] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_helplogreader_agent]
	@publisher [sysname]
WITH EXECUTE AS CALLER
AS
BEGIN
	DECLARE @cmd			nvarchar(4000)
	DECLARE @retcode		int
	DECLARE @publisher_type	sysname
	
	SET @retcode = 0
	
	EXEC @retcode = sys.sp_MSrepl_getpublisherinfo	@publisher		= @publisher,
													@publisher_type = @publisher_type OUTPUT,
													@rpcheader		= @cmd OUTPUT

	IF @retcode <> 0
		RETURN (@retcode)

	-- Add sp
	SET @publisher = UPPER(@publisher) COLLATE DATABASE_DEFAULT
	set @cmd = @cmd + N'sys.sp_MSrepl_helplogreader_agent'

	EXEC @retcode = @cmd	@publisher 		= @publisher,
							@publisher_type = @publisher_type

	RETURN (@retcode)
END
GO
GRANT EXECUTE ON [sys].[sp_helplogreader_agent] TO [public] AS [dbo]
GO
