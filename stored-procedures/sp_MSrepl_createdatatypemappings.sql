SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSrepl_createdatatypemappings]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSrepl_createdatatypemappings] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSrepl_createdatatypemappings]
WITH EXECUTE AS CALLER
AS
begin
	DECLARE @cmd nvarchar(4000)

	--
	-- Security Check: require sysadmin
	--
	IF (ISNULL(IS_SRVROLEMEMBER('sysadmin'),0) = 0)
	BEGIN
		RAISERROR(21089,16,-1) 
		RETURN (1)
	END

	-- MSdbms
	IF OBJECT_ID(N'dbo.MSdbms', 'U') IS NULL
	BEGIN
		print 'Creating table MSdbms'

		create table MSdbms
		(
			dbms_id			int NOT NULL IDENTITY,
			dbms			sysname NOT NULL,
			version			sysname NULL,
			CONSTRAINT pk_MSdbms PRIMARY KEY (dbms_id)
		)
		
		exec dbo.sp_MS_marksystemobject 'MSdbms'
	END

	-- MSdbms_datatype
	IF OBJECT_ID(N'dbo.MSdbms_datatype', 'U') IS NULL
	BEGIN
		print 'Creating table MSdbms_datatype'

		create table MSdbms_datatype
		(
			datatype_id		int NOT NULL IDENTITY,
			dbms_id			int	NOT NULL,
			type			sysname NOT NULL,
			createparams	int NOT NULL DEFAULT 0,
			CONSTRAINT pk_MSdbms_datatype PRIMARY KEY (datatype_id),
			CONSTRAINT fk_MSdbms_datatype_dbms_id FOREIGN KEY (dbms_id) REFERENCES MSdbms (dbms_id)
		)
		
		exec dbo.sp_MS_marksystemobject 'MSdbms_datatype'

		--
		-- Define default dbms data types
		--
		exec sys.sp_MSrepl_MSSQLdatatypes	'MSSQLServer'
		exec sys.sp_MSrepl_DB2datatypes		'DB2'
		exec sys.sp_MSrepl_ORAdatatypes		'Oracle'
		exec sys.sp_MSrepl_ORAdatatypes		'Oracle', '8'
		exec sys.sp_MSrepl_ORAdatatypes		'Oracle', '9'
		exec sys.sp_MSrepl_ORAdatatypes		'Oracle', '10'
		exec sys.sp_MSrepl_ORAdatatypes		'Oracle', '11'
		exec sys.sp_MSrepl_SASdatatypes		'SYBASE'
	END

	-- MSdbms_map
	IF OBJECT_ID(N'dbo.MSdbms_map', 'U') IS NULL
	BEGIN
		print 'Creating table MSdbms_map'

		create table MSdbms_map
		(
			map_id						int NOT NULL IDENTITY,
			src_dbms_id					int	NOT NULL,
			dest_dbms_id				int NOT NULL,
			src_datatype_id				int NOT NULL,
			src_len_min					bigint NULL DEFAULT NULL,
			src_len_max					bigint NULL DEFAULT NULL,
			src_prec_min				bigint NULL DEFAULT NULL,
			src_prec_max				bigint NULL DEFAULT NULL,
			src_scale_min				bigint NULL DEFAULT NULL,
			src_scale_max				bigint NULL DEFAULT NULL,
			src_nullable				bit NULL DEFAULT NULL,
			default_datatype_mapping_id	int NULL DEFAULT NULL,
			CONSTRAINT pk_MSdbms_map PRIMARY KEY (map_id),
			CONSTRAINT fk_MSdbms_map_src_dbms_id FOREIGN KEY (src_dbms_id) REFERENCES MSdbms (dbms_id),
			CONSTRAINT fk_MSdbms_map_dest_dbms_id FOREIGN KEY (dest_dbms_id) REFERENCES MSdbms (dbms_id),
			CONSTRAINT fk_MSdbms_map_src_datatype_id FOREIGN KEY (src_datatype_id) REFERENCES MSdbms_datatype (datatype_id)
		)
		
		exec dbo.sp_MS_marksystemobject 'MSdbms_map'
	END

	-- MSdbms_datatype_mapping
	IF OBJECT_ID(N'dbo.MSdbms_datatype_mapping', 'U') IS NULL
	BEGIN
		print 'Creating table MSdbms_datatype_mapping'

		create table MSdbms_datatype_mapping
		(
			datatype_mapping_id	int NOT NULL IDENTITY,
			map_id				int NOT NULL,
			dest_datatype_id	int NOT NULL,
			dest_precision		bigint NULL DEFAULT NULL,
			dest_scale			int NULL DEFAULT NULL,
			dest_length			bigint NULL DEFAULT NULL,
			dest_nullable		bit NULL DEFAULT NULL,
			dest_createparams	int DEFAULT 0,
			dataloss			bit NOT NULL DEFAULT 0,
			CONSTRAINT pk_MSdbms_datatype_mapping PRIMARY KEY (datatype_mapping_id),
			CONSTRAINT fk_MSdbms_datatype_mapping_map_id FOREIGN KEY (map_id) REFERENCES MSdbms_map (map_id),
			CONSTRAINT fk_MSdbms_datatype_mapping_dest_datatype_id FOREIGN KEY (dest_datatype_id) REFERENCES MSdbms_datatype (datatype_id)
		)

		ALTER TABLE MSdbms_map
		ADD CONSTRAINT fk_MSdbms_map_default_datatype_mapping_id FOREIGN KEY (default_datatype_mapping_id) REFERENCES MSdbms_datatype_mapping (datatype_mapping_id)

		exec dbo.sp_MS_marksystemobject 'MSdbms_datatype_mapping'
		
		print 'Definining default datatype mappings'
		
		-- Heterogeneous subscribers
		exec sys.sp_MSrepl_MSSQL_ORA_datatypemappings @source_dbms = N'MSSQLSERVER', @destination_dbms = N'ORACLE', @destination_version = '8'
		exec sys.sp_MSrepl_MSSQL_ORA_datatypemappings @source_dbms = N'MSSQLSERVER', @destination_dbms = N'ORACLE', @destination_version = '9'
		exec sys.sp_MSrepl_MSSQL_ORA_datatypemappings @source_dbms = N'MSSQLSERVER', @destination_dbms = N'ORACLE', @destination_version = '10'
		exec sys.sp_MSrepl_MSSQL_ORA_datatypemappings @source_dbms = N'MSSQLSERVER', @destination_dbms = N'ORACLE', @destination_version = '11'
		exec sys.sp_MSrepl_MSSQL_DB2_datatypemappings @source_dbms = N'MSSQLSERVER', @destination_dbms = N'DB2'
		exec sys.sp_MSrepl_MSSQL_SAS_datatypemappings @source_dbms = N'MSSQLSERVER', @destination_dbms = N'SYBASE'
		
		-- Heterogeneous publishers
		exec sys.sp_MSrepl_ORA_MSSQL_datatypemappings @source_dbms = N'ORACLE', @source_version = '8', @destination_dbms = N'MSSQLSERVER'
		exec sys.sp_MSrepl_ORA_MSSQL_datatypemappings @source_dbms = N'ORACLE', @source_version = '9', @destination_dbms = N'MSSQLSERVER'
		exec sys.sp_MSrepl_ORA_MSSQL_datatypemappings @source_dbms = N'ORACLE', @source_version = '10', @destination_dbms = N'MSSQLServer'
		exec sys.sp_MSrepl_ORA_MSSQL_datatypemappings @source_dbms = N'ORACLE', @source_version = '11', @destination_dbms = N'MSSQLServer'
	END

	-- Datatype mappings for heterogeneous subscribers previously used
	-- a base table that now has become a view.  The table should
	-- be dropped and replaced with the new scheme.
	IF OBJECT_ID(N'msdb.dbo.MSdatatype_mappings', 'U') IS NOT NULL
	BEGIN
		DROP TABLE msdb.dbo.MSdatatype_mappings
	END
	
	-- MSdatatype_mappings (view to emulate the pre-Yukon table)
	IF OBJECT_ID(N'dbo.MSdatatype_mappings', 'V') IS NULL
	BEGIN
		print 'Creating view MSdatatype_mappings'
		
		SELECT @cmd = 'CREATE VIEW dbo.MSdatatype_mappings '
					  + '(dbms_name, sql_type, dest_type, dest_prec, dest_create_params, dest_nullable) '
					  + 'AS SELECT destination_dbms, source_type, destination_type, '
					  + 'case when (destination_createparams & 1) = 1 then destination_precision else destination_length end, '
					  + 'destination_createparams, destination_nullable '
					  + 'FROM sys.fn_helpdatatypemap(N''MSSQLSERVER'', ''%'', ''%'', ''%'', ''%'', ''%'', 0)'
		
		EXEC(@cmd)
		
		exec dbo.sp_MS_marksystemobject 'MSdatatype_mappings'
	END

	-- sysdatatypemappings (advanced view)
	IF OBJECT_ID(N'dbo.sysdatatypemappings', 'V') IS NULL
	BEGIN
		print 'Creating view sysdatatypemappings'
		
		SELECT @cmd = 'CREATE VIEW dbo.sysdatatypemappings '
					  + 'AS SELECT * FROM sys.fn_helpdatatypemap(''%'', ''%'', ''%'', ''%'', ''%'', ''%'', 0)'
		
		EXEC(@cmd)
		
		exec dbo.sp_MS_marksystemobject 'sysdatatypemappings'
	END
END
GO
GRANT EXECUTE ON [sys].[sp_MSrepl_createdatatypemappings] TO [public] AS [dbo]
GO
