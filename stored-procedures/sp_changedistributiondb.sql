SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_changedistributiondb]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_changedistributiondb] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_changedistributiondb]
	@database [sysname],
	@property [sysname],
	@value [nvarchar](255)
WITH EXECUTE AS CALLER
AS
SET NOCOUNT ON

	/*
	** Declarations.
	*/
	DECLARE @distributor sysname
	DECLARE @min_distretention     int
	DECLARE @max_distretention     int
	DECLARE @retcode             int
	DECLARE @new_min_distretention     int
	DECLARE @new_max_distretention     int
	DECLARE @new_history_retention     int
	DECLARE @agentname nvarchar(100)
	DECLARE @command nvarchar(255)
	DECLARE @security_mode int
	DECLARE @distbit int
	DECLARE @new_deletebatchsize_xact	int
	DECLARE @new_deletebatchsize_cmd	int


	/*
	** Security Check: require sysadmin
	*/
	IF (ISNULL(IS_SRVROLEMEMBER('sysadmin'),0) = 0)
	BEGIN
		RAISERROR(21089,16,-1) 
		RETURN (1)
	END

	SELECT @distbit = 16

	/*
	** Parameter Check:  @property.
	** If the @property parameter is NULL, print the options.
	*/

	IF @property IS NULL
		BEGIN
			CREATE TABLE #tab1 (properties sysname collate database_default not null)
			INSERT INTO #tab1 VALUES ('min_distretention')
			INSERT INTO #tab1 VALUES ('max_distretention')
			INSERT INTO #tab1 VALUES ('history_retention')
			INSERT INTO #tab1 VALUES ('deletebatchsize_xact')
			INSERT INTO #tab1 VALUES ('deletebatchsize_cmd')
			SELECT * FROM #tab1
			RETURN (0)
		END

	/*
	** Parameter Check:  @property.
	** Check to make sure that @property is a valid property in
	** sysarticles.
	*/
	IF @property IS NULL OR LOWER(@property collate SQL_Latin1_General_CP1_CS_AS) NOT IN 
													('min_distretention',
													 'max_distretention',
													 'history_retention',
													 'deletebatchsize_xact',
													 'deletebatchsize_cmd')
			 
		BEGIN

			RAISERROR (14115, 16, -1, 
			'''min_distretention'', ''max_distretention'', ''history_retention'', ''deletebatchsize_xact'' or ''deletebatchsize_cmd''')
			RETURN (1)
		END

	/*
	** Check to make sure this is a distributor
	*/
	IF NOT EXISTS (SELECT * FROM master.dbo.sysservers
			  WHERE UPPER(datasource collate database_default) = UPPER(@@SERVERNAME) collate database_default
				 AND srvstatus & 8 <> 0)
	BEGIN
		RAISERROR (14114, 16, -1, @@SERVERNAME)
		RETURN(1)
	END

	/*
	** Check if database is configured as a distributor database
	*/
	IF NOT EXISTS (SELECT * FROM master.dbo.sysdatabases
			  WHERE name = @database collate database_default
				 AND category & @distbit <> 0)
	BEGIN
		RAISERROR (14117, 16, -1, @database)
		RETURN(1)
	END
	
	/*
	** Change the property.
	*/
	IF LOWER(@property collate SQL_Latin1_General_CP1_CS_AS) = 'min_distretention'
		BEGIN
			IF @value IS NULL
				BEGIN
					RAISERROR (14043, 16, -1, '@value', 'sp_changedistributiondb')
					RETURN (1)
				END

			/*
			** Set the MinDistRetention registry key value
			*/
			SELECT @new_min_distretention = CONVERT(int, @value)

			/*
			** Get MaxDistRetention value
			*/
			SELECT @max_distretention = max_distretention FROM msdb..MSdistributiondbs
				WHERE name = @database collate database_default
				
			/* 
			** Check for invalid retention values 
			*/
			IF @new_min_distretention < 0
				BEGIN
					   RAISERROR(14106, 16, -1)
					RETURN (1)
				END
			IF @new_min_distretention > @max_distretention
				BEGIN
					RAISERROR(14107, 16, -1) 
					RETURN (1)
				END

			UPDATE msdb..MSdistributiondbs SET min_distretention = @new_min_distretention
				WHERE name = @database collate database_default
			IF @@error <> 0 
				BEGIN
					RETURN (1)
				END

			/*
			** Update Distribution Cleanup agent 
			*/
			select @agentname = name from msdb.dbo.sysjobs j, msdb.dbo.sysjobsteps s where 
			j.job_id = s.job_id and
			j.category_id = 11 and
			s.database_name = @database collate database_default
		
			SELECT @command =  'EXEC dbo.sp_MSdistribution_cleanup @min_distretention = ' + 
				CONVERT(nvarchar(12), @new_min_distretention) + ', @max_distretention = ' +
				CONVERT(nvarchar(12), @max_distretention)
			EXEC @retcode = msdb.dbo.sp_update_jobstep @job_name = @agentname, @step_id = 1, 
				@command = @command
			IF @@error <> 0 OR @retcode <> 0
			   RETURN(1)

		END

	IF LOWER(@property collate SQL_Latin1_General_CP1_CS_AS) = 'max_distretention'
		BEGIN
			IF @value IS NULL
				BEGIN
					RAISERROR (14043, 16, -1, '@value', 'sp_changedistributiondb')
					RETURN (1)
				END

			/*
			** Set the MaxDistRetention registry key value
			*/
			SELECT @new_max_distretention = CONVERT(int, @value)

			/*
			** Get MinDistRetention value
			*/
			SELECT @min_distretention = min_distretention FROM msdb..MSdistributiondbs
				WHERE name = @database collate database_default

			/* 
			** Check for invalid retention values 
			*/
			IF @new_max_distretention < 0
				BEGIN
					   RAISERROR(14106, 16, -1)
					RETURN (1)
				END
			IF @new_max_distretention < @min_distretention
				BEGIN
					RAISERROR(14107, 16, -1) 
					RETURN (1)
				END

			UPDATE msdb..MSdistributiondbs SET max_distretention = @new_max_distretention
				WHERE name = @database collate database_default
			IF @@error <> 0 
				BEGIN
					RETURN (1)
				END
			/*
			** Update Distribution Cleanup agent 
			*/
			select @agentname = name from msdb.dbo.sysjobs j, msdb.dbo.sysjobsteps s where 
				j.job_id = s.job_id and
				j.category_id = 11 and
				s.database_name = @database collate database_default
			SELECT @command =  'EXEC dbo.sp_MSdistribution_cleanup @min_distretention = ' + 
				CONVERT(nvarchar(12), @min_distretention) + ', @max_distretention = ' +
				CONVERT(nvarchar(12), @new_max_distretention)
			EXEC @retcode = msdb.dbo.sp_update_jobstep @job_name = @agentname, @step_id = 1, 
				@command = @command
			IF @@error <> 0 OR @retcode <> 0
			   RETURN(1)
		END

	IF LOWER(@property collate SQL_Latin1_General_CP1_CS_AS) = 'history_retention'
		BEGIN
			IF @value IS NULL
				BEGIN
					RAISERROR (14043, 16, -1, '@value', 'sp_changedistributiondb')
					RETURN (1)
				END

			/*
			** Set the HistoryRetention registry key value
			*/
			SELECT @new_history_retention = CONVERT(int, @value)

			UPDATE msdb..MSdistributiondbs SET history_retention = @new_history_retention
				WHERE name = @database collate database_default
			IF @@error <> 0 
				BEGIN
					RETURN (1)
				END

			/*
			** Update History Cleanup agent 
			*/
			select @agentname = name from msdb.dbo.sysjobs j, msdb.dbo.sysjobsteps s where 
				j.job_id = s.job_id and
				j.category_id = 12 and
				s.database_name = @database collate database_default
			SELECT @command =  'EXEC dbo.sp_MShistory_cleanup @history_retention = ' + 
				CONVERT(nvarchar(12), @new_history_retention)
			EXEC @retcode = msdb.dbo.sp_update_jobstep @job_name = @agentname, @step_id = 1, 
				@command = @command
			IF @@error <> 0 OR @retcode <> 0
			   RETURN(1)

		END

		IF LOWER(@property collate SQL_Latin1_General_CP1_CS_AS) = 'deletebatchsize_xact'
		BEGIN
			IF @value IS NULL
			BEGIN
				RAISERROR (14043, 16, -1, '@value', 'sp_changedistributiondb')
				RETURN (1)
			END

			IF @value < 0
			BEGIN
				RAISERROR (22120, 16, -1)
				RETURN (1)
			END

			SELECT @new_deletebatchsize_xact = CONVERT(int, @value)

			UPDATE msdb..MSdistributiondbs SET deletebatchsize_xact = @new_deletebatchsize_xact WHERE name = @database collate database_default
			
			IF @@error <> 0 
				RETURN (1)
		END

		IF LOWER(@property collate SQL_Latin1_General_CP1_CS_AS) = 'deletebatchsize_cmd'
		BEGIN
			IF @value IS NULL
			BEGIN
				RAISERROR (14043, 16, -1, '@value', 'sp_changedistributiondb')
				RETURN (1)
			END

			IF @value < 0
			BEGIN
				RAISERROR (22120, 16, -1)
				RETURN (1)
			END

			SELECT @new_deletebatchsize_cmd = CONVERT(int, @value)

			UPDATE msdb..MSdistributiondbs SET deletebatchsize_cmd = @new_deletebatchsize_cmd WHERE name = @database collate database_default
			
			IF @@error <> 0 
				RETURN (1)
		END

	/*
	** Return succeed.
	*/
	RAISERROR (14105, 10, -1, @property)
	RETURN (0)
GO
GRANT EXECUTE ON [sys].[sp_changedistributiondb] TO [public] AS [dbo]
GO
