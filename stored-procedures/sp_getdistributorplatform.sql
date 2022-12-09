SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_getdistributorplatform]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_getdistributorplatform] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_getdistributorplatform]
	@hostplatform [nvarchar](256) OUTPUT
WITH EXECUTE AS CALLER
AS
BEGIN
	SET NOCOUNT ON
	DECLARE @loc_distributor sysname,
			@retcode int,
			@dist_rpcname sysname

	--
	-- Get the distribution server
	--
	SELECT  @dist_rpcname = name,
			@loc_distributor = UPPER(data_source COLLATE database_default )
	FROM sys.servers
	WHERE is_distributor = 1

	--
	-- Check if need to reach out
	--
	IF @loc_distributor IS NULL OR @loc_distributor = UPPER(@@servername)
		SELECT @hostplatform=host_platform FROM sys.dm_os_host_info
	ELSE
	BEGIN
		-- execute remote query to the linked server to find host platform; if
		-- dm_os_host_info is not available, it's an older version and must be
		-- Windows
		DECLARE @distproc nvarchar (300)
		SELECT @distproc = QUOTENAME(RTRIM(@dist_rpcname)) + N'.master.sys.sp_executesql'
		EXEC @retcode = @distproc @stmt=
				  N'IF EXISTS (SELECT 1 FROM sys.all_objects WHERE name = ''dm_os_host_info'' AND type = ''V'' AND is_ms_shipped = 1)
					  SELECT @hostplatform=host_platform FROM sys.dm_os_host_info
					ELSE
					  SELECT @hostplatform=N''Windows''',
			 @params = N'@hostplatform nvarchar(256) OUTPUT', @hostplatform = @hostplatform OUTPUT
	END

	IF @retcode <> 0 OR @@ERROR <> 0
		RETURN 1
	ELSE
		RETURN 0
END
GO
GRANT EXECUTE ON [sys].[sp_getdistributorplatform] TO [public] AS [dbo]
GO
