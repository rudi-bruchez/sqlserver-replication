SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSsetaccesslist]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSsetaccesslist] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSsetaccesslist]
	@publication [sysname],
	@publisher [sysname],
	@publisher_db [sysname]
WITH EXECUTE AS CALLER
AS
-- we don't need to do anything here since we use role based security
    return 0
GO
GRANT EXECUTE ON [sys].[sp_MSsetaccesslist] TO [public] AS [dbo]
GO
