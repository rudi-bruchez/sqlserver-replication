SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_publication_validation]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_publication_validation] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_publication_validation]
	@publication [sysname],
	@rowcount_only [smallint],
	@full_or_fast [tinyint],
	@shutdown_agent [bit],
	@publisher [sysname]
WITH EXECUTE AS CALLER
AS
BEGIN
	DECLARE @cmd			nvarchar(4000)
	DECLARE @retcode		int
	DECLARE @publisher_type	sysname

	SET @retcode = 0

	
	-- Security Check
	-- No reason anyone but Sysadmin or dbo of publishing db should run this
	exec @retcode = sys.sp_MSreplcheck_publish
	if @@error <> 0 or @retcode <> 0
	begin
		return (1)
	end
	
	EXEC @retcode = sys.sp_MSrepl_getpublisherinfo	@publisher      = @publisher,
													@publisher_type	= @publisher_type OUTPUT,
													@rpcheader      = @cmd OUTPUT
	
	IF @retcode <> 0
		RETURN (@retcode)

	if (@publisher_type = 'MSSQLSERVER')
	begin
		
		SET @cmd = @cmd + N'dbo.sp_MSpublication_validation '

		EXEC @retcode = @cmd
				@publication,
				@rowcount_only,
				@full_or_fast,
				@shutdown_agent
					
	end
	else
	begin
		-- Heterogeneous articles are handled directly by sp_IHpublication_validation
		SET @publisher = UPPER(@publisher) COLLATE DATABASE_DEFAULT
		set @cmd = @cmd + N'sys.sp_IHpublication_validation '

		EXEC @retcode = @cmd
				@publication,
				@rowcount_only,
				@full_or_fast,
				@shutdown_agent,
				@publisher
	end	

	RETURN (@retcode)
END
GO
GRANT EXECUTE ON [sys].[sp_publication_validation] TO [public] AS [dbo]
GO
