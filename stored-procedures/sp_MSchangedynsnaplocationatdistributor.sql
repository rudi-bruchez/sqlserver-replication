SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSchangedynsnaplocationatdistributor]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSchangedynsnaplocationatdistributor] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSchangedynsnaplocationatdistributor]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@dynamic_filter_login [sysname],
	@dynamic_filter_hostname [sysname],
	@dynamic_snapshot_location [nvarchar](255)
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
	declare @command_line nvarchar(4000)
	declare @str_jobid nvarchar(40)
	
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
		raiserror(21482, 16, -1, 'sp_MSchangedynsnaplocationatdistributor', 'distribution')
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

	select @str_jobid = convert(nvarchar(40),@job_id)
	
	-- Change the dynamic snapshot location parameter in the job step
	select @command_line = command from msdb.dbo.sysjobsteps 
		where step_uid = @job_step_uid and job_id = @job_id
	if @command_line is NULL
	begin
		raiserror(20724, 16, -1, @str_jobid, @publication)
		goto UNDO
	end

	SELECT @command_line = sys.fn_updateparameterwithargument(@command_line, N'DynamicSnapshotLocation', sys.fn_replquotename(@dynamic_snapshot_location, default) collate database_default )
	if @@error <> 0
	begin
		raiserror(20725, 16, -1, @str_jobid, @publication)
		goto UNDO
	end

	UPDATE msdb.dbo.sysjobsteps
		SET command = @command_line
		WHERE job_id = @job_id
			AND step_uid = @job_step_uid
	if @@error <> 0
	begin
		raiserror(20725, 16, -1, @str_jobid, @publication)
		goto UNDO
	end
	
	RETURN(0)

UNDO:
	return(1)
end
GO
GRANT EXECUTE ON [sys].[sp_MSchangedynsnaplocationatdistributor] TO [public] AS [dbo]
GO
