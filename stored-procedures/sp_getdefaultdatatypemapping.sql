SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_getdefaultdatatypemapping]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_getdefaultdatatypemapping] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_getdefaultdatatypemapping]
	@source_dbms [sysname],
	@source_version [varchar](10),
	@source_type [sysname],
	@source_length [bigint],
	@source_precision [int],
	@source_scale [int],
	@source_nullable [bit],
	@destination_dbms [sysname],
	@destination_version [varchar](10),
	@destination_type [sysname] OUTPUT,
	@destination_length [bigint] OUTPUT,
	@destination_precision [int] OUTPUT,
	@destination_scale [int] OUTPUT,
	@destination_nullable [bit] OUTPUT,
	@dataloss [bit] OUTPUT
WITH EXECUTE AS CALLER
AS
BEGIN
	DECLARE @retcode int
	SET @retcode = 0

	--
	-- Security Check: require sysadmin
	--
	IF (ISNULL(IS_SRVROLEMEMBER('sysadmin'),0) = 0)
	BEGIN
		RAISERROR(21089,16,-1) 
		RETURN (1)
	END


	-- Check if type even exists
	IF (sys.fn_MSrepl_checktype(@source_type, @source_dbms, @source_version) = 0)
	BEGIN
		RAISERROR(21654, 16, -1, @source_type)
		RETURN (1)
	END
	
	SELECT	@destination_type		= destination_type,
			@destination_length		= destination_length,
			@destination_precision	= destination_precision,
			@destination_scale		= destination_scale,
			@destination_nullable	= destination_nullable,
			@dataloss				= dataloss
	FROM	sys.fn_MSrepl_getdatatypemappings
			(
				@source_dbms,
				@source_version,
				@source_type,
				@source_length,
				@source_precision,
				@source_scale,
				@source_nullable,
				@destination_dbms,
				@destination_version,
				1,
				NULL
			)
			
	IF @@ROWCOUNT = 0
	BEGIN
		RAISERROR (21656, 16, -1, @source_type)
		RETURN (1)
	END

	RETURN (0)
END
GO
GRANT EXECUTE ON [sys].[sp_getdefaultdatatypemapping] TO [public] AS [dbo]
GO
