SET NOCOUNT ON; SET XACT_ABORT OFF;
USE master;
DECLARE @a int, @b int, @rc int;
BEGIN TRAN;
BEGIN TRY
  EXEC sp_add_agent_profile @profile_id = @a OUTPUT, @profile_name = N'rv_fxk3q1_a', @agent_type = 3, @profile_type = 1, @default = 1;
  EXEC sp_change_agent_parameter @profile_id = @a, @parameter_name = N'-CommitBatchSize', @parameter_value = N'500';
  EXEC sp_add_agent_parameter @profile_id = @a, @parameter_name = N'-PacketSize', @parameter_value = N'8192';
  SELECT 'def_now' k, profile_name, def_profile FROM msdb.dbo.MSagent_profiles WHERE agent_type = 3 AND def_profile = 1;
  EXEC sp_add_agent_profile @profile_id = @b OUTPUT, @profile_name = N'rv_fxk3q1_b', @agent_type = 3, @profile_type = 1;
  SELECT 'b_params' k, COUNT(*) n, MAX(CASE WHEN parameter_name = N'-CommitBatchSize' THEN value END) cbs, MAX(CASE WHEN parameter_name = N'-PacketSize' THEN value END) ps FROM msdb.dbo.MSagent_parameters WHERE profile_id = @b;
  -- change of a parameter the profile does not have
  EXEC @rc = sp_change_agent_parameter @profile_id = @b, @parameter_name = N'-OledbStreamThreshold', @parameter_value = N'1';
  SELECT 'change_missing_rc' k, @rc rc, (SELECT COUNT(*) FROM msdb.dbo.MSagent_parameters WHERE profile_id=@b AND parameter_name=N'-OledbStreamThreshold') present;
END TRY
BEGIN CATCH
  SELECT 'err' k, ERROR_NUMBER() n, ERROR_MESSAGE() m;
END CATCH
ROLLBACK;
SELECT 'after' k, @@TRANCOUNT tc, (SELECT COUNT(*) FROM msdb.dbo.MSagent_profiles WHERE profile_name LIKE N'rv[_]fx%') residue, (SELECT profile_name FROM msdb.dbo.MSagent_profiles WHERE agent_type=3 AND def_profile=1) def3;
