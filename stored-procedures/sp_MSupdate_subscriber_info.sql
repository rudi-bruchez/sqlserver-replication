SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSupdate_subscriber_info]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSupdate_subscriber_info] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSupdate_subscriber_info]
	@publisher [sysname],
	@subscriber [sysname],
	@type [tinyint],
	@login [sysname],
	@password [nvarchar](524),
	@commit_batch_size [int],
	@status_batch_size [int],
	@flush_frequency [int],
	@frequency_type [int],
	@frequency_interval [int],
	@frequency_relative_interval [int],
	@frequency_recurrence_factor [int],
	@frequency_subday [int],
	@frequency_subday_interval [int],
	@active_start_time_of_day [int],
	@active_end_time_of_day [int],
	@active_start_date [int],
	@active_end_date [int],
	@retryattempts [int],
	@retrydelay [int],
	@description [nvarchar](255),
	@security_mode [int]
WITH EXECUTE AS CALLER
AS
begin
   set nocount on
   
   declare @cmd1 nvarchar (255)
   declare @retcode int
   declare @platform_nt binary

	--
	-- security check
	-- only db_owner can execute this
	--
	if (is_member ('db_owner') != 1) 
	begin
		raiserror(14260, 16, -1)
		return (1)
	end
	
   select @platform_nt = 0x1

   -- Get publisher port number
	exec sys.sp_MSget_server_portinfo 
		@name = @publisher, 
		@srvname = @publisher OUTPUT

	-- Get subscriber port number
	exec sys.sp_MSget_server_portinfo 
		@name = @subscriber, 
		@srvname = @subscriber OUTPUT

   IF (UPPER(@subscriber) = UPPER(@@SERVERNAME) and ( @platform_nt != platform() & @platform_nt ) and @security_mode = 1)
		BEGIN
			RAISERROR(21038, 16, -1)
			goto FAILED
		END


   begin transaction
   save transaction update_subscriber
   
   /* Check if subscriber exists */
   if not exists (select * from MSsubscriber_info 
				  where UPPER(publisher) = UPPER(@publisher) and UPPER(subscriber) = UPPER(@subscriber))
	   goto FAILED

   if not exists (select * from MSsubscriber_schedule 
				  where UPPER(publisher) = UPPER(@publisher) and UPPER(subscriber) = UPPER(@subscriber) and agent_type = 0)
	   goto FAILED    
   
   if @type is not NULL
	  update MSsubscriber_info set type = @type 
		where UPPER(publisher) = UPPER(@publisher) and UPPER(subscriber) = UPPER(@subscriber)
	  if @@error <> 0
		 goto FAILED

	if @security_mode = 1
	begin
		-- set the password here to newid. by doing
		-- this we will force a reset of the password
		-- to an encrypted invalid password. the encryp
		-- and storing of the password is below...
		
		select @password = newid()
		
		update MSsubscriber_info 
			set security_mode = 1,
				login = N''
			where UPPER(publisher) = UPPER(@publisher) 
				and UPPER(subscriber) = UPPER(@subscriber)
		if @@error <> 0
			goto FAILED
	end
	else if @security_mode = 0
	begin
		update MSsubscriber_info 
			set security_mode = 0
			where UPPER(publisher) = UPPER(@publisher) 
				and UPPER(subscriber) = UPPER(@subscriber)
		if @@error <> 0
			goto FAILED
	end
	else if @security_mode is not NULL
	begin
		raiserror(14109, 16, -1)
		goto FAILED
	end

	if @login is not NULL
	begin
		update MSsubscriber_info 
			set login = @login 
		where UPPER(publisher) = UPPER(@publisher) 
			and UPPER(subscriber) = UPPER(@subscriber)
		if @@error <> 0
			goto FAILED
	end
	
	if isnull(@password, '') <> '%'
	begin
		-- Encrypt the password
		EXEC @retcode = sys.sp_MSreplencrypt @password OUTPUT
		IF @@error <> 0 OR @retcode <> 0
			goto FAILED

		update MSsubscriber_info 
			set password = @password 
			where UPPER(publisher) = UPPER(@publisher) 
				and UPPER(subscriber) = UPPER(@subscriber)
		if @@error <> 0
			goto FAILED
	end
 	
   if @frequency_type is not NULL
	  update MSsubscriber_schedule set frequency_type = @frequency_type 
		where  UPPER(publisher) = UPPER(@publisher) and UPPER(subscriber) = UPPER(@subscriber) and agent_type = 0
	  if @@error <> 0
		 goto FAILED
   
   if @frequency_interval is not NULL
	  update MSsubscriber_schedule set frequency_interval = @frequency_interval 
		where UPPER(publisher) = UPPER(@publisher) and UPPER(subscriber) = UPPER(@subscriber) and agent_type = 0
	  if @@error <> 0
		 goto FAILED
   
   if @frequency_relative_interval is not NULL
	  update MSsubscriber_schedule set frequency_relative_interval = @frequency_relative_interval 
	  where UPPER(publisher) = UPPER(@publisher) and UPPER(subscriber) = UPPER(@subscriber) and agent_type = 0
	   if @@error <> 0
		 goto FAILED
   
   if @frequency_recurrence_factor is not NULL
	  update MSsubscriber_schedule set frequency_recurrence_factor = @frequency_recurrence_factor 
		where UPPER(publisher) = UPPER(@publisher) and UPPER(subscriber) = UPPER(@subscriber) and agent_type = 0
	  if @@error <> 0
		 goto FAILED
   
   if @frequency_subday is not NULL
	  update MSsubscriber_schedule set frequency_subday = @frequency_subday 
		where UPPER(publisher) = UPPER(@publisher) and UPPER(subscriber) = UPPER(@subscriber) and agent_type = 0
	  if @@error <> 0
		 goto FAILED
   
   if @frequency_subday_interval is not NULL
	  update MSsubscriber_schedule set frequency_subday_interval = @frequency_subday_interval 
		where UPPER(publisher) = UPPER(@publisher) and UPPER(subscriber) = UPPER(@subscriber) and agent_type = 0
	  if @@error <> 0
		 goto FAILED
   
   if @active_start_time_of_day is not NULL
	  update MSsubscriber_schedule set active_start_time_of_day = @active_start_time_of_day 
		where UPPER(publisher) = UPPER(@publisher) and UPPER(subscriber) = UPPER(@subscriber) and agent_type = 0
	  if @@error <> 0
		 goto FAILED
   
   if @active_end_time_of_day is not NULL
	  update MSsubscriber_schedule set active_end_time_of_day = @active_end_time_of_day 
		where UPPER(publisher) = UPPER(@publisher) and UPPER(subscriber) = UPPER(@subscriber) and agent_type = 0
	  if @@error <> 0
		 goto FAILED
   
   if @active_start_date is not NULL
	  update MSsubscriber_schedule set active_start_date = @active_start_date 
		where UPPER(publisher) = UPPER(@publisher) and UPPER(subscriber) = UPPER(@subscriber) and agent_type = 0
	  if @@error <> 0
		 goto FAILED
   
   if @active_end_date is not NULL
	  update MSsubscriber_schedule set active_end_date = @active_end_date 
	  where UPPER(publisher) = UPPER(@publisher) and UPPER(subscriber) = UPPER(@subscriber) and agent_type = 0
	  if @@error <> 0
		 goto FAILED
   
   if @description is not NULL
	  update MSsubscriber_info set description = @description 
		where UPPER(publisher) = UPPER(@publisher) and UPPER(subscriber) = UPPER(@subscriber)
	  if @@error <> 0
		 goto FAILED

	if @security_mode is not NULL
	  update MSsubscriber_info set security_mode = @security_mode 
		where UPPER(publisher) = UPPER(@publisher) and UPPER(subscriber) = UPPER(@subscriber)
	  if @@error <> 0
		 goto FAILED

   commit transaction
   return (0)
   
FAILED:
	if @@trancount > 0
	begin
		rollback transaction update_subscriber
		commit tran -- to finish off the tran we started in this proc (though 
					-- work was rolled back to savepoint)
	end
   return (1)
end
GO
GRANT EXECUTE ON [sys].[sp_MSupdate_subscriber_info] TO [public] AS [dbo]
GO
