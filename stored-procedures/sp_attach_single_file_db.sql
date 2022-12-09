SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_attach_single_file_db]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_attach_single_file_db] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_attach_single_file_db]
	@dbname [sysname],
	@physname [nvarchar](260)
WITH EXECUTE AS CALLER
AS
declare @execstring nvarchar (4000)
	set nocount on

	if (SERVERPROPERTY('IsMatrix') = 1)
	begin
		raiserror (28401, -1, -1, N'sys.sp_attach_single_file_db')
		return (1)
	end

	if ((@dbname is null or datalength(@dbname) = 0) or
	   (@physname is null or datalength(@physname) = 0))
	begin
		raiserror (15004,-1,-1)
		return (1)
	end

	select @execstring = 'CREATE DATABASE '
		+ quotename( @dbname , '[')
		+ ' ON (FILENAME ='
		+ ''''
		+ REPLACE(@physname,N'''',N'''''')
		+ ''''
		+ ' ) FOR ATTACH'
	EXEC (@execstring)
	if @@error <>  0
	begin
		-- No need to raiserror as the CREATE DATABASE will do so
		return(1)
	end

	-- strip out replication from this database
	EXEC sys.sp_MSremovedbreplication_internal @dbname

	return (0) -- sp_attach_single_file_db
GO
GRANT EXECUTE ON [sys].[sp_attach_single_file_db] TO [public] AS [dbo]
GO
