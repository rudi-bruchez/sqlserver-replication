SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSadd_subscriber_schedule]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSadd_subscriber_schedule] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSadd_subscriber_schedule]
	@publisher [sysname],
	@subscriber [sysname],
	@agent_type [smallint],
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
   declare @retcode int

	--
	-- security check
	-- only sysadmin can execute this
	--
	if (isnull(is_srvrolemember('sysadmin'),0) = 0) 
	begin
		raiserror(21089, 16, -1)
		return (1)
	end
	--
	-- security check
	-- Has to be executed from distribution database
	--
	if (sys.fn_MSrepl_isdistdb (db_name()) != 1)
	begin
		raiserror(21482, 16, -1, 'sp_MSadd_subscriber_schedule', 'distribution')
		return (1)
	end

	-- Get subscriber port number
	declare @subscriber_with_port sysname
	exec sys.sp_MSget_server_portinfo 
		@name = @subscriber, 
		@srvname = @subscriber OUTPUT,
		@srvname_with_port = @subscriber_with_port OUTPUT

   	/* Add the subscriber to dbo.sysservers as a RPC server, if it does not
  	** already exist. sp_MSadd_subserver does the check.
   	*/
		DECLARE @subscriber_provstr nvarchar(4000) 
		set @subscriber_provstr = sys.fn_getproviderstring(@subscriber_with_port)
		exec @retcode = sys.sp_MSadd_subserver @subscriber = @subscriber,
											@type = 0, -- Microsoft SQL Server
											@subscriber_provstr = @subscriber_provstr
		if @@error <> 0 OR @retcode <> 0
			return 1

	/* Add the subscriber to MSreplservers , if it does not already exist.
	*/   
	if not exists (select * from MSreplservers where  UPPER(srvname collate database_default) = UPPER(@subscriber collate database_default))
	begin
		begin tran
		DECLARE @srvid smallint
		select @srvid = isnull(max(srvid),0)+1 from MSreplservers with (holdlock)
	    insert into MSreplservers
		(srvid, srvname)
	    select @srvid, srvname from master.dbo.sysservers where  UPPER(srvname collate database_default) = UPPER(@subscriber collate database_default)
		commit tran 
	end

	/* only insert if it doesn't exist */
	if not exists (select * 
				from MSsubscriber_schedule 
				where UPPER(publisher) = UPPER(@publisher) 
					and UPPER(subscriber) = UPPER(@subscriber) 
					and agent_type = @agent_type)
	begin
		   insert MSsubscriber_schedule (publisher, subscriber, agent_type, 
			  frequency_type, frequency_interval, frequency_relative_interval,
			  frequency_recurrence_factor, frequency_subday, frequency_subday_interval,
			  active_start_time_of_day, active_end_time_of_day, active_start_date,
			  active_end_date)
			  
			  values (@publisher, @subscriber, @agent_type, 
			  @frequency_type, @frequency_interval, @frequency_relative_interval,
			  @frequency_recurrence_factor, @frequency_subday, @frequency_subday_interval,
			  @active_start_time_of_day, @active_end_time_of_day, @active_start_date,
			  @active_end_date)
		   if @@error <> 0
			  return 1
	end
end
GO
GRANT EXECUTE ON [sys].[sp_MSadd_subscriber_schedule] TO [public] AS [dbo]
GO
