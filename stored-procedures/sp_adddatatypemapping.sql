SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_adddatatypemapping]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_adddatatypemapping] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_adddatatypemapping]
	@source_dbms [sysname],
	@source_version [varchar](10),
	@source_type [sysname],
	@source_length_min [bigint],
	@source_length_max [bigint],
	@source_precision_min [bigint],
	@source_precision_max [bigint],
	@source_scale_min [int],
	@source_scale_max [int],
	@source_nullable [bit],
	@destination_dbms [sysname],
	@destination_version [varchar](10),
	@destination_type [sysname],
	@destination_length [bigint],
	@destination_precision [bigint],
	@destination_scale [int],
	@destination_nullable [bit],
	@destination_createparams [int],
	@dataloss [bit],
	@is_default [bit]
WITH EXECUTE AS CALLER
AS
BEGIN
	DECLARE @retcode	int

	-- Issue unsupported warning
	RAISERROR(21769, 10, -1)

	-- Do data type mapping
	EXEC @retcode = sp_MSrepl_adddatatypemapping	@source_dbms				= @source_dbms,
													@source_version				= @source_version,
													@source_type				= @source_type,
													@source_length_min			= @source_length_min,
													@source_length_max			= @source_length_max,
													@source_precision_min		= @source_precision_min,
													@source_precision_max		= @source_precision_max,
													@source_scale_min			= @source_scale_min,
													@source_scale_max			= @source_scale_max,
													@source_nullable			= @source_nullable,
													@destination_dbms			= @destination_dbms,
													@destination_version		= @destination_version,
													@destination_type			= @destination_type,
													@destination_length			= @destination_length,
													@destination_precision		= @destination_precision,
													@destination_scale			= @destination_scale,
													@destination_nullable		= @destination_nullable,
													@destination_createparams	= @destination_createparams,
													@dataloss					= @dataloss,
													@is_default					= @is_default

	RETURN @retcode
END
GO
GRANT EXECUTE ON [sys].[sp_adddatatypemapping] TO [public] AS [dbo]
GO
