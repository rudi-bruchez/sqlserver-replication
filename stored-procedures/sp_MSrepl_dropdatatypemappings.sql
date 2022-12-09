SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSrepl_dropdatatypemappings]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSrepl_dropdatatypemappings] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSrepl_dropdatatypemappings]
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

	-- MSdatatype_mappings view
	IF OBJECT_ID(N'dbo.MSdatatype_mappings', 'V') IS NOT NULL
	BEGIN
		PRINT 'Dropping view MSdatatype_mappings...'
		
		SELECT @cmd = 'DROP VIEW dbo.MSdatatype_mappings'
		EXEC(@cmd)
	END
	
	-- sysdatatypemappings view
	IF OBJECT_ID(N'dbo.sysdatatypemappings', 'V') IS NOT NULL
	BEGIN
		PRINT 'Dropping view sysdatatypemappings...'
		
		SELECT @cmd = 'DROP VIEW dbo.sysdatatypemappings'
		EXEC(@cmd)
	END

	-- MSdbms_datatype_mapping
	IF OBJECT_ID(N'dbo.MSdbms_datatype_mapping', 'U') IS NOT NULL
	BEGIN
		PRINT 'Dropping table MSdbms_datatype_mapping...'

		ALTER TABLE MSdbms_map
		DROP CONSTRAINT fk_MSdbms_map_default_datatype_mapping_id

		DROP TABLE dbo.MSdbms_datatype_mapping
	END

	-- MSdbms_map
	IF OBJECT_ID(N'dbo.MSdbms_map', 'U') IS NOT NULL
	BEGIN
		PRINT 'Dropping table MSdbms_map...'
		DROP TABLE dbo.MSdbms_map
	END

	-- MSdbms_datatype
	IF OBJECT_ID(N'dbo.MSdbms_datatype', 'U') IS NOT NULL
	BEGIN
		PRINT 'Dropping table MSdbms_datatype...'
		DROP TABLE dbo.MSdbms_datatype
	END

	-- MSdbms
	IF OBJECT_ID(N'dbo.MSdbms', 'U') IS NOT NULL
	BEGIN
		PRINT 'Dropping table MSdbms...'
		DROP TABLE dbo.MSdbms
	END
END
GO
GRANT EXECUTE ON [sys].[sp_MSrepl_dropdatatypemappings] TO [public] AS [dbo]
GO
