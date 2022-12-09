SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSfast_delete_trans]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSfast_delete_trans] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSfast_delete_trans]
WITH EXECUTE AS CALLER
AS
begin
	declare @retcode int

	--
	-- security check is done in sp_MSdrop_snapshot_dirs
	--
	EXEC @retcode = sys.sp_MSdrop_snapshot_dirs
	if( @retcode <> 0 or @@error <> 0 )
		return 1

	truncate table MSrepl_commands
	truncate table MSrepl_transactions
end
GO
GRANT EXECUTE ON [sys].[sp_MSfast_delete_trans] TO [public] AS [dbo]
GO
