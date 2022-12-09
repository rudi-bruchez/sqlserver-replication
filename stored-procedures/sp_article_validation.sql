SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_article_validation]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_article_validation] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_article_validation]
	@publication [sysname],
	@article [sysname],
	@rowcount_only [smallint],
	@full_or_fast [tinyint],
	@shutdown_agent [bit],
	@subscription_level [bit],
	@reserved [int],
	@publisher [sysname]
WITH EXECUTE AS CALLER
AS
BEGIN
	DECLARE @cmd			nvarchar(4000)
	DECLARE @retcode		int
	DECLARE @publisher_type	sysname

	SET @retcode = 0
	
	EXEC @retcode = sys.sp_MSrepl_getpublisherinfo	@publisher      = @publisher,
													@publisher_type	= @publisher_type OUTPUT,
													@rpcheader      = @cmd OUTPUT
	
	IF @retcode <> 0
		RETURN (@retcode)

	if (@publisher_type = 'MSSQLSERVER')
	begin
		set @cmd = @cmd + N'sys.sp_MSarticle_validation '
		EXEC @retcode = @cmd
					@publication,
					@article,
					@rowcount_only,
					@full_or_fast,
					@shutdown_agent,
					@subscription_level,
					@reserved
	end
	else
	begin
		-- Heterogeneous articles are handled directly by sp_IHarticle_validation
		SET @publisher = UPPER(@publisher) COLLATE DATABASE_DEFAULT
		set @cmd = @cmd + N'sys.sp_IHarticle_validation '

		EXEC @retcode = @cmd
					@publication,
					@article,
					@rowcount_only,
					@full_or_fast,
					@shutdown_agent,
					@subscription_level,
					@reserved,
					@publisher,
					@publisher_type
	end	

	RETURN (@retcode)
END
GO
GRANT EXECUTE ON [sys].[sp_article_validation] TO [public] AS [dbo]
GO
