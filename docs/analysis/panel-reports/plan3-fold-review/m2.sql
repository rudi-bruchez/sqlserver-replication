SET NOCOUNT ON;
USE master;
DECLARE @b int, @rc int;
BEGIN TRAN;
BEGIN TRY
  EXEC sp_add_agent_profile @profile_id = @b OUTPUT, @profile_name = N'rv_fxk3q1_b', @agent_type = 3, @profile_type = 1;
  EXEC @rc = sp_change_agent_parameter @profile_id = @b, @parameter_name = N'-PacketSize', @parameter_value = N'8192';
  SELECT 'change_missing_rc' k, @rc rc, (SELECT COUNT(*) FROM msdb.dbo.MSagent_parameters WHERE profile_id=@b AND parameter_name=N'-PacketSize') present;
  EXEC @rc = sp_drop_agent_parameter @profile_id = @b, @parameter_name = N'-QueryTimeout';
  SELECT 'drop_copied_rc' k, @rc rc, (SELECT COUNT(*) FROM msdb.dbo.MSagent_parameters WHERE profile_id=@b) n;
END TRY
BEGIN CATCH
  SELECT 'err' k, ERROR_NUMBER() n, ERROR_MESSAGE() m;
END CATCH
ROLLBACK;
SELECT 'after' k, @@TRANCOUNT tc, (SELECT COUNT(*) FROM msdb.dbo.MSagent_profiles WHERE profile_name LIKE N'rv[_]fx%') residue;
