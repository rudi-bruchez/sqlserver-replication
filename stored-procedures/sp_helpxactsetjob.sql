SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_helpxactsetjob]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_helpxactsetjob] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_helpxactsetjob]
	@publisher [sysname]
WITH EXECUTE AS CALLER
AS
BEGIN
	DECLARE @cmd			nvarchar(4000)
	DECLARE @retcode		int
	DECLARE @publisher_type	sysname

	-- Security Check
    IF IS_SRVROLEMEMBER ('sysadmin') != 1
    BEGIN
    	-- "Only members of the sysadmin fixed server role can perform this operation."
        RAISERROR(21089,16,-1)
        RETURN 1
    END
    
	SET @retcode = 0

	EXEC @retcode = sys.sp_MSrepl_getpublisherinfo	@publisher		= @publisher,
													@rpcheader		= @cmd OUTPUT,
													@publisher_type	= @publisher_type OUTPUT,
													@hreplOnly		= 1
	
	IF @retcode <> 0
		RETURN (@retcode)

	-- Error if the publisher is not a heterogeneous publisher
	IF @publisher_type NOT LIKE 'ORACLE%'
	BEGIN
		RAISERROR (21696, 16, -1, @publisher, @publisher_type)
    	RETURN (1)
	END

	SET @publisher = UPPER(@publisher) COLLATE DATABASE_DEFAULT
	set @cmd = @cmd + N'sys.sp_ORAhelpXactSetJob'
	
	EXEC @retcode = @cmd	@publisher
	RETURN (@retcode)
END
GO
GRANT EXECUTE ON [sys].[sp_helpxactsetjob] TO [public] AS [dbo]
GO
