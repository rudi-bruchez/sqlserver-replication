SET NOCOUNT ON;
USE rv_fxk3q1_p;
EXEC sp_addpublication_snapshot @publication = N'rv_fxk3q1_pi', @frequency_type = 1, @active_start_date = 99991231;
DECLARE @j binary(16);
SELECT @j = job_id FROM distribution.dbo.MSsnapshot_agents WHERE publisher_db = N'rv_fxk3q1_p' AND publication = N'rv_fxk3q1_pi';
SELECT 'snapagent_after' k, a.local_job, CONVERT(nvarchar(36), CONVERT(uniqueidentifier, a.job_id)) job, (SELECT COUNT(*) FROM msdb.dbo.sysjobs j WHERE j.job_id = CONVERT(uniqueidentifier, a.job_id)) job_exists, (SELECT COUNT(*) FROM distribution.dbo.MSsnapshot_agents b WHERE b.publisher_db = N'rv_fxk3q1_p') rows_for_db FROM distribution.dbo.MSsnapshot_agents a WHERE publisher_db = N'rv_fxk3q1_p';
SELECT 'sched_created' k, s.enabled, s.freq_type, s.freq_interval, s.active_start_date, s.active_start_time, s.active_end_date, s.active_end_time FROM msdb.dbo.sysjobschedules js JOIN msdb.dbo.sysschedules s ON s.schedule_id = js.schedule_id WHERE js.job_id = CONVERT(uniqueidentifier, @j);
EXEC sp_changepublication_snapshot @publication = N'rv_fxk3q1_pi', @frequency_type = 4, @frequency_interval = 1, @frequency_subday = 4, @frequency_subday_interval = 10, @active_end_date = 99991231, @active_end_time_of_day = 235959;
SELECT 'sched_changed_nostart' k, s.enabled, s.freq_type, s.freq_interval, s.freq_subday_type, s.freq_subday_interval, s.active_start_date, s.active_start_time, s.active_end_date, s.active_end_time FROM msdb.dbo.sysjobschedules js JOIN msdb.dbo.sysschedules s ON s.schedule_id = js.schedule_id WHERE js.job_id = CONVERT(uniqueidentifier, @j);
-- job_disable as R24 writes it, with the binary(16) job_id passed directly
DECLARE @rc int;
BEGIN TRY
EXEC @rc = msdb.dbo.sp_update_job @job_id = @j, @enabled = 0;
SELECT 'update_job_binary' k, @rc rc, (SELECT enabled FROM msdb.dbo.sysjobs WHERE job_id = CONVERT(uniqueidentifier, @j)) enabled_now;
EXEC @rc = msdb.dbo.sp_update_job @job_id = @j, @enabled = 1;
SELECT 'update_job_restore' k, @rc rc, (SELECT enabled FROM msdb.dbo.sysjobs WHERE job_id = CONVERT(uniqueidentifier, @j)) enabled_now;
END TRY BEGIN CATCH SELECT 'update_job_err' k, ERROR_NUMBER() n, ERROR_MESSAGE() m; END CATCH
-- a job_id that names no job (a deleted job): sp_update_job
DECLARE @dead binary(16) = CONVERT(binary(16), NEWID());
BEGIN TRY
EXEC @rc = msdb.dbo.sp_update_job @job_id = @dead, @enabled = 0;
SELECT 'update_dead_rc' k, @rc rc;
END TRY BEGIN CATCH SELECT 'update_dead_err' k, ERROR_NUMBER() n, ERROR_MESSAGE() m; END CATCH
SELECT 'trancount' k, @@TRANCOUNT tc;
