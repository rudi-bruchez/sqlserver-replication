SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_setdefaultdatatypemapping]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_setdefaultdatatypemapping] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_setdefaultdatatypemapping]
	@mapping_id [int],
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
	@destination_nullable [bit]
WITH EXECUTE AS CALLER
AS
BEGIN
	DECLARE @retcode				int
	DECLARE @src_dbms_id			int
	DECLARE @src_datatype_id		int
	DECLARE @dest_dbms_id			int
	DECLARE @dest_datatype_id		int
	DECLARE @map_id					int
	DECLARE @datatype_mapping_id	int
	
	SET NOCOUNT ON

	-- Prepare dbms for case insensitive searches
	SET @source_dbms		= UPPER(@source_dbms)
	SET @destination_dbms	= UPPER(@destination_dbms)

	set @retcode = 0

	--
	-- Security Check: require sysadmin
	--
	IF (ISNULL(IS_SRVROLEMEMBER('sysadmin'),0) = 0)
	BEGIN
		RAISERROR(21089,16,-1) 
		RETURN (1)
	END

	-- Check parameters
	IF (@mapping_id IS NULL)
	BEGIN
		-- Require source dbms
		IF (@source_dbms IS NULL) OR (@source_dbms = N'')
		BEGIN
			RAISERROR(7801, 16, -1, 128, N'@source_dbms')
			RETURN (1)
		END

		-- Require source type
		IF (@source_type IS NULL) OR (@source_type = N'')
		BEGIN
			RAISERROR(7801, 16, -1, 128, N'@source_type')
			RETURN (1)
		END

		-- Require destination dbms
		IF (@destination_dbms IS NULL) OR (@destination_dbms = N'')
		BEGIN
			RAISERROR(7801, 16, -1, 128, N'@destination_dbms')
			RETURN (1)
		END

		-- Require destination type
		IF (@destination_type IS NULL) OR (@destination_type = N'')
		BEGIN
			RAISERROR(7801, 16, -1, 128, N'@destination_type')
			RETURN (1)
		END

		EXEC @retcode = sys.sp_MSrepl_getdbmsinfo
						@dbms			= @source_dbms,
						@version		= @source_version,
						@type			= @source_type,
						@dbms_id		= @src_dbms_id OUTPUT,
						@datatype_id	= @src_datatype_id OUTPUT

		IF @retcode <> 0 OR @@ERROR <> 0
		BEGIN
			RETURN (@retcode)
		END

		EXEC @retcode = sys.sp_MSrepl_getdbmsinfo
						@dbms			= @destination_dbms,
						@version		= @destination_version,
						@type			= @destination_type,
						@dbms_id		= @dest_dbms_id OUTPUT,
						@datatype_id	= @dest_datatype_id OUTPUT

		IF @retcode <> 0 OR @@ERROR <> 0
		BEGIN
			RETURN (@retcode)
		END
	END

	BEGIN TRAN
	SAVE TRAN setdefaultdatatypemapping

	IF (@mapping_id IS NULL)
	BEGIN
		-- Get source mapping
		SELECT	@map_id					= map.map_id,
				@datatype_mapping_id	= dm.datatype_mapping_id
		FROM	msdb.dbo.MSdbms_map map,
				msdb.dbo.MSdbms_datatype_mapping dm
		WHERE	map.map_id			= dm.map_id
		  AND	map.src_dbms_id		= @src_dbms_id
		  AND	map.dest_dbms_id	= @dest_dbms_id
		  AND	map.src_datatype_id	= @src_datatype_id
		  AND	map.src_len_min		= @source_length_min
		  AND	map.src_len_max		= @source_length_max
		  AND	map.src_prec_min	= @source_precision_min
		  AND	map.src_prec_max	= @source_precision_max
		  AND	map.src_scale_min	= @source_scale_min
		  AND	map.src_scale_max	= @source_scale_max
		  AND	map.src_nullable	= @source_nullable
		  AND	dm.dest_datatype_id	= @dest_datatype_id
		  AND	dm.dest_length		= @destination_length
		  AND	dm.dest_precision	= @destination_precision
		  AND	dm.dest_scale		= @destination_scale
		  AND	dm.dest_nullable	= @destination_nullable

		IF @map_id IS NULL OR @datatype_mapping_id IS NULL OR @@ERROR <> 0
		BEGIN
			RAISERROR (21656, 16, -1, @source_type)

			IF @@TRANCOUNT > 0
			BEGIN
				ROLLBACK TRANSACTION setdefaultdatatypemapping
				COMMIT TRAN
			END
			RETURN (1)
		END
	END
	ELSE
	BEGIN
		-- Set datatype mapping id
		SET @datatype_mapping_id = @mapping_id
		
		-- Get map id for specific data type mapping id
		SELECT	@map_id = dm.map_id
		FROM	msdb.dbo.MSdbms_datatype_mapping dm
		WHERE	datatype_mapping_id = @datatype_mapping_id

		IF @map_id IS NULL OR @datatype_mapping_id IS NULL OR @@ERROR <> 0
		BEGIN
			DECLARE @msg nvarchar(50)
			SELECT @msg = CONVERT(nvarchar(50), @mapping_id)
			RAISERROR (21656, 16, -1, @msg)

			IF @@TRANCOUNT > 0
			BEGIN
				ROLLBACK TRANSACTION setdefaultdatatypemapping
				COMMIT TRAN
			END
			RETURN (1)
		END
	END
	
	-- Set default
	EXEC @retcode = sys.sp_MSrepl_setdefaultdatatype
					@map_id					= @map_id,
					@datatype_mapping_id	= @datatype_mapping_id

	IF @retcode <> 0 OR @@ERROR <> 0
	BEGIN
		IF @@TRANCOUNT > 0
		BEGIN
			ROLLBACK TRANSACTION setdefaultdatatypemapping
			COMMIT TRAN
		END
		RETURN (@retcode)
	END
	
	COMMIT TRAN			
	RETURN (@retcode)		
END
GO
GRANT EXECUTE ON [sys].[sp_setdefaultdatatypemapping] TO [public] AS [dbo]
GO
