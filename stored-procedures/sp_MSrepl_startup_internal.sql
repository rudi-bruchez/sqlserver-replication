SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSrepl_startup_internal]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSrepl_startup_internal] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSrepl_startup_internal]
WITH EXECUTE AS CALLER
AS
/*
	** Security Check: require sysadmin
	*/
	IF (ISNULL(IS_SRVROLEMEMBER('sysadmin'),0) = 0)
	AND NOT sys.fn_MSrepl_editionid() = 32 -- Defect 11687782: CL(MI) doesn't support sp_procoption/callbacks, so this procedure should be unconditionally unblocked for missing data structures initialization
	BEGIN
		RAISERROR(21089,16,-1) 
		RETURN (1)
	END

	-- Drop and create publisher side cache table
	/*
	if exists (select * from tempdb.sys.objects where name = 'MSpublisher_access' and
	type = 'U')
		drop table tempdb.dbo.MSpublisher_access

	create table tempdb.dbo.MSpublisher_access
	(
	spid int NOT NULL,
	db_id int not null,
	publication sysname not null,
	login_time datetime not null,
	pubid uniqueidentifier null -- Used for merge only.
	)

	CREATE CLUSTERED INDEX ucMSpublisher_access ON tempdb.dbo.MSpublisher_access
		(spid, publication, db_id)
	exec tempdb.dbo.sp_MS_marksystemobject 'dbo.MSpublisher_access'
*/

	-- Drop and create distributor side cache table
	-- We need to avoid publisher and distributor using the same table to prevent
	-- contention in local distributor case.
	if exists (select * from master.dbo.sysservers
				  WHERE  srvstatus & 8 <> 0 and UPPER(datasource collate database_default) = UPPER(@@servername) collate database_default)
	begin
		if exists (select * from tempdb.sys.objects where name = 'MSdistributor_access' and
		type = 'U')
			drop table tempdb.dbo.MSdistributor_access

		create table tempdb.dbo.MSdistributor_access
		(
		spid int NOT NULL,
		db_id int not null,
		agent_id int not null,
		agent_type int not null,
		publication_id int not null,
		login_time datetime not null
		)

		create clustered index ucMSdistributor_access on tempdb.dbo.MSdistributor_access
			(spid, login_time)
		
		exec tempdb.dbo.sp_MS_marksystemobject 'dbo.MSdistributor_access'

		-- init perfmon counters
		exec sys.sp_MSinit_replication_perfmon
   end
GO
GRANT EXECUTE ON [sys].[sp_MSrepl_startup_internal] TO [public] AS [dbo]
GO
