SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_drop_agent_profile]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_drop_agent_profile] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_drop_agent_profile]
	@profile_id [int]
WITH EXECUTE AS CALLER
AS
SET NOCOUNT ON

	declare @snapshot_type      int
	declare @logreader_type     int
	declare @distribution_type  int
	declare @merge_type         int
	declare @qreader_type       int
	
	declare @tablename          nvarchar(255)
	declare @proc               nvarchar(255)
	declare @distribution_db    sysname
	declare @profile_type       int

	declare @default            bit
	declare @usage_count        int
	declare @agent_type         int
	declare @retstatus          int
	DECLARE @retcode            int

	declare @default_sys_id     int

	/*
	** Security Check: require sysadmin
	*/
	IF (ISNULL(IS_SRVROLEMEMBER('sysadmin'),0) = 0)
	BEGIN
		RAISERROR(21089,16,-1) 
		RETURN (1)
	END

	SELECT @agent_type = agent_type, @profile_type = type, @default=def_profile
	FROM msdb..MSagent_profiles
	WHERE profile_id = @profile_id

	IF @default IS NULL
	BEGIN
		RAISERROR (20066, 16, -1) -- Profile not defined
		RETURN (1)
	END

	/*
	** Before dropping a default profile, one system profile of the same agent type
	** has to become the new default profile.
	*/
	IF @default = 1
	BEGIN
		select @default_sys_id=min(profile_id) from msdb..MSagent_profiles
			where agent_type = @agent_type AND type = 0
			
		UPDATE msdb..MSagent_profiles SET def_profile = 1 WHERE profile_id = @default_sys_id
	END

	select @snapshot_type = 1
	select @logreader_type = 2
	select @distribution_type = 3
	select @merge_type = 4
	select @qreader_type = 9

		/* By default, assume that this profile is not being used */
	select @usage_count = -1

	select @tablename = 
		case @agent_type
			when @snapshot_type then 'MSsnapshot_agents'
			when @logreader_type then 'MSlogreader_agents'
			when @distribution_type then 'MSdistribution_agents'
			when @merge_type then 'MSmerge_agents'
			when @qreader_type then 'MSqreader_agents'
		end

	declare hCdistdbs CURSOR LOCAL FAST_FORWARD FOR
		select distinct distribution_db 
		from msdb..MSdistpublishers
		for read only

	open hCdistdbs
	fetch hCdistdbs into @distribution_db

	while @@fetch_status <> -1 and @usage_count = -1
	begin
		select @proc = QUOTENAME(@distribution_db) + '.dbo.sp_MSprofile_in_use'
		execute @usage_count = @proc @tablename = @tablename, @profile_id = @profile_id
	
		if @@error <> 0
		begin
			select @retstatus = 1
			goto UNDO
		end

		fetch hCdistdbs into @distribution_db
	end

	/* A profile in use cannot be dropped */
	if @usage_count = 0 
	begin
		RAISERROR(20065, 16, -1) -- Cannot drop profile, because it is in use.
		select @retstatus = 1
		goto UNDO 
	end

	BEGIN TRAN

	/*****
	 * NOTE : If sp_drop_agent_parameter fails, the profile must not be 
	 * deleted either 
	 */
	EXECUTE @retcode = sys.sp_drop_agent_parameter @profile_id = @profile_id,
							@parameter_name = '%'

	IF @@ERROR <> 0 OR @retcode <> 0
		GOTO UNDO
			
	/* Delete all the entries in one go */
	DELETE msdb..MSagent_profiles 
	WHERE profile_id = @profile_id

	IF @@ERROR <> 0
		GOTO UNDO

	COMMIT TRAN

	close hCdistdbs
	deallocate hCdistdbs

	RETURN 0

UNDO:
	IF @@TRANCOUNT = 1
		ROLLBACK TRAN
	ELSE IF @@TRANCOUNT > 1 -- Sometimes we can get here when @@trancount = 0, so need to check explicitly.
		COMMIT TRAN

	close hCdistdbs
	deallocate hCdistdbs


	RETURN (1)
GO
GRANT EXECUTE ON [sys].[sp_drop_agent_profile] TO [public] AS [dbo]
GO
