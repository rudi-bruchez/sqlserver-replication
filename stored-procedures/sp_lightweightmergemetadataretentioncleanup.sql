SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_lightweightmergemetadataretentioncleanup]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_lightweightmergemetadataretentioncleanup] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_lightweightmergemetadataretentioncleanup]
	@num_rowtrack_rows [int] OUTPUT
WITH EXECUTE AS CALLER
AS
declare @delbatchsize	int
	declare @delcount 		int
	declare @retcode		smallint
	
	-- security check
    exec @retcode = sys.sp_MSreplcheck_subscribe 
    if @retcode <> 0 or @@error <> 0 return 1

	set @delbatchsize= 5000
	set @num_rowtrack_rows= 0

	set @delcount= @delbatchsize
	while @delcount = @delbatchsize
	begin
		delete top (@delbatchsize) from dbo.MSmerge_rowtrack
			where 1=sys.fn_MSrowispastretention(tablenick, changed, getdate())

		set @delcount= @@rowcount
		set @num_rowtrack_rows= @num_rowtrack_rows + @delcount
	end
				
	set @delcount= @delbatchsize
	while @delcount = @delbatchsize
	begin
		delete top (@delbatchsize) from dbo.MSmerge_metadataaction_request
			where 1=sys.fn_MSrowispastretention(tablenick, changed, getdate())
	
		set @delcount= @@rowcount
	end
GO
GRANT EXECUTE ON [sys].[sp_lightweightmergemetadataretentioncleanup] TO [public] AS [dbo]
GO
