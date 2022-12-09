SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MShaschangeslightweight]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MShaschangeslightweight] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MShaschangeslightweight]
	@pubid [uniqueidentifier],
	@haschanges [int] OUTPUT
WITH EXECUTE AS CALLER
AS
set nocount on
	declare @retcode smallint

	set @haschanges= 0

	exec @retcode= sys.sp_MSreplcheck_subscribe
	if @@error <> 0 or @retcode <> 0 return (1)
	
	-- find out whether at least one article that belongs to the publication has changes
	if exists (select top 1 * from dbo.MSmerge_rowtrack where tablenick in
				(select nickname from dbo.sysmergearticles where pubid = @pubid)
			  )
	begin
		set @haschanges= 1
	end
	if @@error <> 0 return 1
	return 0
GO
GRANT EXECUTE ON [sys].[sp_MShaschangeslightweight] TO [public] AS [dbo]
GO
