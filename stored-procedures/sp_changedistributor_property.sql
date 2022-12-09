SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_changedistributor_property]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_changedistributor_property] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_changedistributor_property]
	@property [sysname],
	@value [nvarchar](255)
WITH EXECUTE AS CALLER
AS
declare @retcode int
	declare @new_heartbeat_interval int 

	/*
	** Security Check: require sysadmin
	*/
	IF (ISNULL(IS_SRVROLEMEMBER('sysadmin'),0) = 0)
	BEGIN
		RAISERROR(21089,16,-1) 
		RETURN (1)
	END

	-- Check to make sure the local server is a distributor
	if not exists (SELECT * FROM master.dbo.sysservers
			  WHERE  srvstatus & 8 <> 0 and
			  UPPER(datasource  collate database_default) = UPPER(@@servername) collate database_default)
	begin
		RAISERROR (14114, 16, -1, @@SERVERNAME)
		return(1)
	end

	-- Return list of properties if @property is NULL
	if @property is NULL
	begin
		create table #tab1 (properties sysname collate database_default not null)
		insert into #tab1 values ('heartbeat_interval')
		select * from #tab1
		
		return (0)
	end

	-- Check for valid property
	IF LOWER(@property collate SQL_Latin1_General_CP1_CS_AS) NOT IN ('heartbeat_interval')
	BEGIN
		RAISERROR (14154, 16, -1)
		RETURN (1)
	END

	if LOWER(@property collate SQL_Latin1_General_CP1_CS_AS) = 'heartbeat_interval'
	begin
		if isnumeric(@value) = 0 or convert(int, isnull(@value, 0)) < 1
		begin
			raiserror (21115, 16, -1, @value, 'heartbeat_interval')
			return 1
		end
		
		if exists (select name from msdb.sys.objects where name = 'MSdistributor')  
		begin
			update msdb..MSdistributor set value = @value where property = @property
			if @@error <> 0
				return 1
			select @new_heartbeat_interval = CONVERT(int, @value)
			exec @retcode = sys.sp_MScreate_replication_checkup_agent @heartbeat_interval = 
				@new_heartbeat_interval
			if @@error <> 0 or @retcode <> 0
				return 1
		end
		else 
			return 1
	end
	
	return (0)
GO
GRANT EXECUTE ON [sys].[sp_changedistributor_property] TO [public] AS [dbo]
GO
