SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSdynamicsnapshotjobexistsatdistributor]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSdynamicsnapshotjobexistsatdistributor] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSdynamicsnapshotjobexistsatdistributor]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@dynamic_filter_login [sysname],
	@dynamic_filter_hostname [sysname],
	@dynamic_snapshot_jobid [uniqueidentifier] OUTPUT
WITH EXECUTE AS CALLER
AS
begin
	set nocount on

	declare @job_id uniqueidentifier
	declare @publisher_id int
	
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
		raiserror(21482, 16, -1, 'sp_MSdynamicsnapshotjobexistsatdistributor', 'distribution')
		return (1)
	end

    if @dynamic_filter_login is NULL and @dynamic_filter_hostname is NULL
    begin
        raiserror(20653, 16, -1)
        return 1
    end
    
    SELECT @publisher_id = srvid 
      FROM MSreplservers
     WHERE UPPER(srvname) = UPPER(@publisher)
    IF @publisher_id IS  NULL
    BEGIN
        RAISERROR(21169, 16, -1, @publisher, @@SERVERNAME, @publisher)    
    END

	select @job_id = job_id
	  from MSsnapshot_agents
	 where publisher_id = @publisher_id and 
		   publication = @publication and 
		   publisher_db = @publisher_db and
		   ((@dynamic_filter_login is NULL and dynamic_filter_login is NULL) or dynamic_filter_login = @dynamic_filter_login)  and
		   ((@dynamic_filter_hostname is NULL and dynamic_filter_hostname is NULL) or dynamic_filter_hostname = @dynamic_filter_hostname) and
		   publication_type = 2
	if @job_id is NULL or
		not exists (select 1 from msdb..sysjobs where job_id = @job_id)
		select @dynamic_snapshot_jobid = null
	else
		select @dynamic_snapshot_jobid = @job_id
	
	RETURN(0)
end
GO
GRANT EXECUTE ON [sys].[sp_MSdynamicsnapshotjobexistsatdistributor] TO [public] AS [dbo]
GO
