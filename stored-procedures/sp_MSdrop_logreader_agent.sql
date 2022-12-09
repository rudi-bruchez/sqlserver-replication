SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSdrop_logreader_agent]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSdrop_logreader_agent] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSdrop_logreader_agent]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname]
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
        raiserror(21482, 16, -1, 'sp_MSdrop_logreader_agent', 'distribution')
        return (1)
    end
    /*
    ** Initializations
    */
    select @publisher_id = srvid from MSreplservers where
        UPPER(srvname) = UPPER(@publisher)


	SELECT @job_id = job_id, @job_step_uid = job_step_uid, @local_job = local_job, @name = name, @agent_id = id FROM MSlogreader_agents WHERE
		publisher_id = @publisher_id AND
		publisher_db = @publisher_db AND
		publication = @publication

	-- Delete Perfmon instance
	dbcc deleteinstance ("SQL Replication Logreader", @name)

	-- Return if not exists
	IF @local_job IS NULL
		RETURN(0)

	BEGIN TRAN

	IF @local_job = 1
	BEGIN
		-- Don't drop the job for third party publications.
		if exists (select * from msdb..MSdistpublishers where 
			UPPER(name) = UPPER(@publisher) and
			thirdparty_flag = 0)
		begin                           
			IF EXISTS (SELECT * FROM msdb.dbo.sysjobs_view WHERE job_id = @job_id)
			BEGIN
				-- Checks if the job name matches one that is generated 
				-- by replication
				EXEC @retcode = sys.sp_MSislogreaderjobnamegenerated
									@publisher = @publisher,
									@publisher_db = @publisher_db,
									@job_id = @job_id
				IF @@ERROR <> 0 
					GOTO UNDO
				
				-- Only drop the job if the name was generated
				IF @retcode = 0
				BEGIN
					EXEC @retcode = sys.sp_MSdrop_repl_job @job_id = @job_id,
															@job_step_uid = @job_step_uid
					IF @@ERROR <> 0 or @retcode <> 0
						GOTO UNDO
				END
			END
		end
	END

	DELETE MSlogreader_agents WHERE id = @agent_id
	IF @@ERROR <> 0 
		GOTO UNDO

	-- Remove history
	DELETE MSlogreader_history WHERE
		agent_id = @agent_id

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
GRANT EXECUTE ON [sys].[sp_MSdrop_logreader_agent] TO [public] AS [dbo]
GO
