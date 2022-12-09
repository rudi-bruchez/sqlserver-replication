SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_help_agent_parameter]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_help_agent_parameter] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_help_agent_parameter]
	@profile_id [int]
WITH EXECUTE AS CALLER
AS
set nocount on

	-- Security Check: Must be sysadmin or the replmonitor
	if isnull(is_member(N'replmonitor'),0) = 0 and isnull(is_srvrolemember(N'sysadmin'),0) = 0
	begin
	  RAISERROR(14260,16,-1) 
	  return 1
	end
	
	if @profile_id = -1
	begin   
		select profile_id, parameter_name, value
		from msdb..MSagent_parameters
		order by profile_id, parameter_name
	end
	else
	begin
		select profile_id, parameter_name, value
		from msdb..MSagent_parameters
		where profile_id = @profile_id
		order by profile_id, parameter_name
	end
GO
GRANT EXECUTE ON [sys].[sp_help_agent_parameter] TO [public] AS [dbo]
GO
