SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSenum_replication_job]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSenum_replication_job] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSenum_replication_job]
	@job_id [uniqueidentifier],
	@step_uid [uniqueidentifier]
WITH EXECUTE AS CALLER
AS
begin
	SET NOCOUNT ON
	
	declare @retcode 		int
			,@time 			int
			,@date 			int
			,@datetime		nvarchar(50)
			,@runstatus 	int
			,@message 		nvarchar(1024)
			,@job_name		sysname
			,@session_id 	int
			,@job_found		bit
				
	--
	-- security check
	--
	exec @retcode = sys.sp_MSreplcheck_subscribe
	if @@ERROR <> 0 or @retcode <> 0
	begin
		return(1)
	end

	-- check that the user has permission to view this job information
	exec @retcode = sys.sp_MSrepl_check_job_access @id = @job_id,
													@err_not_found = 0,
													@step_uid = @step_uid,
													@job_found = @job_found output		
	if @@ERROR <> 0 or @retcode <> 0
	begin
		return(1)
	end

	
	if @job_found = 1
	begin
		-- retrieve the lastest session id (New session id on every start of sqlagent service)
		select top(1) @session_id = session_id 
			from msdb..syssessions 
			order by agent_start_date desc

		-- retrieve current runstatus, message and date time	
		select @runstatus 	= case 
								when sysja.run_requested_date is NULL then 5								-- Case when job has never been run but sqlagent is started
								when sysja.job_history_id is not NULL and sysjh.run_status is NULL then 5	-- Case when job has been run but history has been truncated
								else isnull(sysjh.run_status, 4)											-- Normal case...
							end,
				@message 	= isnull(nullif(ltrim(sysjh.message), N''), formatmessage(14243, sysj.name)),							
				@date 		= convert(int, convert(nvarchar(4000), sysja.start_execution_date, 112)),
				@time 		= convert(int, replace(convert(nvarchar(4000), sysja.start_execution_date, 8), ':', '')),
				@datetime 	= replace(convert(nvarchar(4000), sysja.start_execution_date, 21), '-', ''),
				@job_name	= sysj.name
			from msdb.dbo.sysjobactivity sysja 
				join msdb.dbo.sysjobs sysj
					on sysja.job_id = sysj.job_id
				left join msdb.dbo.sysjobhistory sysjh
					on sysja.job_id = sysjh.job_id
						and sysja.job_history_id = sysjh.instance_id
			where sysja.job_id = @job_id
				and sysja.session_id = @session_id

		-- Map SQL Agent runstatus to Replication runstatus
		select @runstatus 	= case @runstatus
									when 0 then 6   -- Fail mapping
									when 1 then 2   -- Success mapping
									when 2 then 5   -- Retry mapping
									when 3 then 2   -- Shutdown mapping
									when 4 then 3   -- Inprogress mapping
									when 5 then 0   -- Unknown is mapped to never run
								end
	end
	else
	begin
		select @runstatus	= NULL, 
				@message	= NULL,	  
				@date		= NULL, 
				@time		= NULL, 
				@datetime	= NULL
	end

	-- Return status and message
	select 'runstatus' 	= @runstatus, 
			'message'  	= @message,  
			'date'  	= @date, 
			'time'  	= @time, 
			'datetime' 	= @datetime
	
	-- all done
	return 0
end
GO
GRANT EXECUTE ON [sys].[sp_MSenum_replication_job] TO [public] AS [dbo]
GO
