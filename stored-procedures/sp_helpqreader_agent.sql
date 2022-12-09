SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_helpqreader_agent]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_helpqreader_agent] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_helpqreader_agent]
	@frompublisher [bit]
WITH EXECUTE AS CALLER
AS
BEGIN
	DECLARE @retcode int
	
	IF @frompublisher = 0
	BEGIN
		-- Security Check: require sysadmin/dbo of dist 
		IF IS_SRVROLEMEMBER('sysadmin') != 1
		BEGIN
			RAISERROR(21089,16,-1) 
			RETURN 1
		END

		-- database must be distribution db or we exit with no resultset
		IF sys.fn_MSrepl_isdistdb(DB_NAME()) <> 1
		BEGIN
			RETURN 0
		END
	END
	ELSE
	BEGIN
		-- Security Check: require sysadmin/dbo of publisher 
		IF IS_SRVROLEMEMBER('sysadmin') != 1
			AND IS_MEMBER ('db_owner') != 1
		BEGIN
			RAISERROR(21089,16,-1) 
			RETURN 1
		END

		-- only verify this for the DBO case, sysadmin gets a pass
		IF IS_SRVROLEMEMBER('sysadmin') != 1
		BEGIN
			-- must be tran published or we exit with no resultset
			IF sys.fn_MSrepl_istranpublished(DB_NAME(),0) <> 1
			BEGIN
				RETURN 0
			END
		END
	END

	--
	-- if executed from publisher
	--
	IF @frompublisher = 1
	BEGIN
		DECLARE @loc_publisher sysname
				,@loc_distribdb sysname
				,@rpcsrvname sysname
				,@rpc nvarchar(1000)
		--
		-- get the distributor rpc info
		--
		SELECT @loc_publisher = CONVERT(sysname, SERVERPROPERTY('ServerName'))
		EXEC @retcode = sys.sp_MSrepl_getdistributorinfo @publisher = @loc_publisher,
															@rpcsrvname = @rpcsrvname OUTPUT,
															@distribdb = @loc_distribdb OUTPUT

		IF @@error <> 0 OR @retcode <> 0 or (@rpcsrvname IS NULL) or (@loc_distribdb IS NULL)
		BEGIN
			RAISERROR(20036, 16, -1)
			RETURN 1
		END
		--
		-- execute the RPC
		--
		select @rpc = quotename(@rpcsrvname) + N'.' + quotename(@loc_distribdb) + N'.dbo.sp_helpqreader_agent'
		exec @retcode = @rpc @frompublisher = 0
		IF @@error != 0
			select @retcode = 1

		RETURN @retcode
	END	
	
	SELECT msqa.id, 
			msqa.name,
			sjb.job_id,
			sc.credential_identity as [job_login],
			N'**********' as [job_password]
		FROM MSqreader_agents msqa
			JOIN msdb..sysjobs sjb
				ON convert(uniqueidentifier, msqa.job_id) = sjb.job_id
			LEFT JOIN msdb..sysjobsteps sj
				ON msqa.job_step_uid = sj.step_uid
			LEFT JOIN msdb..sysproxies sp
				ON sj.proxy_id = sp.proxy_id
			LEFT JOIN sys.credentials sc
				ON sp.credential_id = sc.credential_id

	RETURN 0
END
GO
GRANT EXECUTE ON [sys].[sp_helpqreader_agent] TO [public] AS [dbo]
GO
