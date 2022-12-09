SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_helppeerresponses]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_helppeerresponses] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_helppeerresponses]
	@request_id [int]
WITH EXECUTE AS CALLER
AS
begin
	declare @retcode int

	-- Security Check
	exec @retcode = sys.sp_MSreplcheck_publish
	if @@error <> 0 or @retcode <> 0
	begin
		return 1
	end
	
	-- Check to see if database is activated for publication
	if sys.fn_MSrepl_istranpublished(db_name(),0) <> 1
	begin
		RAISERROR (14013, 16, -1)
		return 1
	end

	-- return results
	select * 
		from MSpeer_response
		where request_id = @request_id

	return 0
end
GO
GRANT EXECUTE ON [sys].[sp_helppeerresponses] TO [public] AS [dbo]
GO
