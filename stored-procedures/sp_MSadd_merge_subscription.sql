SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSadd_merge_subscription]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSadd_merge_subscription] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSadd_merge_subscription]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@subscriber [sysname],
	@subscriber_db [sysname],
	@subscription_type [tinyint],
	@sync_type [tinyint],
	@status [tinyint],
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
	@optional_command_line [nvarchar](4000),
	@agent_name [sysname],
	@merge_jobid [binary](16) OUTPUT,
	@offloadagent [bit],
	@offloadserver [sysname],
	@hostname [sysname],
	@description [nvarchar](255),
	@subid [uniqueidentifier],
	@internal [sysname],
	@publisher_engine_edition [int]
WITH EXECUTE AS CALLER
AS
begin
	set nocount on

	declare @publisher_id smallint
	declare @publication_id int
	declare @retcode int

	-- default values 
	declare @flushfrequency int 
	declare @frequencytype int
	declare @frequencyinterval int 
	declare @frequencyrelativeinterval int
	declare @frequencyrecurrencefactor int 
	declare @frequencysubday int 
	declare @frequencysubdayinterval int
	declare @activestarttimeofday int
	declare @activeendtimeofday int
	declare @activestartdate int 
	declare @activeenddate int 
	declare @push int
	declare @local_job bit
	declare @thirdparty_flag bit
	declare @subscribersecuritymode smallint
	declare @subscriberlogin sysname
	declare @subscriberpassword nvarchar(524)

	select @push = 0

	--
	-- security check
	-- Has to be executed from distribution database
	--
	if (sys.fn_MSrepl_isdistdb (db_name()) != 1)
	begin
		raiserror(21482, 16, -1, 'sp_MSadd_merge_subscription', 'distribution')
		return (1)
	end
	-- Check if publisher is a defined as a distribution publisher in the current database
	exec @retcode = sys.sp_MSvalidate_distpublisher @publisher, @publisher_id OUTPUT
	if @retcode <> 0
	begin
		return(1)
	end

	IF @offloadagent IS NOT NULL
		AND @offloadagent != 0
	BEGIN
		-- "Parameter '@offloadagent' is no longer supported."
		RAISERROR(21698, 16, -1, '@offloadagent')
		RETURN 1
	END

	IF ISNULL(@offloadserver, N'') != N''
	BEGIN
		-- "Parameter '@offloadserver' is no longer supported."
		RAISERROR(21698, 16, -1, '@offloadserver')
		RETURN 1
	END
	
	-- Get the publication information 
	select @publication_id = publication_id,
		@thirdparty_flag = thirdparty_flag from 
		dbo.MSpublications where 
		publisher_id = @publisher_id and
		publisher_db = @publisher_db and
		publication = @publication
	if @publication_id is NULL
	begin
		raiserror (20026, 11, -1, @publication)
		return (1)
	end
	
	-- Perform PAL check with retrieved @publication_id
	exec @retcode = sys.sp_MScheck_pull_access
		@agent_type = 1, -- merge agent
		@publication_id = @publication_id
	if @@error <> 0 or @retcode <> 0
	begin    
		RAISERROR (15247, 11, -1)
		return (1)
	end

	-- Make sure subscription does not already exist
	if exists (select * from dbo.MSmerge_subscriptions where 
		publisher_id = @publisher_id and 
		publisher_db = @publisher_db and 
		publication_id = @publication_id and
		UPPER(subscriber) = UPPER(@subscriber) and
		subscriber_db = @subscriber_db)
	begin
		if @thirdparty_flag = 1
		begin
			raiserror (14058, 16, -1)
			return(1)
		end
		else
		begin
			exec @retcode = sys.sp_MSdrop_merge_subscription 
				@publisher = @publisher,
				@publisher_db = @publisher_db,
				@publication = @publication,
				@subscriber = @subscriber,
				@subscriber_db = @subscriber_db,
				@subscription_type  = @subscription_type
			if @retcode <> 0 or @@error <> 0
			begin
				return (1)
			end
		end
	end
			
	select @frequencytype = frequency_type,
		@frequencyinterval = frequency_interval,
		@frequencyrelativeinterval = frequency_relative_interval,
		@frequencyrecurrencefactor = frequency_recurrence_factor,
		@frequencysubday = frequency_subday,
		@frequencysubdayinterval = frequency_subday_interval,
		@activestarttimeofday = active_start_time_of_day,
		@activeendtimeofday = active_end_time_of_day,
		@activestartdate = active_start_date,
		@activeenddate = active_end_date
	from MSsubscriber_schedule 
	where UPPER(publisher) = UPPER(@publisher) and UPPER(subscriber) = UPPER(@subscriber) and agent_type = 1
   	
	if @frequency_type is null
		select @frequency_type = @frequencytype

	if @frequency_interval  is null
		select  @frequency_interval = @frequencyinterval

	if @frequency_relative_interval is null
		select  @frequency_relative_interval = @frequencyrelativeinterval

	if @frequency_recurrence_factor is null
		select  @frequency_recurrence_factor = @frequencyrecurrencefactor

	if @frequency_subday is null
		select  @frequency_subday = @frequencysubday

	if @frequency_subday_interval is null
		select  @frequency_subday_interval = @frequencysubdayinterval

	if @active_start_time_of_day is null
		select  @active_start_time_of_day = @activestarttimeofday

	if @active_end_time_of_day is null
		select  @active_end_time_of_day = @activeendtimeofday

	if @active_start_date is null
		select  @active_start_date = @activestartdate

	if @active_end_date is null
		select  @active_end_date = @activeenddate
	
	begin transaction 

	-- If push and agent name is not passed in, create local job.
	if @subscription_type = @push
		select @local_job = 1
	else
		select @local_job = 0

	/* If a subid is not passed in, set it to NEWID() */
	if (@subid IS NULL)
		set @subid = newid()
		
	insert into dbo.MSmerge_subscriptions (publisher_id, publisher_db, publication_id,
		subscriber_id, subscriber_db, subscription_type, sync_type, status, 
		subscription_time, description, publisher, subscriber, subid)
		values (@publisher_id, @publisher_db, @publication_id,
		NULL, @subscriber_db, @subscription_type, @sync_type, @status, 
		getdate(), 
		@description,
		@publisher,
		@subscriber,
		@subid)
	if @@error <> 0
	begin
		goto FAILURE
	end

	-- Create Merge Agent
	exec @retcode = sys.sp_MSadd_merge_agent
		@name = @agent_name, 
		@publisher = @publisher,
		@publisher_db = @publisher_db,
		@publication = @publication,
		@subscriber = @subscriber,
		@subscriber_db = @subscriber_db,
		@local_job = @local_job,
		@frequency_type  = @frequency_type,                         
		@frequency_interval = @frequency_interval, 
		@frequency_relative_interval = @frequency_relative_interval, 
		@frequency_recurrence_factor = @frequency_recurrence_factor, 
		@frequency_subday = @frequency_subday, 
		@frequency_subday_interval = @frequency_subday_interval,
		@active_start_time_of_day = @active_start_time_of_day, 
		@active_end_time_of_day = @active_end_time_of_day,         
		@active_start_date = @active_start_date, 
		@active_end_date = @active_end_date,
		@optional_command_line = @optional_command_line,
		@merge_jobid = @merge_jobid OUTPUT,
		@subscription_type = @subscription_type,
		@hostname = @hostname,
		@internal = @internal,
		@publisher_engine_edition = @publisher_engine_edition
	if @retcode <> 0 or @@error <> 0
	begin
		goto FAILURE
	end
	
	commit transaction
	return (0)

FAILURE:
	/* UNDONE : This code is specific to 6.X nested transaction semantics */
	if @@TRANCOUNT = 1 
		ROLLBACK TRANSACTION 
	else
		COMMIT TRANSACTION 
	RETURN (1)
end
GO
GRANT EXECUTE ON [sys].[sp_MSadd_merge_subscription] TO [public] AS [dbo]
GO
