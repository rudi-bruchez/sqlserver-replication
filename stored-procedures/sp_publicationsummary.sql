SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_publicationsummary]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_publicationsummary] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_publicationsummary]
	@publication [sysname],
	@publisher [sysname]
WITH EXECUTE AS CALLER
AS
BEGIN
	DECLARE	@cmd			nvarchar(4000),
			@retcode		int,
			@publisher_type	sysname

	EXEC @retcode = sys.sp_MSrepl_getpublisherinfo	@publisher		= @publisher,
													@rpcheader		= @cmd OUTPUT,
													@publisher_type	= @publisher_type OUTPUT
	
	IF @retcode <> 0
	BEGIN
		RETURN (@retcode)
	END

	select @publisher = UPPER(@publisher)
				,@cmd = @cmd + N'sys.sp_MSrepl_publicationsummary'
	
	EXEC @retcode = @cmd
					@publication,
					@publisher,
					@publisher_type

	RETURN (@retcode)
END
GO
GRANT EXECUTE ON [sys].[sp_publicationsummary] TO [public] AS [dbo]
GO
