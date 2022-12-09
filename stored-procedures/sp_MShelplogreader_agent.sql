SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MShelplogreader_agent]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MShelplogreader_agent] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MShelplogreader_agent]
	@publisher [sysname],
	@publisher_db [sysname]
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
		RAISERROR (21482, 16, -1, 'sp_MShelplogreader_agent', 'distribution')
		RETURN (1)
	END

	SELECT @publisher_id = srvid
		FROM MSreplservers
		WHERE UPPER(srvname) = UPPER(@publisher)

	SELECT msla.id, 
			msla.name,
			msla.publisher_security_mode,
			msla.publisher_login,
			N'**********' as [publisher_password],
			sjb.job_id,
			sc.credential_identity as [job_login],
			N'**********' as [job_password]
		FROM MSlogreader_agents msla
				JOIN msdb..sysjobs sjb
					ON convert(uniqueidentifier, msla.job_id) = sjb.job_id
				LEFT JOIN msdb..sysjobsteps sj
					ON msla.job_step_uid = sj.step_uid
				LEFT JOIN msdb..sysproxies sp
					ON sj.proxy_id = sp.proxy_id
				LEFT JOIN sys.credentials sc
					ON sp.credential_id = sc.credential_id
		WHERE msla.publisher_id = @publisher_id
			AND msla.publisher_db = @publisher_db

	RETURN 0
END
GO
GRANT EXECUTE ON [sys].[sp_MShelplogreader_agent] TO [public] AS [dbo]
GO
