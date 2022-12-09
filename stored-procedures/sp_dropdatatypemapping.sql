SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_dropdatatypemapping]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_dropdatatypemapping] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_dropdatatypemapping]
	@mapping_id [int],
	@source_dbms [sysname],
	@source_version [sysname],
	@source_type [sysname],
	@source_length_min [bigint],
	@source_length_max [bigint],
	@source_precision_min [bigint],
	@source_precision_max [bigint],
	@source_scale_min [int],
	@source_scale_max [int],
	@source_nullable [bit],
	@destination_dbms [sysname],
	@destination_version [sysname],
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
		-- Require source dbms at a minimum
		IF (@source_dbms IS NULL) OR (@source_dbms = N'')
		BEGIN
			RAISERROR(7801, 16, -1, 128, N'@source_dbms')
			RETURN (1)
		END

		-- Get source DBMS id
		SELECT	@src_dbms_id = dbms_id
		FROM	msdb.dbo.MSdbms
		WHERE	dbms	= @source_dbms
		  AND	version = @source_version

		IF @src_dbms_id IS NULL OR @@ERROR <> 0
		BEGIN
			RAISERROR(21653, 16, -1, @source_dbms, @source_version)
			RETURN (1)
		END
	END
	  
	BEGIN TRAN
	SAVE TRAN dropdatatypemapping

	IF (@mapping_id IS NULL) AND (@source_type = '%')
	BEGIN
		-- Clear default data type mappings
		UPDATE	msdb.dbo.MSdbms_map
		SET		default_datatype_mapping_id = NULL
		WHERE	src_dbms_id = @src_dbms_id

		IF @@ERROR <> 0
		BEGIN
			IF @@TRANCOUNT > 0
			BEGIN
				ROLLBACK TRANSACTION dropdatatypemapping
				COMMIT TRAN
			END
			RETURN (1)
		END

		-- Drop data type mappings
		DELETE	msdb.dbo.MSdbms_datatype_mapping
		FROM	msdb.dbo.MSdbms_datatype_mapping dm,
				msdb.dbo.MSdbms_map map
		WHERE	map.map_id		= dm.map_id
		  AND	map.src_dbms_id	= @src_dbms_id
		
		IF @@ERROR <> 0
		BEGIN
			IF @@TRANCOUNT > 0
			BEGIN
				ROLLBACK TRANSACTION dropdatatypemapping
				COMMIT TRAN
			END
			RETURN (1)
		END

		-- Drop maps
		DELETE FROM msdb.dbo.MSdbms_map
		WHERE src_dbms_id = @src_dbms_id

		IF @@ERROR <> 0
		BEGIN
			IF @@TRANCOUNT > 0
			BEGIN
				ROLLBACK TRANSACTION dropdatatypemapping
				COMMIT TRAN
			END
			RETURN (1)
		END
	END
	ELSE
	BEGIN
		IF (@mapping_id IS NULL)
		BEGIN
			-- Get source data type
			SELECT	@src_datatype_id = datatype_id
			FROM	msdb.dbo.MSdbms_datatype
			WHERE	dbms_id = @src_dbms_id
			  AND	UPPER(type COLLATE DATABASE_DEFAULT) =
				UPPER(@source_type) COLLATE DATABASE_DEFAULT

			IF @src_datatype_id IS NULL OR @@ERROR <> 0
			BEGIN
				RAISERROR(21654, 16, -1, @source_type)

				IF @@TRANCOUNT > 0
				BEGIN
					ROLLBACK TRAN dropdatatypemapping
					COMMIT TRAN
				END
				RETURN (1)
			END
		END

		IF (@mapping_id IS NULL) AND (@destination_type = '%')
		BEGIN
			-- Clear default data type mapping
			UPDATE	msdb.dbo.MSdbms_map
			SET		default_datatype_mapping_id = NULL
			WHERE	src_dbms_id		= @src_dbms_id
			  AND	src_datatype_id	= @src_datatype_id

			IF @@ERROR <> 0
			BEGIN
				IF @@TRANCOUNT > 0
				BEGIN
					ROLLBACK TRANSACTION dropdatatypemapping
					COMMIT TRAN
				END
				RETURN (1)
			END
			
			-- Drop data type mappings
			DELETE	msdb.dbo.MSdbms_datatype_mapping
			FROM	msdb.dbo.MSdbms_map map,
					msdb.dbo.MSdbms_datatype_mapping dm
			WHERE	map.map_id			= dm.map_id
			  AND	map.src_dbms_id		= @src_dbms_id
			  AND	map.src_datatype_id	= @src_datatype_id
			
			IF @@ERROR <> 0
			BEGIN
				IF @@TRANCOUNT > 0
				BEGIN
					ROLLBACK TRANSACTION dropdatatypemapping
					COMMIT TRAN
				END
				RETURN (1)
			END

			-- Drop map
			DELETE FROM msdb.dbo.MSdbms_map
			WHERE	src_dbms_id		= @src_dbms_id
			  AND	src_datatype_id	= @src_datatype_id

			IF @@ERROR <> 0
			BEGIN
				IF @@TRANCOUNT > 0
				BEGIN
					ROLLBACK TRANSACTION dropdatatypemapping
					COMMIT TRAN
				END
				RETURN (1)
			END
		END
		ELSE
		BEGIN
			IF (@mapping_id IS NULL)
			BEGIN
				-- Get destination info
				EXEC @retcode = sys.sp_MSrepl_getdbmsinfo
								@dbms			= @destination_dbms,
								@version		= @destination_version,
								@type			= @destination_type,
								@dbms_id		= @dest_dbms_id OUTPUT,
								@datatype_id	= @dest_datatype_id OUTPUT

				IF @retcode <> 0 OR @@ERROR <> 0
				BEGIN
					IF @@TRANCOUNT > 0
					BEGIN
						ROLLBACK TRANSACTION dropdatatypemapping
						COMMIT TRAN
					END

					RETURN (@retcode)
				END

				-- Get data map
				SELECT	@map_id = map_id
				FROM	msdb.dbo.MSdbms_map
				WHERE	src_dbms_id		= @src_dbms_id
				  AND	dest_dbms_id	= @dest_dbms_id
				  AND	src_datatype_id	= @src_datatype_id
				  AND	src_len_min		= @source_length_min
				  AND	src_len_max		= @source_length_max
				  AND	src_prec_min	= @source_precision_min
				  AND	src_prec_max	= @source_precision_max
				  AND	src_scale_min	= @source_scale_min
				  AND	src_scale_max	= @source_scale_max
				  AND	src_nullable	= @source_nullable

				IF @map_id IS NULL OR @@ERROR <> 0
				BEGIN
					RAISERROR (21656, 16, -1, @source_type)

					IF @@TRANCOUNT > 0
					BEGIN
						ROLLBACK TRANSACTION dropdatatypemapping
						COMMIT TRAN
					END

					RETURN (1)
				END

				-- Get data type mapping
				SELECT	@datatype_mapping_id = datatype_mapping_id
				FROM	msdb.dbo.MSdbms_map map,
						msdb.dbo.MSdbms_datatype_mapping dm
				WHERE	map.map_id			= dm.map_id
				  AND	map.map_id			= @map_id
				  AND	dm.dest_datatype_id	= @dest_datatype_id
				  AND	dm.dest_length		= @destination_length
				  AND	dm.dest_precision	= @destination_precision
				  AND	dm.dest_scale		= @destination_scale
				  AND	dm.dest_nullable	= @destination_nullable

				IF @datatype_mapping_id IS NULL OR @@ERROR <> 0
				BEGIN
					RAISERROR (21656, 16, -1, @source_type)

					IF @@TRANCOUNT > 0
					BEGIN
						ROLLBACK TRANSACTION dropdatatypemapping
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
				WHERE	datatype_mapping_id = @mapping_id

				IF @map_id IS NULL OR @datatype_mapping_id IS NULL OR @@ERROR <> 0
				BEGIN
					DECLARE @msg nvarchar(50)
					SELECT @msg = CONVERT(nvarchar(50), @mapping_id)
					RAISERROR (21656, 16, -1, @msg)

					IF @@TRANCOUNT > 0
					BEGIN
						ROLLBACK TRANSACTION dropdatatypemapping
						COMMIT TRAN
					END
					RETURN (1)
				END
			END
			
			-- Clear if default
			UPDATE	msdb.dbo.MSdbms_map
			SET		default_datatype_mapping_id = NULL
			WHERE	map_id = @map_id
			  AND	default_datatype_mapping_id = @datatype_mapping_id
			  
			IF @@ERROR <> 0
			BEGIN
				IF @@TRANCOUNT > 0
				BEGIN
					ROLLBACK TRANSACTION dropdatatypemapping
					COMMIT TRAN
				END
				RETURN (1)
			END

			-- Drop data type mapping
			DELETE FROM msdb.dbo.MSdbms_datatype_mapping
			WHERE datatype_mapping_id = @datatype_mapping_id

			-- Drop map if no mappings left
			DELETE FROM msdb.dbo.MSdbms_map
			WHERE	map_id = @map_id
			  AND	map_id NOT IN
					(
						SELECT	map_id
						FROM	msdb.dbo.MSdbms_datatype_mapping
						WHERE	map_id = @map_id
					)

			IF @@ERROR <> 0
			BEGIN
				IF @@TRANCOUNT > 0
				BEGIN
					ROLLBACK TRANSACTION dropdatatypemapping
					COMMIT TRAN
				END
				RETURN (1)
			END
		END
	END
	
	-- Fixup defaults for any dropped default mappings
	exec @retcode = sys.sp_MSrepl_fixupdefaultmappings
	IF @retcode <> 0 OR @@ERROR <> 0
	BEGIN
		IF @@TRANCOUNT > 0
		BEGIN
			ROLLBACK TRANSACTION dropdatatypemapping
			COMMIT TRAN
		END
		RETURN (1)
	END
	
	COMMIT TRAN
	RETURN (@retcode)		
END
GO
GRANT EXECUTE ON [sys].[sp_dropdatatypemapping] TO [public] AS [dbo]
GO
