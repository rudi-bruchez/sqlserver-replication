SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_marksubscriptionvalidation]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_marksubscriptionvalidation] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_marksubscriptionvalidation]
	@publication [sysname],
	@subscriber [sysname],
	@destination_db [sysname],
	@publisher [sysname]
WITH EXECUTE AS CALLER
AS
BEGIN
	DECLARE @cmd			nvarchar(4000)
	DECLARE @retcode		int
	DECLARE @publisher_type	sysname

	SET @retcode = 0
	
	/* 
    ** Security Check.
    */
    exec @retcode = sys.sp_MSreplcheck_publish
    if @@ERROR <> 0 or @retcode <> 0
        return(1)
	
	EXEC @retcode = sys.sp_MSrepl_getpublisherinfo	@publisher      = @publisher,
													@publisher_type	= @publisher_type OUTPUT,
													@rpcheader      = @cmd OUTPUT
	
	IF @retcode <> 0
		RETURN (@retcode)

	if (@publisher_type = 'MSSQLSERVER')
	begin
		
		set @cmd = @cmd + N'sys.sp_MSmarksubscriptionvalidation '
		EXEC @retcode = @cmd
				@publication,
				@subscriber,
				@destination_db
	end
	else
	begin
		-- Heterogeneous articles are handled directly
		SET @publisher = UPPER(@publisher) COLLATE DATABASE_DEFAULT
		set @cmd = @cmd + N'sys.sp_IHmarksubscriptionvalidation '
		EXEC @retcode = @cmd
				@publication,
				@subscriber,
				@destination_db,
				@publisher,
				@publisher_type
	end	

	RETURN (@retcode)
END
GO
GRANT EXECUTE ON [sys].[sp_marksubscriptionvalidation] TO [public] AS [dbo]
GO
