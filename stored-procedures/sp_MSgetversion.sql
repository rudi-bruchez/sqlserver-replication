SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSgetversion]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSgetversion] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSgetversion]
WITH EXECUTE AS CALLER
AS
BEGIN
	/* 
	* Dev Note (VSTS#749780): 
	* sp_MSgetversion was removed in Denali since it was an internal sp and deprecated. 
	* We re-implement it in repl for downlevel compatibility.
	* Repl agents in Denali do not use it.
	*
	* The package type is not available directly in serverproperty.
	* We do some simple translation from engineedition.The values are,
	*    PACKAGE_STANDARD = 2 ;
	*    PACKAGE_ENTERPRISE = 3 ;
	*    PACKAGE_MSDE = 4 ;
	*    PACKAGE_EXPRESS = 5 ;
	*    ENGINE_MSDE = 1 ;
	*    ENGINE_STANDARD = 2 ;
	*    ENGINE_ENTERPRISE = 3 ;
	*    ENGINE_EXPRESS = 4 ;
	* In fact nobody cares about the package type, we just make it complete.
	*/
	SELECT SERVERPROPERTY('ProductVersion'), 
		CASE SERVERPROPERTY('LicenseType')
			WHEN 'PER_SEAT' THEN 1
			WHEN 'PER_PROCESSOR' THEN  2
			-- Just keep same behavior as the old sp, return 1 for other cases
			-- Keep the PER_SEAT case to indicate the licensetype
			ELSE 1
		END,
		CASE SERVERPROPERTY('EngineEdition')
			WHEN 1 THEN 4
			WHEN 4 THEN 5
			ELSE SERVERPROPERTY('EngineEdition')
		END 
	RETURN 0
END
GO
GRANT EXECUTE ON [sys].[sp_MSgetversion] TO [public] AS [dbo]
GO
