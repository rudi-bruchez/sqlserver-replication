SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_replincrementlsn]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_replincrementlsn] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_replincrementlsn]
	@xact_seqno [binary](10) OUTPUT,
	@publisher [sysname]
WITH EXECUTE AS CALLER
AS
declare @retcode int,
		@cmd nvarchar(4000)

	-- For SQL Server publisher, @publisher is NULL
	if @publisher IS NULL
	begin
			exec @retcode = sys.sp_MSrepl_incrementlsn @xact_seqno OUTPUT 
			if @@ERROR <> 0 or @retcode <> 0
		begin
				return (1)
		end
		return (0)
	end

	-- For heterogeneous publisher, make equivalent call in distribution database context
	EXEC @retcode = sys.sp_MSrepl_getpublisherinfo	@publisher	= @publisher,
							@rpcheader	= @cmd OUTPUT,
							@skipSecurityCheck	= 1
	
	IF @retcode <> 0
		RETURN (1)

	-- Add sp
	set @cmd = @cmd + N'sys.sp_IHreplincrementlsn'
	
	EXEC @retcode = @cmd	@xact_seqno OUTPUT,
				@publisher		

		if @@ERROR <> 0 or @retcode <> 0
	begin
			return (1)
	end
	return (0)
GO
GRANT EXECUTE ON [sys].[sp_replincrementlsn] TO [public] AS [dbo]
GO
