SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MShelpsnapshot_agent]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MShelpsnapshot_agent] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MShelpsnapshot_agent]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname]
WITH EXECUTE AS CALLER
AS
BEGIN
	DECLARE @publisher_id int

	-- Security Check: require sysadmin
	IF (ISNULL(IS_SRVROLEMEMBER('sysadmin'),0) = 0)
	BEGIN
		RAISERROR(21089,16,-1) 
		RETURN 1
	END

	-- database must be distribution db
	IF sys.fn_MSrepl_isdistdb(DB_NAME()) <> 1
	BEGIN
		RAISERROR (21482, 16, -1, 'sp_MShelpsnapshot_agent', 'distribution')
		RETURN (1)
	END

	SELECT @publisher_id = srvid
		FROM MSreplservers
		WHERE UPPER(srvname) = UPPER(@publisher)

	SELECT mssa.id, 
			mssa.name,
			mssa.publisher_security_mode,
			mssa.publisher_login,
			N'**********' as [publisher_password],
			sjb.job_id,
			sc.credential_identity as [job_login],
			N'**********' as [job_password],
			ss.name as [schedule_name],
			ss.freq_type as [frequency_type],
			ss.freq_interval as [frequency_interval],
			ss.freq_subday_type as [frequency_subday_type],
			ss.freq_subday_interval as [frequency_subday_interval],
			ss.freq_relative_interval as [frequency_relative_interval],
			ss.freq_recurrence_factor as [frequency_recurrence_factor],
			ss.active_start_date,
			ss.active_end_date,
			ss.active_start_time,
			ss.active_end_time
		FROM MSsnapshot_agents mssa
				JOIN msdb..sysjobs sjb
					ON convert(uniqueidentifier, mssa.job_id) = sjb.job_id
				LEFT JOIN msdb..sysjobsteps sj
					ON mssa.job_step_uid = sj.step_uid
				LEFT JOIN msdb..sysproxies sp
					ON sj.proxy_id = sp.proxy_id
				LEFT JOIN sys.credentials sc
					ON sp.credential_id = sc.credential_id
				LEFT JOIN msdb..sysjobschedules sjs
					ON sjs.job_id = sjb.job_id
				LEFT JOIN msdb..sysschedules ss
					ON ss.schedule_id = sjs.schedule_id
		WHERE mssa.publisher_id = @publisher_id
			AND mssa.publisher_db = @publisher_db
			AND mssa.publication = @publication

	RETURN 0
END
GO
GRANT EXECUTE ON [sys].[sp_MShelpsnapshot_agent] TO [public] AS [dbo]
GO
