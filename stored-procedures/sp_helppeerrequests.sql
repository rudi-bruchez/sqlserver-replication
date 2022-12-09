SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_helppeerrequests]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_helppeerrequests] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_helppeerrequests]
	@publication [sysname],
	@description [nvarchar](4000)
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
		from MSpeer_request
		where publication = @publication
			and isnull(description, N'') like @description
		order by sent_date desc

	return 0
end
GO
GRANT EXECUTE ON [sys].[sp_helppeerrequests] TO [public] AS [dbo]
GO
