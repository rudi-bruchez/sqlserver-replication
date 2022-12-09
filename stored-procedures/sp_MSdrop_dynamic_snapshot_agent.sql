SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSdrop_dynamic_snapshot_agent]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSdrop_dynamic_snapshot_agent] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSdrop_dynamic_snapshot_agent]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@agent_id [int]
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
	declare @no_of_agents int

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
		raiserror(21482, 16, -1, 'sp_MSdrop_dynamic_snapshot_agent', 'distribution')
		return (1)
	end

    /*
    ** Initializations
    */
    select @publisher_id = srvid from MSreplservers where
        UPPER(srvname) = UPPER(@publisher)

	SELECT @job_id = job_id, @job_step_uid = job_step_uid, @local_job = local_job, @name = name  FROM MSsnapshot_agents WHERE
		publisher_id = @publisher_id AND
		publisher_db = @publisher_db AND
		publication = @publication and
		id = @agent_id

	-- Delete Perfmon instance
	dbcc deleteinstance ("SQL Replication Snapshot", @name)

	-- Return if not exists
	IF @local_job IS NULL
		RETURN(0)

	BEGIN TRAN

	IF @local_job = 1
	BEGIN
		IF EXISTS (SELECT * FROM msdb.dbo.sysjobs_view WHERE job_id = @job_id)
		BEGIN                
			EXEC @retcode = sys.sp_MSdrop_repl_job @job_id = @job_id,
													@job_step_uid = @job_step_uid
			IF @@ERROR <> 0 or @retcode <> 0
				GOTO UNDO
		END
	END

	DELETE MSsnapshot_agents WHERE id = @agent_id
	IF @@ERROR <> 0 
		GOTO UNDO

	-- Remove history
	DELETE MSsnapshot_history WHERE agent_id = @agent_id
	IF @@ERROR <> 0 
		GOTO UNDO
		
	COMMIT TRAN
	RETURN(0)

UNDO:
	if @@TRANCOUNT = 1
		ROLLBACK TRAN
	else
		COMMIT TRAN
	return(1)
end
GO
GRANT EXECUTE ON [sys].[sp_MSdrop_dynamic_snapshot_agent] TO [public] AS [dbo]
GO
