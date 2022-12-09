SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSupdate_subscriber_schedule]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSupdate_subscriber_schedule] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSupdate_subscriber_schedule]
	@publisher [sysname],
	@subscriber [sysname],
	@agent_type [tinyint],
	@frequency_type [int],
	@frequency_interval [int],
	@frequency_relative_interval [int],
	@frequency_recurrence_factor [int],
	@frequency_subday [int],
	@frequency_subday_interval [int],
	@active_start_time_of_day [int],
	@active_end_time_of_day [int],
	@active_start_date [int],
	@active_end_date [int]
WITH EXECUTE AS CALLER
AS
begin
   set nocount on
   
   declare @cmd1 nvarchar (255)
   declare @retcode int

	--
	-- security check
	-- only db_owner can execute this
	--
	if (is_member ('db_owner') != 1) 
	begin
		raiserror(14260, 16, -1)
		return (1)
	end

   begin transaction
   save transaction update_subscriber_schedule
   
   /* Check if subscriber exists */
   if not exists (select * from MSsubscriber_info 
			where UPPER(publisher) = UPPER(@publisher) and UPPER(subscriber) = UPPER(@subscriber))
	   goto FAILED
	   
	if not exists (select * from MSsubscriber_schedule 
		where UPPER(publisher) = UPPER(@publisher) and UPPER(subscriber) = UPPER(@subscriber) and agent_type = @agent_type)
	   goto FAILED
	
   
   if @frequency_type is not NULL
	  update MSsubscriber_schedule set frequency_type = @frequency_type 
	  where UPPER(publisher) = UPPER(@publisher) and UPPER(subscriber) = UPPER(@subscriber) and agent_type = @agent_type
	  if @@error <> 0
		 goto FAILED
   
   if @frequency_interval is not NULL
	  update MSsubscriber_schedule set frequency_interval = @frequency_interval 
	  where UPPER(publisher) = UPPER(@publisher) and UPPER(subscriber) = UPPER(@subscriber) and agent_type = @agent_type
	  if @@error <> 0
		 goto FAILED
   
   if @frequency_relative_interval is not NULL
	  update MSsubscriber_schedule set frequency_relative_interval = @frequency_relative_interval 
	  where UPPER(publisher) = UPPER(@publisher) and UPPER(subscriber) = UPPER(@subscriber) and agent_type = @agent_type
	  if @@error <> 0
		 goto FAILED
   
   if @frequency_recurrence_factor is not NULL
	  update MSsubscriber_schedule set frequency_recurrence_factor = @frequency_recurrence_factor 
	  where UPPER(publisher) = UPPER(@publisher) and UPPER(subscriber) = UPPER(@subscriber) and agent_type = @agent_type
	   if @@error <> 0
		 goto FAILED
   
   if @frequency_subday is not NULL
	  update MSsubscriber_schedule set frequency_subday = @frequency_subday 
	  where UPPER(publisher) = UPPER(@publisher) and UPPER(subscriber) = UPPER(@subscriber) and agent_type = @agent_type
	  if @@error <> 0
		 goto FAILED
   
   if @frequency_subday_interval is not NULL
	  update MSsubscriber_schedule set frequency_subday_interval = @frequency_subday_interval 
	  where UPPER(publisher) = UPPER(@publisher) and UPPER(subscriber) = UPPER(@subscriber) and agent_type = @agent_type
	  if @@error <> 0
		 goto FAILED
   
   if @active_start_time_of_day is not NULL
	  update MSsubscriber_schedule set active_start_time_of_day = @active_start_time_of_day 
	  where UPPER(publisher) = UPPER(@publisher) and UPPER(subscriber) = UPPER(@subscriber) and agent_type = @agent_type
	  if @@error <> 0
		 goto FAILED
   
   if @active_end_time_of_day is not NULL
	  update MSsubscriber_schedule set active_end_time_of_day = @active_end_time_of_day 
	  where UPPER(publisher) = UPPER(@publisher) and UPPER(subscriber) = UPPER(@subscriber) and agent_type = @agent_type
	  if @@error <> 0
		 goto FAILED
   
   if @active_start_date is not NULL
	  update MSsubscriber_schedule set active_start_date = @active_start_date 
	  where UPPER(publisher) = UPPER(@publisher) and UPPER(subscriber) = UPPER(@subscriber) and agent_type = @agent_type
	  if @@error <> 0
		 goto FAILED
   
   if @active_end_date is not NULL
	  update MSsubscriber_schedule set active_end_date = @active_end_date 
	  where UPPER(publisher) = UPPER(@publisher) and UPPER(subscriber) = UPPER(@subscriber) and agent_type = @agent_type
	  if @@error <> 0
		 goto FAILED

   commit transaction
   return (0)
   
FAILED:
	if @@trancount > 0
	begin
		rollback transaction update_subscriber_schedule
		commit transaction      -- to finish off the tran we started in this proc (though 
								-- work was rolled back to savepoint)
	end
   return (1)
end
GO
GRANT EXECUTE ON [sys].[sp_MSupdate_subscriber_schedule] TO [public] AS [dbo]
GO
