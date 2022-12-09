SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSset_repl_serveroptions]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSset_repl_serveroptions] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSset_repl_serveroptions]
	@servername [sysname]
WITH EXECUTE AS CALLER
AS
BEGIN
	declare @retcode int

	exec @retcode = sp_serveroption @servername, 'rpc','true'
	IF @@error <> 0 OR @retcode <> 0
		return (1)

	exec @retcode = sp_serveroption @servername, 'rpc out','true'
	IF @@error <> 0 OR @retcode <> 0
		return (1)

	exec @retcode = sp_serveroption @servername, 'remote proc transaction promotion','false'
	IF @@error <> 0 OR @retcode <> 0
		return (1)

	exec @retcode = sp_serveroption @servername, 'data access','false'
	IF @@error <> 0 OR @retcode <> 0
		return (1)

	return (0)
END
GO
GRANT EXECUTE ON [sys].[sp_MSset_repl_serveroptions] TO [public] AS [dbo]
GO
