SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_dropdistributiondb]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_dropdistributiondb] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_dropdistributiondb]
	@database [sysname],
	@former_ag_secondary [int]
WITH EXECUTE AS CALLER
AS
BEGIN
	SET NOCOUNT ON

	DECLARE @retcode		int
	DECLARE @agentname		nvarchar(100)
	DECLARE @security_mode	int
	DECLARE @distbit		int
	DECLARE @distpublisher	sysname
	DECLARE @distdb			sysname
	DECLARE @file_name		sysname
	DECLARE @command		nvarchar(4000)
	DECLARE @force			bit

	-- Security Check: require sysadmin
	IF (ISNULL(IS_SRVROLEMEMBER('sysadmin'),0) = 0)
	BEGIN
		RAISERROR(21089,16,-1) 
		RETURN (1)
	END

	SELECT	@distbit = 16,
			@force   = 0

	-- Check to make sure this is a distributor
	IF NOT EXISTS
	(
		SELECT	*
		FROM	master.dbo.sysservers
		WHERE	UPPER(datasource collate database_default) = UPPER(@@SERVERNAME) collate database_default
		  AND	srvstatus & 8 <> 0
	)
	BEGIN
		RAISERROR (14114, 16, -1, @@SERVERNAME)
		RETURN(1)
	END

	-- Check if database is configured as a distributor database
	IF NOT EXISTS
	(
		SELECT	*
		FROM	msdb..MSdistributiondbs
		WHERE	name = @database collate database_default
	)
	BEGIN
		RAISERROR (14117, 16, -1, @database)
		RETURN(1)
	END

	-- Check if any DistPublishers are using this database
	IF EXISTS
	(
		SELECT	*
		FROM	msdb..MSdistpublishers
		WHERE	distribution_db = @database collate database_default
	)
	BEGIN
		RAISERROR (14120, 16, -1, @database)
		RETURN (1)
	END

	-- Verify db file is accessible.  If it isn't,
	-- use force drop logic to skip any steps that
	-- interface directly with the db
	IF (ISNULL(HAS_DBACCESS(@database),0) = 0)
	BEGIN
		SET @force = 1
		RAISERROR (21773, 10, -1, @database)
	END

	IF @force = 0
	BEGIN
		-- In yukon security model drop the 
		-- qreader_agent if it still exists. 
		SELECT @command = QUOTENAME(@database) + '.sys.sp_MSdrop_qreader_agent ' 

		EXEC @command
		IF @@ERROR != 0
			RETURN 1

		SELECT @command = NULL
		
		-- we wait for 3 seconds after the drop to 
		-- ensure all connections have been dropped
		WAITFOR DELAY '00:00:03'
	END

	-- Check if the DB is being currently used
	IF EXISTS
	(
		SELECT	*
		FROM	sys.sysprocesses
		WHERE	dbid = DB_ID(@database)
		  AND	spid > 50
	)
	BEGIN
		RAISERROR (21122, 16, 1, @database)
		RETURN (1)
	END

	-- Drop the history cleanup agent.
	SELECT	@agentname = name
	FROM	msdb.dbo.sysjobs j,
			msdb.dbo.sysjobsteps s
	WHERE	j.job_id = s.job_id
	  AND	j.category_id = 12
	  AND	s.database_name = @database collate database_default

	IF @agentname IS NOT NULL
	BEGIN
		EXEC @retcode = sys.sp_MSdrop_repl_job @job_name = @agentname

		IF @@ERROR <> 0 or @retcode <> 0
		BEGIN
			RETURN(1)
		END
	END

	-- Drop the distribution cleanup agent.
	SELECT	@agentname = name
	FROM	msdb.dbo.sysjobs j,
			msdb.dbo.sysjobsteps s
	WHERE	j.job_id = s.job_id
	  AND	j.category_id = 11
	  AND	s.database_name = @database collate database_default

	IF @agentname IS NOT NULL
	BEGIN
		EXEC @retcode = sys.sp_MSdrop_repl_job @job_name = @agentname

		IF @@ERROR <> 0 or @retcode <> 0
		BEGIN
			RETURN(1)
		END
	END

	-- Drop the job for replication monitoring refresh
	select @agentname = formatmessage (20811, @database)
	if exists (select j.name
				from msdb.dbo.sysjobs j join msdb.dbo.sysjobsteps s
				on j.job_id = s.job_id
				and j.name = @agentname
				and j.category_id = 18
				and s.database_name = @database collate database_default)
	begin
		exec @retcode = sys.sp_MSdrop_repl_job @job_name = @agentname
		if @@error <> 0 or @retcode <> 0
		begin
			return (1)
		end
	end

	-- Drop orphaned jobs that are left over on this former AG secondary
	if (@former_ag_secondary = 1)
	BEGIN
		SELECT @command = QUOTENAME(@database) + '.sys.sp_MSrepl_droporphanedjobs'
		EXEC @retcode = @command
		IF (@@ERROR <> 0 or @retcode <> 0)
			BEGIN
				RETURN (1)
			END
	END

    -- Consider: Lock database using EXEC %%CurrentDatabase().Lock()??

	-- Drop the distributor db if it exists
	IF EXISTS
	(
		SELECT	*
		FROM	master.dbo.sysdatabases
		WHERE	name = @database collate database_default
	)
	BEGIN
		-- Update sysdatabase category bit before dropping the database
		-- Otherwise, the database can not be dropped.
		EXEC %%DatabaseEx(Name = @database).SetDistributor(Value = 0)

		CREATE TABLE #db_existed (db_existed bit NOT NULL)

		IF @force = 0
		BEGIN
			/* Get version stamp */
			SELECT	@command =	'INSERT INTO #db_existed SELECT db_existed FROM ' +
								QUOTENAME(@database) + '..MSrepl_version'

			EXEC(@command)

			IF @@ERROR <> 0
			BEGIN
				RETURN(1)       
			END
		END

        -- Drop the distribution db only if it is created in sp_adddistributiondb.
        IF (@force = 1) OR NOT EXISTS
        (
            SELECT	*
            FROM	#db_existed
            WHERE	db_existed = 0x1
        )
        BEGIN
			IF @force = 0 and @former_ag_secondary = 0  -- Dont drop the snapshot directory if the SP is executed on former secondary
			BEGIN
				-- we're dropping the database, so don't bother to clean up
				-- individual records.  Just make sure we blow away the synchronization
				-- files & directories hosted by the file system.

				SELECT @command = QUOTENAME(@database) + '.dbo.sp_MSdrop_snapshot_dirs'
				SELECT @command = 'EXEC ' + @command
				EXEC (@command)
				IF (@@ERROR <> 0)
				BEGIN
					RETURN (1)
				END

				-- Save the device info before dropping the database
				CREATE TABLE #distdbdevices
				(
					name sysname collate database_default not null,
					filename nvarchar(4000) collate database_default not null
				)

				-- Drop distributor devices
				-- Query is copied from sp_helpdb
				SELECT	@command = 'INSERT INTO #distdbdevices select DISTINCT name, filename from ' + 
									QUOTENAME(@database) + '.dbo.sysfiles'

				EXEC (@command)
				IF @@ERROR <>0
				BEGIN
					RETURN(1)      
				END
			END

			-- Drop the distribution database
			SELECT @command = 'drop database ' + QUOTENAME(@database)
			EXEC (@command)

			IF @@ERROR <> 0
			BEGIN
				-- Mark the database as distribution database again 
				-- Otherwise, this sp will fail when it is reentered.
				-- It is often the case that if there's an open session
				-- on the database, it can not be dropped.
				EXEC %%DatabaseEx(Name = @database).SetDistributor(Value = 1)
				RETURN(1)
			END

			IF @force = 0 and @former_ag_secondary = 0 -- Dont drop the backup device if the SP is executed on former secondary
			BEGIN
				-- Drop distributor devices
				-- Query is copied from sp_helpdb
				-- SQL SERVER 7.0 may drop some auto generated device files, drop them here again
				DECLARE hCdropdistributiondb CURSOR LOCAL FAST_FORWARD FOR
				SELECT	DISTINCT dd.name
				FROM	#distdbdevices dd,
						master.dbo.sysaltfiles sf
				WHERE	sf.name = dd.name collate database_default
				  AND	sf.filename = dd.filename collate database_default
				FOR READ ONLY

				OPEN	hCdropdistributiondb
				FETCH	hCdropdistributiondb INTO @file_name

				WHILE (@@fetch_status <> -1)
				BEGIN
					-- Device may be used by other databases.  Ignore all errors.
					-- Note here that we are assuming sp_dropdevice can 
					-- handle logical file names. 
					EXEC sys.sp_dropdevice @file_name, DELFILE
					FETCH hCdropdistributiondb INTO @file_name
				END

				CLOSE hCdropdistributiondb
				DEALLOCATE hCdropdistributiondb
			END
		END
		-- else, database did exist before it was made the distributor, 
		-- do full cleanup
		ELSE
		BEGIN
			-- run 'fast clean' routine first. this removes repldata files
			-- and truncates MSrepl_transactions/commands

			SELECT @command = QUOTENAME(@database) + '.dbo.sp_MSfast_delete_trans'
			SELECT @command = 'EXEC ' + @command
			EXEC (@command)
			IF (@@ERROR <> 0)
			BEGIN
				RETURN (1)
			END

			-- Do distribution cleanup the final time
			-- this handles those fiddly agent tables & such
			-- ( and would delete commands/xacts if we hadn't already purged 'em )

			SELECT	@command =	'EXEC ' +
								QUOTENAME(@database) + 
								'.dbo.sp_MSdistribution_cleanup @min_distretention = 0, @max_distretention = 0, @no_applock = 1'

			EXEC (@command)

			IF (@@ERROR <> 0)
			BEGIN
				RETURN (1)
			END
		END
	END

	-- Delete the DistributionDB entry
	DELETE	msdb.dbo.MSdistributiondbs
	WHERE	name = @database collate database_default

	IF @@error <> 0
	BEGIN
		RETURN(1)
	END

	RETURN (0)
END                
GO
GRANT EXECUTE ON [sys].[sp_dropdistributiondb] TO [public] AS [dbo]
GO
