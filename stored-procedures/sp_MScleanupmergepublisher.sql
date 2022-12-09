SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[dbo].[sp_MScleanupmergepublisher]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [dbo].[sp_MScleanupmergepublisher] AS' 
END
GO
ALTER PROCEDURE [dbo].[sp_MScleanupmergepublisher]
WITH EXECUTE AS CALLER
AS
exec sys.sp_MScleanupmergepublisher_internal
GO
