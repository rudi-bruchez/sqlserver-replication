SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_articlecolumn]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_articlecolumn] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_articlecolumn]
	@publication [sysname],
	@article [sysname],
	@column [sysname],
	@operation [nvarchar](5),
	@refresh_synctran_procs [bit],
	@ignore_distributor [bit],
	@change_active [int],
	@force_invalidate_snapshot [bit],
	@force_reinit_subscription [bit],
	@publisher [sysname],
	@internal [bit]
WITH EXECUTE AS CALLER
AS
BEGIN
	DECLARE @cmd			nvarchar(4000)
	DECLARE @cmd2			nvarchar(4000)
	DECLARE @retcode		int
	DECLARE	@publisher_type	sysname
	DECLARE	@publisher_dbms	sysname
	DECLARE	@publisher_version sysname
	
	SET @retcode = 0
	
	EXEC @retcode = sys.sp_MSrepl_getpublisherinfo	@publisher		= @publisher,
													@rpcheader		= @cmd OUTPUT,
													@publisher_type	= @publisher_type OUTPUT
	
	IF @retcode <> 0
		RETURN (@retcode)
		
	SET @publisher = UPPER(@publisher) COLLATE DATABASE_DEFAULT

	IF @publisher_type = N'MSSQLSERVER'
	BEGIN	
		-- Add sp
		set @cmd = @cmd + N'sys.sp_MSrepl_articlecolumn'
	
		EXEC @retcode = @cmd
					@publication,
					@article,
					@column,
					@operation,
					@refresh_synctran_procs,
					@ignore_distributor,
					@change_active,
					@force_invalidate_snapshot,
					@force_reinit_subscription,
					@internal
	END
	ELSE
	BEGIN

		-- Set publisher DBMS and version (for getting default data type mapping)
		SELECT	@publisher_dbms		= 'ORACLE'

		set @cmd2 = @cmd + N'sys.sp_IHgetversion'
		EXEC @retcode = @cmd2
					@publisher	= @publisher,
					@version	= @publisher_version OUTPUT

		IF @retcode != 0 OR @@ERROR != 0
		BEGIN
		    RETURN (1)
		END

		-- Add sp
		set @cmd2 = @cmd + N'sys.sp_IHarticlecolumn'
	
		EXEC @retcode = @cmd2
					@publication,
					@article,
					@column,
					@operation,
					@refresh_synctran_procs,
					@ignore_distributor,
					@change_active,
					@force_invalidate_snapshot,
					@force_reinit_subscription,
					@publisher,
					@publisher_type,
					@publisher_dbms,
					@publisher_version

	END

	RETURN (@retcode)
END
GO
GRANT EXECUTE ON [sys].[sp_articlecolumn] TO [public] AS [dbo]
GO
