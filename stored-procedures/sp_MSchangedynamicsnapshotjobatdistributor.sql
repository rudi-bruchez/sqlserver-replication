SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSchangedynamicsnapshotjobatdistributor]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSchangedynamicsnapshotjobatdistributor] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSchangedynamicsnapshotjobatdistributor]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@dynamic_filter_login [sysname],
	@dynamic_filter_hostname [sysname],
	@frequency_type [int],
	@frequency_interval [int],
	@frequency_subday [int],
	@frequency_subday_interval [int],
	@frequency_relative_interval [int],
	@frequency_recurrence_factor [int],
	@active_start_date [int],
	@active_end_date [int],
	@active_start_time_of_day [int],
	@active_end_time_of_day [int],
	@job_login [nvarchar](257),
	@job_password [sysname]
WITH EXECUTE AS CALLER
AS
begin
	set nocount on

	declare @retcode int
	declare @agent_id int
	declare @job_id uniqueidentifier
	declare @job_step_uid uniqueidentifier
	declare @publisher_id int
	declare @publication_type int
	
	--
	-- security check
	-- only db_owner can execute this
	--
	if (is_srvrolemember('sysadmin') != 1) 
	begin
		raiserror(14260, 16, -1)
		return (1)
	end
	--
	-- security check
	-- Has to be executed from distribution database
	--
	if (sys.fn_MSrepl_isdistdb (db_name()) != 1)
	begin
		raiserror(21482, 16, -1, 'sp_MSchangedynamicsnapshotjobatdistributor', 'distribution')
		return (1)
	end

	if @dynamic_filter_login is NULL and @dynamic_filter_hostname is NULL
	begin
		raiserror(20653, 16, -1)
		return 1
	end
	
	select @retcode = 0
	select @agent_id = null

    SELECT @publisher_id = srvid 
      FROM MSreplservers
     WHERE UPPER(srvname) = UPPER(@publisher)
    IF @publisher_id IS  NULL
    BEGIN
        RAISERROR(21169, 16, -1, @publisher, @@SERVERNAME, @publisher)    
    END
    
    -- Get the publication details from the agent for regular snapshot  
    select @agent_id = id,
           @job_id = job_id,
           @job_step_uid = job_step_uid,
           @publication_type = publication_type
      from MSsnapshot_agents
     where publisher_id = @publisher_id and 
           publication = @publication and 
           publisher_db = @publisher_db and
          ((@dynamic_filter_login is NULL and dynamic_filter_login is NULL) or dynamic_filter_login = @dynamic_filter_login)  and
          ((@dynamic_filter_hostname is NULL and dynamic_filter_hostname is NULL) or dynamic_filter_hostname = @dynamic_filter_hostname)
    if @agent_id is null or @job_id is NULL
    begin
        raiserror(21325, 11, -1)
        return 1
    end

	if @publication_type <> 2
	begin
		raiserror(20654, 16, -1)
		return 1
	end

	-- Change the job
	exec @retcode = sys.sp_MSchange_repl_job @id 							= @job_id,
											@step_uid						= @job_step_uid,
											@name 							= NULL,
											@frequency_type 				= @frequency_type,
											@frequency_interval 			= @frequency_interval,
											@frequency_subday				= @frequency_subday,
											@frequency_subday_interval		= @frequency_subday_interval,
											@frequency_relative_interval	= @frequency_relative_interval,
											@frequency_recurrence_factor	= @frequency_recurrence_factor,
											@active_start_date				= @active_start_date,
											@active_end_date				= @active_end_date,
											@active_start_time_of_day		= @active_start_time_of_day,
											@active_end_time_of_day 		= @active_end_time_of_day,
											@login							= @job_login,
											@password						= @job_password

	if @retcode <> 0 or @@error <> 0
		goto UNDO
	
	RETURN(0)

UNDO:
	return(1)
end
GO
GRANT EXECUTE ON [sys].[sp_MSchangedynamicsnapshotjobatdistributor] TO [public] AS [dbo]
GO
