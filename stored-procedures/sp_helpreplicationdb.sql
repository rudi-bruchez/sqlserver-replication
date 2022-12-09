SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_helpreplicationdb]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_helpreplicationdb] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_helpreplicationdb]
	@dbname [sysname],
	@type [sysname]
WITH EXECUTE AS CALLER
AS
SET NOCOUNT ON

	/*
	** Declarations.
	*/

	DECLARE @retcode int, @typebit int

	if (lower(@type collate SQL_Latin1_General_CP1_CS_AS) like 'pub%')
	   select @typebit = 1
	else if (lower(@type collate SQL_Latin1_General_CP1_CS_AS) like 'sub%')
	   select @typebit = 2
	else
	begin
	   raiserror(14091,-1,-1)
	   return 1
	end

	/*
	** Parameter Check:  @dbname.
	** Check to make sure that the database name conforms to the rules
	** for identifiers.
	*/

	IF @dbname <> '%'
	   BEGIN
		  EXECUTE @retcode = sys.sp_validname @dbname

		  IF @@ERROR <> 0 OR @retcode <> 0
		  RETURN (1)
	   END

	/*
	** Show databases with this option enabled.
	*/

	SELECT name
	  FROM master.dbo.sysdatabases
	 WHERE ((@dbname = N'%') or (name = @dbname collate database_default)) 
	   AND (category & @typebit) <> 0
GO
GRANT EXECUTE ON [sys].[sp_helpreplicationdb] TO [public] AS [dbo]
GO
