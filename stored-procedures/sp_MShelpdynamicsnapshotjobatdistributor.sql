SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MShelpdynamicsnapshotjobatdistributor]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MShelpdynamicsnapshotjobatdistributor] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MShelpdynamicsnapshotjobatdistributor]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@dynamic_filter_login [sysname],
	@dynamic_filter_hostname [sysname],
	@frequency_type [int] OUTPUT,
	@frequency_interval [int] OUTPUT,
	@frequency_subday [int] OUTPUT,
	@frequency_subday_interval [int] OUTPUT,
	@frequency_relative_interval [int] OUTPUT,
	@frequency_recurrence_factor [int] OUTPUT,
	@active_start_date [int] OUTPUT,
	@active_end_date [int] OUTPUT,
	@active_start_time_of_day [int] OUTPUT,
	@active_end_time_of_day [int] OUTPUT
WITH EXECUTE AS CALLER
AS
begin
	set nocount on

	declare @retcode int
	declare @job_id uniqueidentifier
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
		raiserror(21482, 16, -1, 'sp_MShelpdynamicsnapshotjobatdistributor', 'distribution')
		return (1)
	end

	if @dynamic_filter_login is NULL and @dynamic_filter_hostname is NULL
	begin
		raiserror(20653, 16, -1)
		return 1
	end
	
	select @retcode = 0

    SELECT @publisher_id = srvid 
      FROM MSreplservers
     WHERE UPPER(srvname) = UPPER(@publisher)
    IF @publisher_id IS  NULL
    BEGIN
        RAISERROR(21169, 16, -1, @publisher, @@SERVERNAME, @publisher)    
    END

	select @job_id = job_id,
		   @publication_type = publication_type
	  from MSsnapshot_agents
	 where publisher_id = @publisher_id and 
		   publication = @publication and 
		   publisher_db = @publisher_db and
		   ((@dynamic_filter_login is NULL and dynamic_filter_login is NULL) or dynamic_filter_login = @dynamic_filter_login)  and
		   ((@dynamic_filter_hostname is NULL and dynamic_filter_hostname is NULL) or dynamic_filter_hostname = @dynamic_filter_hostname)
	if @job_id is NULL
	begin
		raiserror(21325, 11, -1)
		return 1
	end
	
	if @publication_type <> 2
	begin
		raiserror(20654, 16, -1)
		return 1
	end

	select @frequency_type = ss.freq_type,
		   @frequency_interval = ss.freq_interval,
		   @frequency_subday = ss.freq_subday_type,
		   @frequency_subday_interval = ss.freq_subday_interval,
		   @frequency_relative_interval = ss.freq_relative_interval,
		   @frequency_recurrence_factor = ss.freq_recurrence_factor,
		   @active_start_date = ss.active_start_date,
		   @active_end_date = ss.active_end_date,
		   @active_start_time_of_day = ss.active_start_time,
		   @active_end_time_of_day = ss.active_end_time
	from msdb..sysjobs sjb, msdb..sysjobschedules sjs, msdb..sysschedules ss
	where sjb.job_id = @job_id and
		  sjs.job_id = sjb.job_id and
		  ss.schedule_id = sjs.schedule_id

	
	RETURN(0)

UNDO:
	return(1)
end
GO
GRANT EXECUTE ON [sys].[sp_MShelpdynamicsnapshotjobatdistributor] TO [public] AS [dbo]
GO
