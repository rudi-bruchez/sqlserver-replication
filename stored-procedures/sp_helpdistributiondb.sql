SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_helpdistributiondb]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_helpdistributiondb] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_helpdistributiondb]
	@database [sysname]
WITH EXECUTE AS CALLER
AS
begin
	set nocount on

	declare @retcode	int,
			@cmd		nvarchar(500),
			@dbname		sysname

	-- check to see if we are configured as a distributor
	if not exists (select * 
					from master.dbo.sysservers
					  where upper(datasource collate database_default) = upper(@@servername) collate database_default
						 and srvstatus & 8 <> 0)
	begin
		-- if searching for any db then return success with no result... else we 
		   -- are searching for a specific db, which implies we think we are a dist (raiserror)
		if @database = '%' 
		begin
			 return(0)
		end

		-- '@@servername' is not configured as a Distributor.
		raiserror (14114, 16, -1, @@servername)
		return(1)      
	end

	if object_id('msdb.dbo.MSdistributiondbs', 'U') is null
	begin
		-- "Could not find the Distributor or the distribution database for the local server. The Distributor 
		--  may not be installed, or the local server may not be configured as a Publisher at the Distributor."
		raiserror (14071, 16, -1)
		return(1)
	end    

	-- Check if database is configured as a distributor database (only do this for a given db NOT all)
	if @database <> '%' 
		and sys.fn_MSrepl_isdistdb (@database) != 1
	begin
		-- '@database' is not configured as a distribution database.
		raiserror (14117, 16, -1, @database)
		return(1)
	end    

	-- table that holds a list of distribution dbs
	declare @distdb table 
			(
				dbname sysname
			)
	
	-- table that holds information on the database files    
	-- can't use @table because we need to do insert exec
	create table #dbfiledesc
			(
				dbname		sysname collate database_default,
				size		int not null,
				file_path	nvarchar(4000) collate database_default not null,
				type		smallint not null,
				separator	nvarchar(2) not null
			)   
	

	-- retrieve all distribution databases
	insert into @distdb (dbname)
		select sysdb.name 
			from master.dbo.sysdatabases sysdb 
				inner join msdb.dbo.MSdistributiondbs msddb
					on sysdb.name = msddb.name collate database_default
			where msddb.name like @database collate database_default
				and has_dbaccess(msddb.name) = 1 
		  
	-- now, for each distribution database that the user has PAL 
	-- access to, we will retrieve the data and log file information. 
	declare hCdatabase CURSOR LOCAL FAST_FORWARD FOR
		select dbname 
			from @distdb
			
	open hCdatabase

	fetch next from hCdatabase into @dbname
	while (@@fetch_status <> -1)
	begin
		-- Check to see if the user is a member of 'db_owner' or 'replmonitor' role
		-- or in the PAL of any publication whose publisher is associated with
		-- this distribution database
		select @cmd = quotename(@dbname) + N'.sys.sp_MSrepl_DistDBPALAccess'
		
		exec @retcode = @cmd
		if @retcode = 0 and @@error = 0
		begin
			-- if we have pal access then insert data and log file info
			--
			-- NOTE : type map as follows:
			--		0 - Data File
			--		1 - Log File
			--		2 - FileStream Data File
			--		3 - FileStream Log File
			--		4 - Fulltext
			select @cmd = 'select N' + quotename(@dbname, N'''') + ',
								sysdf.size, 
								sysdf.physical_name,
								type,
								CASE WHEN sysdf.physical_name like ''http%'' COLLATE SQL_Latin1_General_CP1_CI_AS THEN N''/'' ELSE ISNULL(CAST(SERVERPROPERTY(''pathseparator'') as nvarchar(2)), N''\'') END
							from ' + quotename(@dbname) + '.[sys].[database_files] sysdf
							where sysdf.type not in (2, 3, 4)'

			insert into #dbfiledesc (dbname, size, file_path, type, separator)
				exec(@cmd)
		end
		
		fetch next from hCdatabase into @dbname
	end
	close hCdatabase
	deallocate hCdatabase
	
	select msddb.name,	
			min_distretention, 
			max_distretention, 
			history_retention,
			'history_cleanup_agent' =  formatmessage (20567, msddb.name),
			'distributor_cleanup_agent' = formatmessage(20568, msddb.name),
			'status' = 0, 
			'data_folder' = case when charindex(dbfd_data.separator, dbfd_data.file_path) > 0 then substring(dbfd_data.file_path, 1, len(dbfd_data.file_path) - charindex(dbfd_data.separator, reverse(dbfd_data.file_path))) else null end,
			'data_file'	= case when charindex(dbfd_data.separator, dbfd_data.file_path) > 0 then right(dbfd_data.file_path, charindex(dbfd_data.separator, reverse(dbfd_data.file_path))-1) else dbfd_data.file_path end,
			'data_file_size'= convert(int, (select low from master.dbo.spt_values where type = 'E' and number = 1) * convert(dec(15), dbfd_data.size)/ 1048576), 
			'log_folder' = case when charindex(dbfd_log.separator, dbfd_log.file_path) > 0 then substring(dbfd_log.file_path, 1, len(dbfd_log.file_path) - charindex(dbfd_log.separator, reverse(dbfd_log.file_path))) else null end,
			'log_file' = case when charindex(dbfd_log.separator, dbfd_log.file_path) > 0 then right(dbfd_log.file_path, charindex(dbfd_log.separator, reverse(dbfd_log.file_path))-1) else dbfd_log.file_path end,
			'log_file_size' = convert(int, (select low from master.dbo.spt_values where type = 'E' and number = 1) * convert(dec(15), dbfd_log.size)/ 1048576),
			 deletebatchsize_xact,
			 deletebatchsize_cmd
		from msdb.dbo.MSdistributiondbs msddb
			join #dbfiledesc dbfd_data
				on msddb.name = dbfd_data.dbname collate database_default
			join #dbfiledesc dbfd_log
				on dbfd_data.dbname = dbfd_log.dbname collate database_default
		where msddb.name LIKE @database collate database_default
			and dbfd_data.type = 0
			and dbfd_log.type = 1

	return 0
end
GO
GRANT EXECUTE ON [sys].[sp_helpdistributiondb] TO [public] AS [dbo]
GO
