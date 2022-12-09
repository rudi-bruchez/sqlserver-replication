SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSrepl_isdbowner]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSrepl_isdbowner] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSrepl_isdbowner]
	@dbname [sysname]
WITH EXECUTE AS CALLER
AS
BEGIN
    SET NOCOUNT ON
    DECLARE @retcode int
    DECLARE @cmd      nvarchar(1000)
    DECLARE @isdbowner int

    SELECT @retcode = has_dbaccess(@dbname)
    IF (@retcode IS NULL) OR (@retcode = 0)
    BEGIN
        /* 
        ** Either no access or database not found 
        ** No need to go further
        */
        RETURN 0
    END

    SELECT @cmd = 'USE ' + quotename(@dbname) + ' SELECT @isdbowner = is_member(''db_owner'')'
    EXEC sys.sp_executesql @cmd, N'@isdbowner int output', @isdbowner output

    RETURN isnull(@isdbowner, 0)
END
GO
GRANT EXECUTE ON [sys].[sp_MSrepl_isdbowner] TO [public] AS [dbo]
GO
