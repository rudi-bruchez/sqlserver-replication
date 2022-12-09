SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSinsertlightweightschemachange]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSinsertlightweightschemachange] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSinsertlightweightschemachange]
	@pubid [uniqueidentifier],
	@schemaversion [int],
	@schemaguid [uniqueidentifier]
WITH EXECUTE AS CALLER
AS
set nocount on
	declare @retcode int
	
	-- security check
    exec @retcode = sys.sp_MSreplcheck_subscribe 
    if @retcode <> 0 or @@error <> 0 return 1
		

	update dbo.sysmergesubscriptions 
		set schemaversion= @schemaversion,
			schemaguid= @schemaguid
		where pubid = @pubid and
			  (schemaversion < @schemaversion or schemaversion is null)
	if @@error <> 0 return 1

	return 0
GO
GRANT EXECUTE ON [sys].[sp_MSinsertlightweightschemachange] TO [public] AS [dbo]
GO
