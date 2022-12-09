SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_reinitsubscription]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_reinitsubscription] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_reinitsubscription]
	@publication [sysname],
	@article [sysname],
	@subscriber [sysname],
	@destination_db [sysname],
	@for_schema_change [bit],
	@publisher [sysname],
	@ignore_distributor_failure [bit],
	@invalidate_snapshot [bit]
WITH EXECUTE AS CALLER
AS
BEGIN
	DECLARE @cmd			nvarchar(4000)
	DECLARE @retcode		int
	DECLARE @distributor	sysname
	DECLARE @distribdb		sysname
	DECLARE @publisher_type	sysname

    SET NOCOUNT ON

	SET @retcode = 0
	
	EXEC @retcode = sys.sp_MSrepl_getpublisherinfo	@publisher			= @publisher,
													@rpcheader			= @cmd OUTPUT,
													@publisher_type		= @publisher_type OUTPUT,
													@skipSecurityCheck	= 1
	
	IF @retcode <> 0
		RETURN (@retcode)

	-- Add sp
	SET @publisher = UPPER(@publisher) COLLATE DATABASE_DEFAULT
	set @cmd = @cmd + N'sys.sp_MSrepl_reinitsubscription'

	-- Get distributor info
    EXEC @retcode = sys.sp_MSrepl_getdistributorinfo	@publisher		= @publisher,
											@rpcsrvname		= @distributor OUTPUT,
											@distribdb		= @distribdb OUTPUT

    IF (@retcode <> 0 OR @@ERROR <> 0 OR @distribdb IS NULL or @distributor IS NULL) and @ignore_distributor_failure = 0
    BEGIN
        RAISERROR (14071, 16, -1)
        RETURN (1)
    END

	EXEC @retcode = @cmd
					@publication,
					@article,
					@subscriber,
					@destination_db,
					@for_schema_change,
					@distributor,
					@distribdb,
					@publisher,
					@publisher_type,
					@ignore_distributor_failure,
					@invalidate_snapshot

	RETURN (@retcode)
END
GO
GRANT EXECUTE ON [sys].[sp_reinitsubscription] TO [public] AS [dbo]
GO
