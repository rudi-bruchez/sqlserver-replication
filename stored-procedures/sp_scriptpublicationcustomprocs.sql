SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_scriptpublicationcustomprocs]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_scriptpublicationcustomprocs] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_scriptpublicationcustomprocs]
	@publication [sysname],
	@publisher [sysname],
	@usesqlclr [bit]
WITH EXECUTE AS CALLER
AS
BEGIN
	DECLARE @cmd			nvarchar(4000)
	DECLARE @retcode		int
	DECLARE @publisher_type	sysname

	SET @retcode = 0
	
	EXEC @retcode = sys.sp_MSrepl_getpublisherinfo	@publisher		= @publisher,
													@rpcheader		= @cmd            OUTPUT,
													@publisher_type	= @publisher_type OUTPUT
	
	IF @retcode <> 0
		RETURN (@retcode)

	-- Add sp
	SET @publisher = UPPER(@publisher) COLLATE DATABASE_DEFAULT
	set @cmd = @cmd + N'sys.sp_MSrepl_scriptpublicationcustomprocs'
	
	EXEC @retcode = @cmd
					@publication,
					@publisher,
					@publisher_type,
                    @usesqlclr

	RETURN (@retcode)
END


raiserror('Creating procedure sp_MSrepl_scriptpublicationcustomprocs',0,-1) with nowait
GO
GRANT EXECUTE ON [sys].[sp_scriptpublicationcustomprocs] TO [public] AS [dbo]
GO
