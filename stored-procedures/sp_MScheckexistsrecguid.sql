SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MScheckexistsrecguid]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MScheckexistsrecguid] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MScheckexistsrecguid]
	@recguid [uniqueidentifier],
	@exists [bit] OUTPUT
WITH EXECUTE AS CALLER
AS
declare @retcode int
    
	exec @retcode = sys.sp_MSreplcheck_subscribe 
    if @retcode <> 0 or @@error <> 0 return 1

	if exists (select * from dbo.sysmergesubscriptions where recguid=@recguid)
	begin
		set @exists= 1
	end
	else
	begin
		set @exists= 0
	end

	return 0
GO
GRANT EXECUTE ON [sys].[sp_MScheckexistsrecguid] TO [public] AS [dbo]
GO
