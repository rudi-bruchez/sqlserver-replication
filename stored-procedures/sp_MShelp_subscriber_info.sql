SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MShelp_subscriber_info]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MShelp_subscriber_info] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MShelp_subscriber_info]
	@publisher [sysname],
	@subscriber [sysname],
	@found [int] OUTPUT,
	@show_password [bit]
WITH EXECUTE AS CALLER
AS
begin
   set nocount on
   
   DECLARE @no_rows bit

	--
	-- push agents (dist or merge) may call this.
	-- raise an message indicating that users may forget to specify -SubscriptionType
	-- security check
	--
	if is_member(N'db_owner') <> 1
	begin
		raiserror (20604, 16, -1)
		return 1
	end
	/*
	** Initializations.
	*/
	IF @found is NULL
	BEGIN
		SELECT @no_rows=0
	END
	ELSE
	BEGIN
		SELECT @no_rows=1
	END

   if exists (select * from MSsubscriber_info 
			   where (@publisher = '%' or UPPER(publisher) = UPPER(@publisher)) 
				 and (@subscriber = '%' or UPPER(subscriber) = UPPER(@subscriber)))
   begin
		select @found = 1
		if @no_rows <>0 return(0)
   end
   else
   begin
		select @found = 0
		if @no_rows <>0 return(0)
   end

   if exists (select * from MSsubscriber_schedule 
			   where (@publisher = N'%' or UPPER(publisher) = UPPER(@publisher))
				 and (@subscriber = N'%' or UPPER(subscriber) = UPPER(@subscriber)))
	begin
		select Sinfo.publisher,
				Sinfo.subscriber,
				Sinfo.type,
				Sinfo.login,
				case when @show_password = 1 then sys.fn_repldecryptver4(Sinfo.password)
				else convert(sysname, NULL) end,
				100,  -- commit_batch_size, no longer supported
				100,  -- status_batch_size, no longer supported
				1,    -- flush_frequency, no longer supported
				sch1.frequency_type, 
				sch1.frequency_interval,
				sch1.frequency_relative_interval,
				sch1.frequency_recurrence_factor,
				sch1.frequency_subday,
				sch1.frequency_subday_interval,
				sch1.active_start_time_of_day,
				sch1.active_end_time_of_day,
				sch1.active_start_date,
				sch1.active_end_date,
				4, -- retryattempt, no longer exist
				4,  -- retrydelay, no longer exist
				Sinfo.description,
				Sinfo.security_mode,
				sch2.frequency_type as frequency_type2, 
				sch2.frequency_interval as frequency_interval2,
				sch2.frequency_relative_interval as frequency_relative_interval2,
				sch2.frequency_recurrence_factor as frequency_recurrence_factor2,
				sch2.frequency_subday as frequency_subday2,
				sch2.frequency_subday_interval as frequency_subday_interval2,
				sch2.active_start_time_of_day as active_start_time_of_day2,
				sch2.active_end_time_of_day as active_end_time_of_day2,
				sch2.active_start_date as active_start_date2,
				sch2.active_end_date as active_end_date2
			from (MSsubscriber_info as Sinfo LEFT OUTER JOIN MSsubscriber_schedule as sch1 
			on UPPER(Sinfo.publisher)=UPPER(sch1.publisher) AND UPPER(Sinfo.subscriber)=UPPER(sch1.subscriber) and sch1.agent_type=0)
			LEFT OUTER JOIN MSsubscriber_schedule as sch2
				on UPPER(Sinfo.publisher)=UPPER(sch2.publisher) AND UPPER(Sinfo.subscriber)=UPPER(sch2.subscriber) 
						and sch2.agent_type=1
			where (@publisher = N'%' or UPPER(Sinfo.publisher) = UPPER(@publisher)) and 
			  (@subscriber = N'%' or UPPER(Sinfo.subscriber) = UPPER(@subscriber))                 
		if @@error <> 0 return 1
	end
end
GO
GRANT EXECUTE ON [sys].[sp_MShelp_subscriber_info] TO [public] AS [dbo]
GO
