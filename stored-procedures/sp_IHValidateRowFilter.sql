SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_IHValidateRowFilter]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_IHValidateRowFilter] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_IHValidateRowFilter]
	@publisher [sysname],
	@owner [sysname],
	@table [sysname],
	@columnmask [binary](128),
	@rowfilter [nvarchar](max)
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

	--
	-- Parameter Check: columnlist and rowfilter must be non-NULL
	--
	if ( @rowfilter IS NULL)
	BEGIN
		RAISERROR (21784, 16, -1)
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

	set @cmd = @cmd + N'sys.sp_ORAValidateRowFilter'
	
	EXEC @retcode = @cmd	@publisher,
				@owner,
				@table,
				@columnmask,
				@rowfilter,
				@publisher_type
	RETURN (@retcode)
END
GO
GRANT EXECUTE ON [sys].[sp_IHValidateRowFilter] TO [public] AS [dbo]
GO
