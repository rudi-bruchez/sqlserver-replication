SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_stoppublication_snapshot]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_stoppublication_snapshot] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_stoppublication_snapshot]
	@publication [sysname],
	@publisher [sysname]
WITH EXECUTE AS CALLER
AS
begin
	set nocount on
	declare @cmd        nvarchar(4000)
	declare @retcode    int 
	declare @pubtype    sysname
	declare @stop      tinyint    
	set @retcode = 0
	set @stop = 1
	exec @retcode = sys.sp_MSrepl_getpublisherinfo  @publisher      = @publisher,
													@publisher_type = @pubtype OUTPUT,
													@rpcheader      = @cmd OUTPUT
	if @retcode <> 0
		return (@retcode)

	-- Add sp
	set @cmd = @cmd + N'sys.sp_MSrepl_publicationsnapshotjobcontrol'

	exec @retcode = @cmd
					@publication = @publication,
					@publisher = @publisher,
					@action = @stop
	return (@retcode)

end
GO
GRANT EXECUTE ON [sys].[sp_stoppublication_snapshot] TO [public] AS [dbo]
GO
