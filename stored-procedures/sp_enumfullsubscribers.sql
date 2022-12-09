SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_enumfullsubscribers]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_enumfullsubscribers] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_enumfullsubscribers]
	@publication [sysname],
	@publisher [sysname]
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
	set @cmd = @cmd + N'sys.sp_MSrepl_enumfullsubscribers'
	
	EXEC @retcode = @cmd
					@publication,
					@publisher,
					@publisher_type

	RETURN (@retcode)
END

--
-- Name: sp_MSrepl_enumfullsubscribers
--
-- Descriptions: 
--
-- Parameters: as defined in create statement
--
-- Returns: 0 - success
--          1 - Otherwise
--
-- Security: Public - publish check
-- Requires Certificate signature for catalog access
--
raiserror(15339,-1,-1,'sp_MSrepl_enumfullsubscribers')
GO
GRANT EXECUTE ON [sys].[sp_enumfullsubscribers] TO [public] AS [dbo]
GO
