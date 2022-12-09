SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MScheck_snapshot_agent]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MScheck_snapshot_agent] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MScheck_snapshot_agent]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@valid_agent_exists [bit] OUTPUT
WITH EXECUTE AS CALLER
AS
begin

	SET NOCOUNT ON

	/*
	** Declarations.
	*/
	DECLARE @retcode    int
	DECLARE @job_id     binary(16)
	DECLARE @job_step_uid uniqueidentifier
	DECLARE @local_job  bit
	DECLARE @publisher_id smallint
	DECLARE @name       nvarchar(100)
	DECLARE @agent_id   int

	--
	-- security check
	-- only db_owner can execute this
	--
	if (is_member ('db_owner') != 1) 
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
		raiserror(21482, 16, -1, 'sp_MScheck_snapshot_agent', 'distribution')
		return (1)
	end

    select @valid_agent_exists = 0
    
    /*
    ** Initializations
    */
    select @publisher_id = srvid from MSreplservers where
        UPPER(srvname) = UPPER(@publisher)

	-- Look for the regular snapshot agen
	SELECT @job_id = job_id, @job_step_uid = job_step_uid, @local_job = local_job, @name = name, @agent_id = id  FROM MSsnapshot_agents WHERE
		publisher_id = @publisher_id AND
		publisher_db = @publisher_db AND
		publication = @publication and
		dynamic_filter_login is NULL and
		dynamic_filter_hostname is NULL
		
	-- Return if not exists
	IF @local_job IS NULL
		return(0)

	IF @local_job = 1 and EXISTS (SELECT * FROM msdb.dbo.sysjobs_view WHERE job_id = @job_id)
		select @valid_agent_exists = 1

	return 0
end
GO
GRANT EXECUTE ON [sys].[sp_MScheck_snapshot_agent] TO [public] AS [dbo]
GO
