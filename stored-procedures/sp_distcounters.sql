SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_distcounters]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_distcounters] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_distcounters]
WITH EXECUTE AS CALLER
AS
SET NOCOUNT ON

	/*
	** Declarations.
	*/
	DECLARE @distributor sysname
	DECLARE @distribdb sysname
	DECLARE @distproc nvarchar (300)
	DECLARE @retcode int

	/*
	** Get distribution server information for remote RPC
	** subscription calls.  If no distribution information, assume
	** replication is not being used.
	*/
	EXEC @retcode = sys.sp_MSrepl_getdistributorinfo @rpcsrvname = @distributor OUTPUT,
									   @distribdb = @distribdb OUTPUT
	IF @@error <> 0 OR @retcode <> 0 OR @distributor IS NULL OR
	   @distribdb IS NULL
	RETURN (1)

	/*
	** Request counters from Distribution Server
	*/
	SELECT @distproc = QUOTENAME(RTRIM(@distributor)) + '.' + QUOTENAME(RTRIM(@distribdb)) +
	'.dbo.sp_MSdistribution_counters'
	declare @publisher sysname
	select @publisher = publishingservername()
	EXEC @retcode = @distproc @publisher
GO
GRANT EXECUTE ON [sys].[sp_distcounters] TO [public] AS [dbo]
GO
