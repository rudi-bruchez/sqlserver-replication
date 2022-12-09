SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSforeachdb]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSforeachdb] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSforeachdb]
	@command1 [nvarchar](2000),
	@replacechar [nchar](1),
	@command2 [nvarchar](2000),
	@command3 [nvarchar](2000),
	@precommand [nvarchar](2000),
	@postcommand [nvarchar](2000)
WITH EXECUTE AS CALLER
AS
set deadlock_priority low
    
	/* This proc returns one or more rows for each accessible db, with each db defaulting to its own result set */
	/* @precommand and @postcommand may be used to force a single result set via a temp table. */

	/* Preprocessor won't replace within quotes so have to use str(). */
	declare @inaccessible nvarchar(12), @invalidlogin nvarchar(12), @dbinaccessible nvarchar(12)
	select @inaccessible = ltrim(str(convert(int, 0x03e0), 11))
	select @invalidlogin = ltrim(str(convert(int, 0x40000000), 11))
	select @dbinaccessible = N'0x80000000'		/* SQLDMODbUserProf_InaccessibleDb; the negative number doesn't work in convert() */

	if (@precommand is not null)
		exec(@precommand)

	declare @origdb nvarchar(128)
	select @origdb = db_name()

	/* If it's a single user db and there's an entry for it in sysprocesses who isn't us, we can't use it. */
   /* Create the select */
	exec(N'declare hCForEachDatabase cursor global for select name from master.dbo.sysdatabases d ' +
			N' where (d.status & ' + @inaccessible + N' = 0)' +
			N' and (DATABASEPROPERTYEX(d.name, ''UserAccess'') <> ''SINGLE_USER'' and (has_dbaccess(d.name) = 1))' )

	declare @retval int
	select @retval = @@error
	if (@retval = 0)
		exec @retval = sys.sp_MSforeach_worker @command1, @replacechar, @command2, @command3, 1

	if (@retval = 0 and @postcommand is not null)
		exec(@postcommand)

   declare @tempdb nvarchar(258)
   SELECT @tempdb = REPLACE(@origdb, N']', N']]')
   exec (N'use ' + N'[' + @tempdb + N']')

	return @retval
GO
GRANT EXECUTE ON [sys].[sp_MSforeachdb] TO [public] AS [dbo]
GO
