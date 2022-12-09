SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_IHXactSetJob]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_IHXactSetJob] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_IHXactSetJob]
	@publisher [sysname],
	@enabled [bit],
	@interval [int],
	@threshold [int],
	@LRinterval [int],
	@LRthreshold [int]
WITH EXECUTE AS CALLER
AS
BEGIN
	DECLARE @cmd			nvarchar(4000)
	DECLARE @retcode		int
	DECLARE @publisher_type	sysname

	--
	-- Security Check: require sysadmin
	--
	IF (ISNULL(IS_SRVROLEMEMBER('sysadmin'),0) = 0)
	BEGIN
		RAISERROR(21089,16,-1) 
		RETURN (1)
	END

	SET @retcode = 0

	EXEC @retcode = sys.sp_MSrepl_getpublisherinfo	@publisher		= @publisher,
													@rpcheader		= @cmd OUTPUT,
													@publisher_type	= @publisher_type OUTPUT,
													@hreplOnly		= 1
	
	IF @retcode <> 0
		RETURN (@retcode)

	-- Error if the publisher is not an Oracle publisher
	IF @publisher_type NOT LIKE 'ORACLE%'
	BEGIN
		RAISERROR (21696, 16, -1, @publisher, @publisher_type)
    		RETURN (1)
	END

	set @cmd = @cmd + N'sys.sp_ORAXactSetJob'
	
	EXEC @retcode = @cmd	@publisher,
				@enabled,
				@interval,
				@threshold,
				@LRinterval,
				@LRthreshold
	RETURN (@retcode)
END
GO
GRANT EXECUTE ON [sys].[sp_IHXactSetJob] TO [public] AS [dbo]
GO
