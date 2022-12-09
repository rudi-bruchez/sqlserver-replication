SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_add_agent_profile]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_add_agent_profile] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_add_agent_profile]
	@profile_id [int] OUTPUT,
	@profile_name [sysname],
	@agent_type [int],
	@profile_type [int],
	@description [nvarchar](3000),
	@default [bit]
WITH EXECUTE AS CALLER
AS
SET NOCOUNT ON

	declare     @sys_profile    int
	declare     @default_id     int
	declare     @sysdefault_id  int
	declare     @retcode        int

	/*
	** Security Check: require sysadmin
	*/
	IF (ISNULL(IS_SRVROLEMEMBER('sysadmin'),0) = 0)
	BEGIN
		RAISERROR(21089,16,-1) 
		RETURN (1)
	END

	SELECT @profile_name = RTRIM(@profile_name)

	exec @retcode = sys.sp_MSreplcheck_name @profile_name, '@profile_name', 'sp_add_agent_profile'
	if @@ERROR <> 0 or @retcode <> 0
		return(1)

	/* The profile name is unique across a particular agent type */
	IF EXISTS ( SELECT * FROM msdb..MSagent_profiles 
			WHERE profile_name = @profile_name collate database_default
			AND agent_type = @agent_type )
	BEGIN
		RAISERROR(20057, 16, -1, @profile_name)
		RETURN (1)
	END

	IF @agent_type NOT IN (1, 2, 3, 4, 9)
	BEGIN
		RAISERROR(20058, 16, -1)
		return (1)
	END

	IF @profile_type NOT IN (0, 1)
	BEGIN
		RAISERROR(20059, 16, -1)
		return (1)
	END

	BEGIN TRAN

	/*
	** First find out the default profile of the same agent type
	*/
	select @default_id = profile_id from msdb..MSagent_profiles WHERE agent_type = @agent_type AND def_profile = 1
	
	INSERT INTO msdb..MSagent_profiles
			VALUES (@profile_name, @agent_type, @profile_type, @description, 0)
	IF @@ERROR <> 0
		GOTO UNDO

	SELECT @profile_id = profile_id 
		FROM msdb..MSagent_profiles
		WHERE profile_name = @profile_name collate database_default AND agent_type = @agent_type

	/*
	** If there is system profiles of the same agent type, use the primary system one as template of parameter set
	*/
	IF EXISTS (select * from msdb..MSagent_profiles where agent_type = @agent_type AND type = 0)
		select @sysdefault_id = min(profile_id) from msdb..MSagent_profiles where agent_type = @agent_type AND type = 0

	if @sysdefault_id IS NULL
		select @sysdefault_id = @default_id

	if @profile_type=1
	BEGIN
		INSERT INTO msdb..MSagent_parameters 
			select @profile_id, parameter_name, value from msdb..MSagent_parameters 
				where profile_id = @sysdefault_id      
		if @@ERROR<>0 
			GOTO UNDO
	END

	/* Only one profile for an agent type must be default */
	IF @default = 1
		BEGIN
			UPDATE msdb..MSagent_profiles
				SET def_profile = 0 WHERE profile_id = @default_id
			IF @@ERROR <> 0
				GOTO UNDO
			UPDATE msdb..MSagent_profiles
				SET def_profile = 1 WHERE profile_id = @profile_id
			IF @@ERROR <> 0
				GOTO UNDO
		END

	COMMIT TRAN
	RETURN 0 

UNDO:

	IF @@TRANCOUNT = 1
		ROLLBACK TRAN
	ELSE
		COMMIT TRAN

	RETURN 1 
GO
GRANT EXECUTE ON [sys].[sp_add_agent_profile] TO [public] AS [dbo]
GO
