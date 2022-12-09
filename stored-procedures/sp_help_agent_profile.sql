SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_help_agent_profile]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_help_agent_profile] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_help_agent_profile]
	@agent_type [int],
	@profile_id [int]
WITH EXECUTE AS CALLER
AS
set nocount on

	declare @proc nvarchar(255)

	declare @snapshot_type      int
	declare @logreader_type     int
	declare @distribution_type  int
	declare @merge_type     int
	declare @qreader_type       int

	select @snapshot_type = 1
	select @logreader_type = 2
	select @distribution_type = 3
	select @merge_type = 4
	select @qreader_type = 9

   -- Security Check: Must be sysadmin or the replmonitor
   if isnull(is_member(N'replmonitor'),0) = 0 and isnull(is_srvrolemember(N'sysadmin'),0) = 0
   begin
	 RAISERROR(14260,16,-1) 
	 return 1
   end

	if @agent_type is null 
	BEGIN
		RAISERROR (14043, 16, -1, '@agent_type', 'sp_help_agent_profile')
		RETURN (1)
	END

	if @profile_id is null
	BEGIN
		RAISERROR (14043, 16, -1, '@profile_id', 'sp_help_agent_profile')
		RETURN (1)
	END

	if @agent_type not in (0, @snapshot_type, @logreader_type, @distribution_type, @merge_type, @qreader_type)
	BEGIN
		RAISERROR(20058, 16, -1)
		return (1)
	END

	select profile_id, profile_name, agent_type, type, description, def_profile
		from msdb.dbo.MSagent_profiles where
			 (profile_id = @profile_id or @profile_id = -1) and
			 (agent_type = @agent_type or @agent_type = 0)
		order by profile_id, profile_name

GO
GRANT EXECUTE ON [sys].[sp_help_agent_profile] TO [public] AS [dbo]
GO
