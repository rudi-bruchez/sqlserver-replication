SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSrepl_setNFR]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSrepl_setNFR] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSrepl_setNFR]
	@schema [sysname],
	@object_name [sysname]
WITH EXECUTE AS CALLER
AS
BEGIN
	DECLARE @retcode	int,
			@fkid		int

	-- security check for subscriber
	EXEC @retcode = sys.sp_MSreplcheck_subscribe 
    IF @@ERROR <> 0 OR @retcode <> 0 
    BEGIN
        RETURN 1
    END
	
	DECLARE #hForeignKeys CURSOR LOCAL FAST_FORWARD FOR
		SELECT object_id
			FROM sys.foreign_keys
			WHERE is_not_for_replication = 0
				AND referenced_object_id = OBJECT_ID(QUOTENAME(@schema) + '.' + QUOTENAME(@object_name))
			ORDER BY object_id
			
	OPEN #hForeignKeys

	FETCH #hForeignKeys INTO @fkid

	WHILE @@FETCH_STATUS != -1
	BEGIN
		EXEC %%Object(ID = @fkid).SetConstraintNotForRepl(Value = 1)
		IF @@ERROR <> 0
			RETURN 1

		FETCH #hForeignKeys INTO @fkid
	END

	CLOSE #hForeignKeys

	RETURN 0
END
GO
GRANT EXECUTE ON [sys].[sp_MSrepl_setNFR] TO [public] AS [dbo]
GO
