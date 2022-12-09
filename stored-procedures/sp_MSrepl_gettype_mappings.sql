SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSrepl_gettype_mappings]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSrepl_gettype_mappings] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSrepl_gettype_mappings]
	@dbms_name [sysname],
	@dbms_version [sysname],
	@sql_type [sysname],
	@source_prec [int]
WITH EXECUTE AS CALLER
AS
set nocount on
	declare @retcode int
	declare @distributor sysname
	declare @distribdb sysname
	declare @distproc nvarchar (255)
	
	EXECUTE @retcode = sys.sp_MSrepl_getdistributorinfo @rpcsrvname = @distributor OUTPUT,
		   @distribdb   = @distribdb OUTPUT
	IF @@ERROR <> 0 or @retcode <> 0
	BEGIN
		RAISERROR (14071, 16, -1)
		RETURN (1)
	END

	SELECT @distproc = QUOTENAME(RTRIM(@distributor)) + '.' + QUOTENAME(RTRIM(@distribdb)) + '.sys.sp_help_datatype_mapping'

	EXECUTE @retcode = @distproc
					   @dbms_name = @dbms_name,
					   @dbms_version = @dbms_version,
					   @sql_type = @sql_type,
					   @source_prec = @source_prec
			 
	IF @@ERROR <> 0 OR @retcode <> 0
		return 1
	ELSE
		return 0
GO
GRANT EXECUTE ON [sys].[sp_MSrepl_gettype_mappings] TO [public] AS [dbo]
GO
