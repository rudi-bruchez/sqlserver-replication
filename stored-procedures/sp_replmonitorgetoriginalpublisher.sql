SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_replmonitorgetoriginalpublisher]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_replmonitorgetoriginalpublisher] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_replmonitorgetoriginalpublisher]
	@publisher [sysname],
	@orig_publisher [sysname] OUTPUT
WITH EXECUTE AS CALLER
AS
begin
    set nocount on
	select top 1 @orig_publisher = original_publisher  from MSredirected_publishers where upper(redirected_publisher collate database_default) = UPPER(@publisher collate database_default)
end
GO
GRANT EXECUTE ON [sys].[sp_replmonitorgetoriginalpublisher] TO [public] AS [dbo]
GO
