SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_stoppushsubscription_agent]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_stoppushsubscription_agent] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_stoppushsubscription_agent]
	@publication [sysname],
	@subscriber [sysname],
	@subscriber_db [sysname],
	@publisher [sysname]
WITH EXECUTE AS CALLER
AS
begin
	set nocount on
	declare @cmd        nvarchar(4000)
	declare @retcode    int 
	declare @pubtype    sysname
	declare @stop       tinyint
	
	set @retcode = 0
	set @stop = 1
	exec @retcode = sys.sp_MSrepl_getpublisherinfo  @publisher      = @publisher,
													@publisher_type = @pubtype OUTPUT,
													@rpcheader      = @cmd OUTPUT
	if @retcode <> 0
		return (@retcode)

	-- Add sp
	set @cmd = @cmd + N'sys.sp_MSrepl_subscriptionagentjobcontrol'

	exec @retcode = @cmd
					@publication = @publication,
					@subscriber = @subscriber,
					@subscriber_db = @subscriber_db,
					@publisher = @publisher,
					@publisher_type = @pubtype,
					@action = @stop    
	return @retcode


end
GO
GRANT EXECUTE ON [sys].[sp_stoppushsubscription_agent] TO [public] AS [dbo]
GO
