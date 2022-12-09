SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_enumdsn]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_enumdsn] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_enumdsn]
WITH EXECUTE AS CALLER
AS
if 1 <> is_srvrolemember('sysadmin')
	begin
		raiserror(15247,-1,-1)
		return 1
	end

	SET NOCOUNT ON

	DECLARE @distributor sysname
	DECLARE @distproc nvarchar (300)
	DECLARE @retcode int

	DECLARE @dsotype_odbc int
	DECLARE @dsotype_oledb int

	select @dsotype_odbc = 1
	select @dsotype_oledb = 3

	/*
	** Get distribution server information for remote RPC
	** subscription calls.
	*/

	EXEC @retcode = sys.sp_MSrepl_getdistributorinfo @rpcsrvname = @distributor OUTPUT
	IF @@error <> 0 OR @retcode <> 0 or @distributor is null
		BEGIN
		RAISERROR (14071, 16, -1)
			RETURN (1)
	END

	create table #datasourcestemptable (DataSourceName sysname collate database_default not null, Description nvarchar(255) collate database_default null, DataSourceType int null, ProviderName nvarchar(255) collate database_default null)
	
	/*
	** Call xp_enumdsn
	*/
	SELECT @distproc = QUOTENAME(RTRIM(@distributor)) + '.master.sys.xp_enumdsn'
	insert into #datasourcestemptable(DataSourceName, Description) EXEC @retcode = @distproc
	IF @@error <> 0
		BEGIN
		RAISERROR (14071, 16, -1)
		RETURN (1)
	END

	update #datasourcestemptable set DataSourceType = @dsotype_odbc where DataSourceType is null
	IF @@error <> 0 
	BEGIN
		RETURN (1)
	END

	/*
	** Call sp_enumoledbdatasources
	*/
	SELECT @distproc = QUOTENAME(RTRIM(@distributor)) + '.master.sys.sp_enumoledbdatasources'
	insert into #datasourcestemptable(DataSourceName, Description, ProviderName) EXEC @retcode = @distproc
	IF @@error <> 0
		BEGIN
		RAISERROR (14071, 16, -1)
		RETURN (1)
	END

	update #datasourcestemptable set DataSourceType = @dsotype_oledb where DataSourceType is null
	IF @@error <> 0 
	BEGIN
		RETURN (1)
	END
	
	select 'Data Source Name' = DataSourceName, Description, 'Type' = DataSourceType, 'Provider Name' = ProviderName 
	from #datasourcestemptable
	order by 3, 1

	drop table #datasourcestemptable

	return (0)
GO
GRANT EXECUTE ON [sys].[sp_enumdsn] TO [public] AS [dbo]
GO
