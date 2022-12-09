SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSupdate_subscriber_tracer_history]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSupdate_subscriber_tracer_history] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSupdate_subscriber_tracer_history]
	@parent_tracer_id [int],
	@agent_id [int]
WITH EXECUTE AS CALLER
AS
begin
	set nocount on

	declare @retcode 		int,
			@current_date	datetime

	select @current_date = getdate()
	
	-- security check
	exec @retcode = sys.sp_MScheck_pull_access @agent_id = @agent_id, @agent_type = 0
	if @@error <> 0 or @retcode <> 0
	begin
		return 1 
	end
	
	begin transaction tr_sp_MSupd_sub_tracer_hist
	save transaction tr_sp_MSupd_sub_tracer_hist
	
	-- here we will update the subscriber commit time
	-- if the tracer history row no longer exists then
	-- we will exit with no error because this may happen
	-- if cleanup comes bye and removes the history row
	update MStracer_history
		set subscriber_commit = @current_date
		where parent_tracer_id = @parent_tracer_id
			and agent_id = @agent_id
	if @@error <> 0
		goto Err_Handler

	commit transaction tr_sp_MSupd_sub_tracer_hist
	return 0

Err_Handler:
	rollback transaction tr_sp_MSupd_sub_tracer_hist
	commit transaction

	return 1
end
GO
GRANT EXECUTE ON [sys].[sp_MSupdate_subscriber_tracer_history] TO [public] AS [dbo]
GO
