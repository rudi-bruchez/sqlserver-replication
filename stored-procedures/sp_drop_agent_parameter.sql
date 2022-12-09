SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_drop_agent_parameter]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_drop_agent_parameter] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_drop_agent_parameter]
	@profile_id [int],
	@parameter_name [sysname]
WITH EXECUTE AS CALLER
AS
set nocount on

	declare @default            bit
	declare @agent_type         int
	declare @retstatus          int
	select @retstatus = 0

	/*
	** Security Check: require sysadmin
	*/
	IF (ISNULL(IS_SRVROLEMEMBER('sysadmin'),0) = 0)
	BEGIN
		RAISERROR(21089,16,-1) 
		RETURN (1)
	END

	if @parameter_name is null
	BEGIN
		RAISERROR (14043, 16, -1, '@parameter_name', 'sp_drop_agent_parameter')
		RETURN (1)
	END

	select @agent_type = agent_type, @default=def_profile
	from msdb..MSagent_profiles
	where profile_id = @profile_id

	if @default is null
	BEGIN
		RAISERROR (20066, 16, -1) -- profile not defined
		RETURN (1)
	END
	
	select @parameter_name = lower(@parameter_name collate SQL_Latin1_General_CP1_CS_AS)

	if left(@parameter_name,1) in (N'-', N'/')
		select @parameter_name = right(@parameter_name,len(@parameter_name)-1)

	/* Delete the parameters of the profile */
	delete  msdb..MSagent_parameters 
	where   right(lower(parameter_name collate SQL_Latin1_General_CP1_CS_AS),len(parameter_name)-1) like 
			@parameter_name collate SQL_Latin1_General_CP1_CS_AS
	and     profile_id = @profile_id

	if @@error <> 0
	begin
		select @retstatus = 1
		goto UNDO
	end

UNDO:
	
	return @retstatus
GO
GRANT EXECUTE ON [sys].[sp_drop_agent_parameter] TO [public] AS [dbo]
GO
