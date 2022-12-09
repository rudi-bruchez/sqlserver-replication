SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_replsync]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_replsync] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_replsync]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@article [sysname]
WITH EXECUTE AS CALLER
AS
SET NOCOUNT ON
    RAISERROR (21023, 16, -1,'sp_replsync')
    RETURN(1)
GO
GRANT EXECUTE ON [sys].[sp_replsync] TO [public] AS [dbo]
GO
