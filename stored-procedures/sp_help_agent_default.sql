SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_help_agent_default]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_help_agent_default] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_help_agent_default]
	@profile_id [int] OUTPUT,
	@agent_type [int]
WITH EXECUTE AS CALLER
AS
begin
	set nocount on

   -- Security Check: Must be sysadmin or the replmonitor
   if isnull(is_member(N'replmonitor'),0) = 0 and isnull(is_srvrolemember(N'sysadmin'),0) = 0
   begin
	 RAISERROR(14260,16,-1) 
	 return 1
   end

	if @agent_type not in (1, 2, 3, 4, 9)
	BEGIN
		RAISERROR(20058, 16, -1)
		return (1)
	END

	select @profile_id = profile_id 
	from msdb.dbo.MSagent_profiles 
	where agent_type = @agent_type
	and def_profile = 1 
end
GO
GRANT EXECUTE ON [sys].[sp_help_agent_default] TO [public] AS [dbo]
GO
