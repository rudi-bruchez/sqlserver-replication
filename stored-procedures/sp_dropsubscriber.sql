SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_dropsubscriber]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_dropsubscriber] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_dropsubscriber]
	@subscriber [sysname],
	@reserved [nvarchar](50),
	@ignore_distributor [bit],
	@publisher [sysname]
WITH EXECUTE AS CALLER
AS
BEGIN
	DECLARE @cmd		nvarchar(4000)
	DECLARE @retcode	int

	SET @retcode = 0
	
	-- Security Check: require sysadmin
	IF (ISNULL(IS_SRVROLEMEMBER('sysadmin'),0) = 0)
	BEGIN
		RAISERROR(21089,16,-1) 
		RETURN (1)
	END
	
	EXEC @retcode = sys.sp_MSrepl_getpublisherinfo	@publisher		= @publisher,
													@rpcheader		= @cmd OUTPUT
	
	IF @retcode <> 0
		RETURN (@retcode)

	-- Add sp
	SET @publisher = UPPER(@publisher) COLLATE DATABASE_DEFAULT
	set @cmd = @cmd + N'sys.sp_MSrepl_dropsubscriber'

	EXEC @retcode = @cmd
					@subscriber,
					@reserved,
					@ignore_distributor,
					@publisher

	RETURN (@retcode)
END
GO
GRANT EXECUTE ON [sys].[sp_dropsubscriber] TO [public] AS [dbo]
GO
