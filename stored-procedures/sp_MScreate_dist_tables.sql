SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MScreate_dist_tables]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MScreate_dist_tables] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MScreate_dist_tables]
WITH EXECUTE AS CALLER
AS
begin
	DECLARE @Cmd varchar(4000)

   -- Only sysadmin and db_owner of a distribution database are allowed
   -- to create replication tables in the distribution database 
   if (is_srvrolemember('sysadmin') <> 1  and
	   is_member('db_owner') <> 1)
   begin
	  raiserror(21050, 14, -1)
	  return (1)
   end

	--
	-- create replmonitor role if it does not exist
	--
	if not exists (select * from sys.database_principals 
				where name = N'replmonitor' and type = 'R')
	begin
		EXEC  dbo.sp_addrole 'replmonitor'
	end

   /*
   ** Important:  
   ** We use varbinary(16) for xact_id and xact_seqno, we don't want ending nulls
   ** to be truncated by the server
   **
   ** Also, in MSrepl_commands, we don't want ending space to be truncated.  
   */
   SET ANSI_PADDING ON

    --
    -- create MSreplservers for a new distribution DB
    --
   
   IF NOT EXISTS (SELECT * from sys.objects WHERE name = 'MSreplservers' and type = 'U')
   BEGIN
      /****************************************************************************/
      raiserror('Creating table MSreplservers', 0,1)
      /****************************************************************************/
      CREATE TABLE dbo.MSreplservers
      (
      srvid		smallint,
      srvname	sysname
	  )
      CREATE UNIQUE CLUSTERED INDEX ucMSreplservers ON dbo.MSreplservers
                    (srvid)
                    
      exec dbo.sp_MS_marksystemobject 'MSreplservers'
      
    END   

    --
    -- create view MSsysservers_replservers for a new distribution DB
    --
   
   IF NOT EXISTS (SELECT * from sys.objects WHERE name = 'MSsysservers_replservers' and type = 'V')
   BEGIN
      /****************************************************************************/
      raiserror('Creating view MSsysservers_replservers', 0,1)
      /****************************************************************************/
      exec ('create view MSsysservers_replservers
      as
      select msrs.srvid msrs_srvid, msrs.srvname msrs_srvname,  ss.* from MSreplservers msrs,  master.dbo.sysservers ss where 
      upper(msrs.srvname collate database_default) = upper(ss.srvname collate database_default)')
                  
      exec dbo.sp_MS_marksystemobject 'MSsysservers_replservers'
      
    END   

   IF NOT EXISTS (SELECT * from sys.objects WHERE name = 'MSredirected_publishers' and type = 'U')
   BEGIN
	  /****************************************************************************/
	  raiserror('Creating table MSredirected_publishers', 0,1)
	  /****************************************************************************/
	  CREATE TABLE dbo.MSredirected_publishers
	  (
	  original_publisher   sysname NOT NULL,
	  publisher_db         sysname NOT NULL,     
	  redirected_publisher sysname NOT NULL
	  )
	  CREATE UNIQUE CLUSTERED INDEX ucMSredirected_publishers ON dbo.MSredirected_publishers
					(original_publisher, publisher_db)
					
	  exec dbo.sp_MS_marksystemobject 'MSredirected_publishers'
	  
	END   

   IF NOT EXISTS (SELECT * from sys.objects WHERE name = 'MSrepl_version' and type = 'U')
   BEGIN
	  /****************************************************************************/
	  raiserror('Creating table MSrepl_version', 0,1)
	  /****************************************************************************/
	  CREATE TABLE dbo.MSrepl_version
	  (
	  major_version int NOT NULL,
	  minor_version int NOT NULL,
	  revision int NOT NULL,
	  db_existed bit NULL
	  )
	  CREATE UNIQUE CLUSTERED INDEX ucMSrepl_version ON dbo.MSrepl_version
					(major_version, minor_version, revision)
	
	  exec dbo.sp_MS_marksystemobject 'MSrepl_version'
	  
	  INSERT INTO MSrepl_version VALUES (7,0,0,0)
   END

   IF NOT EXISTS (SELECT * from sys.objects WHERE name = 'MSpublisher_databases' and type = 'U')
   BEGIN
	  /****************************************************************************/
	  raiserror('Creating table MSpublisher_databases', 0,1)
	  /****************************************************************************/
	  CREATE TABLE dbo.MSpublisher_databases(
		publisher_id smallint NOT NULL,
		publisher_db sysname NULL,
		id int identity NOT NULL,
		publisher_engine_edition int null
	)
	  exec dbo.sp_MS_marksystemobject 'MSpublisher_databases'

	  raiserror('Creating clustered index ucMSpublisher_databases', 0,1)
	  CREATE UNIQUE CLUSTERED INDEX ucMSpublisher_databases ON dbo.MSpublisher_databases
	 (publisher_id, publisher_db, id)
   END
   ELSE
   BEGIN
		IF NOT EXISTS (select * from sys.columns
		where name = 'publisher_engine_edition'
		and object_id=object_id('MSpublisher_databases'))
	  BEGIN
		 ALTER TABLE MSpublisher_databases ADD publisher_engine_edition int null
	  END
   END

   IF NOT EXISTS (SELECT * from sys.objects WHERE name = 'MSpublications' and type = 'U')
   BEGIN
	  /****************************************************************************/
	  raiserror('Creating table MSpublications', 0,1)
	  /****************************************************************************/
	  CREATE TABLE dbo.MSpublications (
		publisher_id smallint NOT NULL,
		publisher_db sysname NULL,
		publication sysname NOT NULL,
		publication_id int identity NOT NULL,   -- This id IS NOT the same as the SQL Server publisher's
		publication_type int NOT NULL,          -- 0 = Snapshot 1 = Transactional
		thirdparty_flag bit NOT NULL,           -- 0 = SQL Server 1 = Third Party
		independent_agent bit NOT NULL,
		immediate_sync bit NOT NULL,
		allow_push bit NOT NULL,
		allow_pull bit NOT NULL,
		allow_anonymous bit NOT NULL,
		description nvarchar(255) NULL,
		vendor_name nvarchar(100) NULL,
		retention   int NULL,
		sync_method int default 0 NOT NULL,
		allow_subscription_copy bit default 0 not null,
		thirdparty_options int null,
		allow_queued_tran bit default 0 not null,
		options int default 0 not null,
		retention_period_unit	tinyint default 0 not null,
		allow_initialize_from_backup	bit				not null default 0,
		min_autonosync_lsn      varbinary(16) NULL
		)
	  exec dbo.sp_MS_marksystemobject 'MSpublications'

	 -- publication_id needs to be the first columns in the index. It
	 -- is used in sp_MSmaximum_cleanup_seqno.
	  raiserror('Creating clustered index ucMSpublications', 0,1)
	  CREATE UNIQUE CLUSTERED INDEX ucMSpublications ON dbo.MSpublications
	 (publication_id,  publication, publisher_db, publisher_id)
	  CREATE UNIQUE INDEX uc2MSpublications ON dbo.MSpublications
	 (publication, publisher_db, publisher_id)
   END
   ELSE
   BEGIN
	  IF NOT EXISTS (select * from sys.columns
		where name = 'sync_method'
		and object_id=object_id('MSpublications'))
	  BEGIN
		 ALTER TABLE MSpublications ADD sync_method int default 0 not null
	  END

	  IF NOT EXISTS (select * from sys.columns
		where name = 'allow_subscription_copy'
		and object_id=object_id('MSpublications'))
	  BEGIN
		 ALTER TABLE MSpublications ADD allow_subscription_copy bit default 0 not null
	  END
	  IF NOT EXISTS (select * from sys.columns
		where name = 'thirdparty_options'
		and object_id=object_id('MSpublications'))
	  BEGIN
		 ALTER TABLE MSpublications ADD thirdparty_options int null
	  END

	  IF NOT EXISTS (select * from sys.columns
		where name = 'allow_queued_tran'
		and object_id=object_id('MSpublications'))
	  BEGIN
		 ALTER TABLE MSpublications ADD allow_queued_tran bit default 0 not null
	  END

	  IF NOT EXISTS (select * from sys.columns
		where name = 'options'
		and object_id=object_id('MSpublications'))
	  BEGIN
		 exec ('ALTER TABLE MSpublications ADD options int default 0 not null')
		 -- Set enabled for het sub bit in options column if sync_method = 1
		 exec ('update MSpublications set options = 0x4 where sync_method = 1')
	  END

	  IF NOT EXISTS (select * from sys.columns
		where name = 'allow_initialize_from_backup'
		and object_id=object_id('MSpublications'))
	  BEGIN
		 ALTER TABLE MSpublications ADD allow_initialize_from_backup bit default 0 not null
	  END

	  IF NOT EXISTS (select * from sys.columns
		where name = 'min_autonosync_lsn'
		and object_id=object_id('MSpublications'))
	  BEGIN
		 ALTER TABLE MSpublications ADD min_autonosync_lsn varbinary(16) NULL
	  END

	END


	IF NOT EXISTS (SELECT * from sys.objects WHERE name = 'MSarticles' and type = 'U')
	BEGIN
		/****************************************************************************/
		raiserror('Creating table MSarticles', 0,1)
		/****************************************************************************/
		CREATE TABLE dbo.MSarticles (
			publisher_id smallint NOT NULL,
			publisher_db sysname NULL,
			publication_id int NOT NULL,
			article sysname NOT NULL,
			article_id int NOT NULL,                            -- This id is the same as a SQL Server Publisher's
			destination_object sysname NULL,
			source_owner    sysname NULL,
			source_object sysname NULL,
			description nvarchar(255) NULL,
			destination_owner sysname NULL
		)   

		exec dbo.sp_MS_marksystemobject 'MSarticles'

		  raiserror('Creating clustered index ucMSarticles', 0,1)
		  CREATE UNIQUE CLUSTERED INDEX ucMSarticles ON dbo.MSarticles (publisher_db, publisher_id, article_id, article, publication_id)
	END
	ELSE
	BEGIN
		IF NOT EXISTS(select * from sys.columns 
						where object_id = object_id(N'MSarticles') 
							and name = N'destination_owner')
		BEGIN
			ALTER TABLE MSarticles ADD destination_owner sysname NULL
		END
	END

	IF NOT EXISTS( SELECT * from sys.objects WHERE name = 'MSsync_states' )
	BEGIN
		CREATE TABLE dbo.MSsync_states
		(
			publisher_id smallint not null,
			publisher_db sysname not null,
			publication_id int not null 
		)
		exec dbo.sp_MS_marksystemobject 'MSsync_states'

		CREATE UNIQUE CLUSTERED INDEX ucMSsyncstates on dbo.MSsync_states
		( publisher_id, publisher_db, publication_id )
	END

   IF NOT EXISTS (SELECT * from sys.objects WHERE name = 'MSsubscriptions' and type = 'U')
   BEGIN
	  /****************************************************************************/
	  raiserror('Creating table MSsubscriptions', 0,1)
	  /****************************************************************************/
	   CREATE TABLE dbo.MSsubscriptions
	  (
		publisher_database_id int NOT NULL,         -- Used to reference MSrepl_transactions and MSrepl_commands
		publisher_id smallint NOT NULL,
		publisher_db sysname NOT NULL,
		publication_id int NOT NULL,
		article_id int NOT NULL,
		subscriber_id smallint NOT NULL,
		subscriber_db sysname NOT NULL,
		subscription_type int NOT NULL,         -- 0 = push, 1 = pull, 2 = anonymous 
		sync_type tinyint NOT NULL,                 -- 1 = automatic 2 = no sync
		status tinyint NOT NULL,                        -- 0 = inactive, 1 = subscribed, 2 = active 
		subscription_seqno varbinary(16) NOT NULL,  -- publisher's database sequence number 
		snapshot_seqno_flag bit NOT NULL,               -- 1 if subscription_seqno is the snapshot seqno
		independent_agent bit NOT NULL,             -- Value carried over from MSpublications
		subscription_time datetime NOT NULL, 
		loopback_detection bit NOT NULL,  
		agent_id int NOT NULL,
		update_mode tinyint NOT NULL,  -- 0 = read only, 1 = sync tran, 2 = queued tran, 3 = failover, 4 = sqlqueued tran, 
													   -- 5 = sqlqueued failover, 6 = sqlqueued qfailover, 7 = qfailover
		publisher_seqno varbinary(16) NOT NULL,
		ss_cplt_seqno   varbinary(16) NOT NULL,
		nosync_type     tinyint DEFAULT 0   NOT NULL -- 0(none), 1(replication support only), 2(initialize with backup), 3(initialize from lsn) 
	  )

	  exec dbo.sp_MS_marksystemobject 'MSsubscriptions'

	  raiserror('Creating clustered index ucMSsubscirptions', 0,1)
	  CREATE UNIQUE CLUSTERED INDEX ucMSsubscriptions ON dbo.MSsubscriptions
	  (agent_id, article_id)

	  -- Index used by sp_MSdelete_publisherdb_trans
	  raiserror('Creating index iMSsubscriptions', 0,1)
	  CREATE INDEX iMSsubscriptions ON dbo.MSsubscriptions
	  (publisher_database_id, article_id, subscriber_id, subscriber_db, publication_id, publisher_db, publisher_id)
	END
	ELSE
	BEGIN
		if not exists ( select * from sys.columns 
						where object_id = object_id( N'MSsubscriptions' ) 
						and name = N'ss_cplt_seqno' )
		begin               
			exec ('alter table MSsubscriptions add ss_cplt_seqno varbinary(16) NULL')
			exec ('update MSsubscriptions set ss_cplt_seqno = publisher_seqno')
			exec ('alter table MSsubscriptions alter column ss_cplt_seqno varbinary(16) NOT NULL')
		end
	END

   -- For beta 3 upgrade, we need to create new index here.
   if not exists (select * from sysindexes where name = 'iMSsubscriptions2')
   begin
	  -- Index used by sp_MSdelete_publisherdb_trans
	  raiserror('Creating index iMSsubscriptions2', 0,1)
	  CREATE INDEX iMSsubscriptions2 ON dbo.MSsubscriptions
	  (publisher_database_id, subscription_seqno)
   end

   
   IF NOT EXISTS (SELECT * from sys.objects WHERE name = 'MSmerge_subscriptions' and type = 'U')
   BEGIN
	  /****************************************************************************/
	  raiserror('Creating table MSmerge_subscriptions', 0,1)
	  /****************************************************************************/
	   CREATE TABLE dbo.MSmerge_subscriptions
	  (
		publisher_id smallint NOT NULL,
		publisher_db sysname NULL,
		publication_id int NOT NULL,
		subscriber_id smallint NULL,
		subscriber_db sysname NULL,
		subscription_type int NULL,         -- 0 = push, 1 = pull, 2 = anonymous 
		sync_type tinyint NOT NULL,                 -- 1 = automatic 2 = no sync
		status tinyint NOT NULL,                        -- 0 = inactive, 1 = subscribed, 2 = active 
		subscription_time datetime NOT NULL,
		description nvarchar(255) NULL,
		publisher sysname NULL,
		subscriber sysname NULL,
		subid uniqueidentifier NOT NULL,
		subscriber_version int NULL
	  )
	  exec dbo.sp_MS_marksystemobject 'MSmerge_subscriptions'

	  raiserror('Creating clustered index ucMSmerge_subscriptions', 0,1)
	  CREATE UNIQUE CLUSTERED INDEX ucMSmerge_subscriptions ON dbo.MSmerge_subscriptions(subid)
	  
	  CREATE UNIQUE INDEX unc1MSmerge_subscriptions ON dbo.MSmerge_subscriptions
		(subscriber, subscriber_db, publisher_id, publisher_db, publication_id)
	 
   END
   else
	begin
		/*
		 * Call proc to upgrade MSmerge_subscriptions
		*/
		exec sp_MSmerge_subscriptions_upgrade
		if @@error <> 0
			   return(1)
	
   END


   IF NOT EXISTS (SELECT * from sys.objects WHERE name = 'MSrepl_transactions' and type = 'U')
   BEGIN
	  /****************************************************************************/
	  raiserror('Creating table MSrepl_transactions', 0,1)
	  /****************************************************************************/
	  CREATE TABLE dbo.MSrepl_transactions
	  (
	  publisher_database_id int NOT NULL,
	  xact_id varbinary(16) NULL,
	  xact_seqno varbinary (16 )  NOT NULL,
	  entry_time datetime  NOT NULL
	  )

	  exec dbo.sp_MS_marksystemobject 'MSrepl_transactions'

	  raiserror('Creating clustered index usMSrepl_transactions', 0,1)
	  CREATE UNIQUE CLUSTERED INDEX ucMSrepl_transactions ON dbo.MSrepl_transactions
		 (publisher_database_id, xact_seqno)
		 WITH STATISTICS_NORECOMPUTE

	  CREATE STATISTICS stat_publisher_database_id
		 ON MSrepl_transactions (publisher_database_id)
		WITH NORECOMPUTE

	  CREATE STATISTICS stat_xact_id
		 ON MSrepl_transactions (xact_id)
		 WITH NORECOMPUTE

	  CREATE STATISTICS stat_xact_seqno
		 ON MSrepl_transactions (xact_seqno)
		 WITH NORECOMPUTE

	  CREATE STATISTICS stat_entry_time
		 ON MSrepl_transactions (entry_time)
		 WITH NORECOMPUTE

   END

   IF NOT EXISTS (SELECT * from sys.objects WHERE name = 'MSrepl_commands' and type = 'U')
   BEGIN

	  /****************************************************************************/
	  raiserror('Creating table MSrepl_commands', 0,1)
	  /****************************************************************************/


	  CREATE TABLE dbo.MSrepl_commands (
		  publisher_database_id int not null,
		  xact_seqno varbinary(16) not null,
		  type int not null, 
		  article_id int not null,
		  originator_id int not null,
		  command_id int not null,
		  partial_command bit not null,
		  command varbinary(1024) NULL,
		  hashkey int default 0,
		  originator_lsn varbinary(16) NULL
	  )


	  exec dbo.sp_MS_marksystemobject 'MSrepl_commands'

	  raiserror('Creating clusterd index ucMSrepl_commands', 0,1)
	  CREATE UNIQUE CLUSTERED INDEX ucMSrepl_commands ON dbo.MSrepl_commands
		 (publisher_database_id, xact_seqno, command_id)
		 WITH STATISTICS_NORECOMPUTE

	  -- CREATE INDEX uncMSrepl_commands_originator ON dbo.MSrepl_commands 
	  -- (originator_id, originator_lsn)
	 
	  CREATE STATISTICS stat_xact_seqno
		 ON MSrepl_commands (xact_seqno)
		 WITH NORECOMPUTE

	  CREATE STATISTICS stat_type
		 ON MSrepl_commands (type)
		 WITH NORECOMPUTE

	  CREATE STATISTICS stat_article_id
		 ON MSrepl_commands (article_id)
		 WITH NORECOMPUTE

	  CREATE STATISTICS stat_originator_id
		 ON MSrepl_commands (originator_id)
		 WITH NORECOMPUTE

	  CREATE STATISTICS stat_command_id
		 ON MSrepl_commands (command_id)
		 WITH NORECOMPUTE

	  CREATE STATISTICS stat_partial_command
		 ON MSrepl_commands (partial_command)
		 WITH NORECOMPUTE

   END
   ELSE
   BEGIN
	  IF NOT EXISTS (select * from sys.columns
		where name = 'hashkey'
		and object_id=object_id('MSrepl_commands'))
	  BEGIN         
		 ALTER TABLE MSrepl_commands ADD hashkey int default 0
	  END

	  IF NOT EXISTS (select * from sys.columns
		where name = 'originator_lsn'
		and object_id=object_id('MSrepl_commands'))
	  BEGIN         
		 ALTER TABLE MSrepl_commands ADD originator_lsn varbinary(16) NULL
	  END
   END

   IF NOT EXISTS (SELECT * from sys.objects WHERE name = 'MSrepl_originators' and type = 'U')
   BEGIN
	  /****************************************************************************/
	  raiserror('Creating table MSrepl_orginators', 0,1)
	  /****************************************************************************/
	  CREATE TABLE dbo.MSrepl_originators
	  (
		  id 					int identity not null,
		  publisher_database_id int not null,
		  srvname   			sysname not null,
		  dbname    			sysname not null,
		  publication_id 		int NULL,
		  dbversion 			int NULL
	  )

	  exec dbo.sp_MS_marksystemobject 'MSrepl_originators'

	  raiserror('Creating clustered index usMSrepl_originators', 0,1)
	  CREATE UNIQUE CLUSTERED INDEX ucMSrepl_originators ON dbo.MSrepl_originators
		 (id, srvname, dbname, publication_id, dbversion)
   END
   ELSE
   BEGIN
		 IF NOT EXISTS (select * from sys.columns
		where name = 'publication_id'
		and object_id=object_id('MSrepl_originators'))
	  BEGIN         
		 ALTER TABLE MSrepl_originators ADD publication_id int NULL
	  END
	  
	  IF NOT EXISTS (select * from sys.columns
		where name = 'dbversion'
		and object_id=object_id('MSrepl_originators'))
	  BEGIN         
		 ALTER TABLE MSrepl_originators ADD dbversion int NULL
	  END

	  raiserror('Creating clustered index usMSrepl_originators', 0,1)
	  CREATE UNIQUE CLUSTERED INDEX ucMSrepl_originators ON dbo.MSrepl_originators
		 (id, srvname, dbname, publication_id, dbversion)
	  WITH DROP_EXISTING 
   END
	
   IF NOT EXISTS (SELECT * from sys.objects WHERE name = 'MSsubscriber_info' and type = 'U')
   BEGIN
	  /****************************************************************************/
	  raiserror('Creating table MSsubscriber_info', 0,1)
	  /****************************************************************************/
	  CREATE TABLE dbo.MSsubscriber_info
	  (
	  publisher  sysname NOT NULL,
	  subscriber  sysname NOT NULL,
	  type tinyint NOT NULL,           /* 0: MS SQL Server 1: ODBC Data Source */
	  login sysname NULL,
	  password nvarchar(524) NULL,
	  description nvarchar(510) NULL,
	  security_mode int NOT NULL
	  )

	  exec dbo.sp_MS_marksystemobject 'MSsubscriber_info'

	  raiserror('Creating clustered index ucMSsubscriber_info', 0,1)
	  CREATE UNIQUE CLUSTERED INDEX ucMSsubscriber_info ON dbo.MSsubscriber_info
	 (publisher, subscriber)
   END
   ELSE
   BEGIN
	  IF NOT EXISTS (select * from sys.columns
		where name = 'password'
		and object_id=object_id('MSsubscriber_info'))
	  BEGIN
		 ALTER TABLE MSsubscriber_info ADD password nvarchar (524) NULL
	  END
	  ELSE
	  BEGIN
		 ALTER TABLE MSsubscriber_info ALTER COLUMN password nvarchar (524) NULL
	  END
	  
	  IF NOT EXISTS (select * from sys.columns
		where name = 'description'
		and object_id=object_id('MSsubscriber_info'))
	  BEGIN
		 ALTER TABLE MSsubscriber_info ADD description nvarchar (510) NULL
		 UPDATE MSsubscriber_info SET description = 'SQL Server 6.0'
	  END
	  ELSE
	  BEGIN
		 ALTER TABLE MSsubscriber_info ALTER COLUMN description nvarchar (510) NULL
	  END
   END

   IF NOT EXISTS (SELECT * from sys.objects WHERE name = 'MSsubscriber_schedule' and type = 'U')
   BEGIN
		 raiserror('Creating table MSsubscriber_schedule', 0,1)
		 
		CREATE TABLE dbo.MSsubscriber_schedule
		(
			publisher  sysname NOT NULL,
			subscriber  sysname NOT NULL,
			agent_type      smallint NOT NULL,   -- 0 for distribution agent, 1 for merge agent
			frequency_type int NOT NULL,
			frequency_interval int NOT NULL,
			frequency_relative_interval int NOT NULL,
			frequency_recurrence_factor int NOT NULL,
			frequency_subday int NOT NULL,
			frequency_subday_interval int NOT NULL,
			active_start_time_of_day int NOT NULL,
			active_end_time_of_day int NOT NULL,
			active_start_date int NOT NULL,
			active_end_date int NOT NULL
		)
	  exec dbo.sp_MS_marksystemobject 'MSsubscriber_schedule'

		CREATE UNIQUE CLUSTERED INDEX ucMSsubscriber_schedule ON dbo.MSsubscriber_schedule
	 (publisher, subscriber, agent_type)
	 
	END

   IF NOT EXISTS (SELECT * from sys.objects WHERE name = 'MSsnapshot_history' and type = 'U')
   BEGIN
		/****************************************************************************/
		 raiserror('Creating table MSsnapshot_history', 0,1)
		/****************************************************************************/
		CREATE TABLE dbo.MSsnapshot_history 
		(
		agent_id int NOT NULL,
		runstatus int NOT NULL,
		start_time datetime NOT NULL,        
		time datetime NOT NULL,    
		duration int NOT NULL,            
		comments nvarchar(1000) NOT NULL,

		-- Session summary statistics
		delivered_transactions int NOT NULL,
		delivered_commands int NOT NULL,
		delivery_rate float NOT NULL,

		error_id int NOT NULL,
		timestamp NOT NULL
	)

	  exec dbo.sp_MS_marksystemobject 'MSsnapshot_history'

	 raiserror('Creating clustered index ucMSsnapshot_history', 0,1)
	CREATE UNIQUE CLUSTERED INDEX ucMSsnapshot_history ON dbo.MSsnapshot_history
		(agent_id, timestamp, start_time, time)

   END
   ELSE 
   BEGIN
	   if exists (select * from sysindexes where name = 'nc1MSsnapshot_history' and id=object_id('MSsnapshot_history'))
	begin
		drop index MSsnapshot_history.nc1MSsnapshot_history
	end
	   if exists (select * from sys.columns where name = 'comments' and object_id=object_id('MSsnapshot_history'))
	   begin 
		alter table MSsnapshot_history alter column comments nvarchar(1000) NOT NULL
	   end
   END
   
   IF NOT EXISTS (SELECT * from sys.objects WHERE name = 'MSlogreader_history' and type = 'U')
   BEGIN
		/****************************************************************************/
		raiserror('Creating table MSlogreader_history', 0,1)
		/****************************************************************************/    
		CREATE TABLE dbo.MSlogreader_history
		(
		agent_id int NOT NULL,
		runstatus int NOT NULL,
		start_time datetime NOT NULL,
		time datetime NOT NULL,
		duration int NOT NULL,
		comments nvarchar(4000) NOT NULL,
		xact_seqno varbinary(16) NULL,

		-- Session summary statistics
		delivery_time int NOT NULL,
		delivered_transactions int NOT NULL,
		delivered_commands int NOT NULL,
		average_commands int NOT NULL,
		delivery_rate float NOT NULL,
		delivery_latency int NOT NULL,

		error_id int NOT NULL,
		timestamp NOT NULL,
		updateable_row bit NOT NULL default 0
		)

	  exec dbo.sp_MS_marksystemobject 'MSlogreader_history'

	raiserror('Creating clustered index ucMSlogreader_history', 0,1)
	CREATE UNIQUE CLUSTERED INDEX ucMSlogreader_history ON dbo.MSlogreader_history
		(agent_id, timestamp, runstatus, start_time, time) 

   END
   ELSE
   BEGIN
		if exists (select * from sysindexes where name = 'nc1MSlogreader_history' and id=object_id('MSlogreader_history'))
	begin
		drop index MSlogreader_history.nc1MSlogreader_history
	end
	   if exists (select * from sys.columns where name = 'comments' and object_id=object_id('MSlogreader_history'))
	   begin 
		alter table MSlogreader_history alter column comments nvarchar(4000) NOT NULL
	   end	
	   if not exists (select * from sys.columns where name = 'updateable_row' and object_id=object_id('MSlogreader_history'))
	   begin 
		alter table MSlogreader_history add updateable_row bit NOT NULL default 0
	   end	
   END
   
   IF NOT EXISTS (SELECT * from sys.objects WHERE name = 'MSdistribution_history' and type = 'U')
   BEGIN
		/****************************************************************************/
		  raiserror('Creating table MSdistribution_history', 0,1)
		/****************************************************************************/    

		CREATE TABLE dbo.MSdistribution_history
		(
		agent_id int NOT NULL,
		runstatus int NOT NULL,
		start_time datetime NOT NULL,
		time datetime NOT NULL,
		duration int NOT NULL,
		comments nvarchar(max) NOT NULL,
		xact_seqno varbinary(16) NULL,

		-- Current statistics
		current_delivery_rate float NOT NULL,
		current_delivery_latency int NOT NULL,

		-- Session summary statistics
		delivered_transactions int NOT NULL,
		delivered_commands int NOT NULL,
		average_commands int NOT NULL,
		delivery_rate float NOT NULL,       
		delivery_latency int NOT NULL, 

		-- Summary statistics across all sessions
		total_delivered_commands bigint NOT NULL, 

		error_id int NOT NULL,
		updateable_row bit NOT NULL,
		timestamp NOT NULL
		)

	exec dbo.sp_MS_marksystemobject 'MSdistribution_history'

	raiserror('Creating clustered index ucMSdistribution_history', 0,1)
	CREATE UNIQUE CLUSTERED INDEX ucMSdistribution_history ON dbo.MSdistribution_history
		(agent_id, timestamp, runstatus, start_time, time) 

   END
   ELSE
   BEGIN
		IF EXISTS (select * from sys.columns
			where name = 'comments' 
			and object_id=object_id('MSdistribution_history'))
		BEGIN 
			ALTER TABLE MSdistribution_history ALTER COLUMN comments nvarchar(max) NOT NULL
		END
		if exists (select * from sysindexes where name = 'nc1MSdistribution_history' and id=object_id('MSdistribution_history'))
		begin
			drop index MSdistribution_history.nc1MSdistribution_history
		end
   END

   exec sys.sp_MScreate_common_dist_tables @subside = 0

   IF NOT EXISTS (SELECT * from sys.objects WHERE name = 'MSsnapshot_agents' and type = 'U')
   BEGIN
		/****************************************************************************/
		raiserror('Creating table MSsnapshot_agents', 0,1)
		/****************************************************************************/    

		CREATE TABLE dbo.MSsnapshot_agents
		(
		id                  int IDENTITY NOT NULL,
		name                nvarchar(100) NOT NULL,
		publisher_id        smallint NOT NULL,
		publisher_db        sysname NOT NULL,
		publication         sysname NOT NULL,
		publication_type    int NOT NULL,       -- 0 transactional 1 snapshot 2 merge
		local_job           bit NOT NULL,
		job_id              binary(16) NULL,
		profile_id  int     NOT NULL,
		dynamic_filter_login     sysname NULL, -- used only for merge dynamic snapshot. Should be null otherwise
		dynamic_filter_hostname  sysname NULL,  -- used only for merge dynamic snapshot. Should be null otherwise  
		publisher_security_mode int NULL,
		publisher_login 		sysname NULL,
		publisher_password		nvarchar(524) NULL,
		job_step_uid		uniqueidentifier NULL,
		job_login          nvarchar(257) NULL, -- used for CL only
		job_password       nvarchar(524) NULL  -- used for CL only
		)

	  exec dbo.sp_MS_marksystemobject 'MSsnapshot_agents'

	raiserror('Creating clustered index ucMSsnapshot_agents', 0,1)
	CREATE CLUSTERED INDEX ucMSsnapshot_agents ON dbo.MSsnapshot_agents
		(publication, publisher_db, publisher_id) 

	raiserror('Creatingindex iMSsnapshot_agents', 0,1)
	CREATE UNIQUE INDEX iMSsnapshot_agents ON dbo.MSsnapshot_agents
		(id)
   END
   ELSE
   BEGIN
		IF NOT EXISTS (select * from sys.columns
			where name = 'dynamic_filter_login'
			and object_id=object_id('MSsnapshot_agents'))
		BEGIN 
			ALTER TABLE MSsnapshot_agents ADD dynamic_filter_login sysname NULL
		END

		IF NOT EXISTS (select * from sys.columns
			where name = 'dynamic_filter_hostname'
			and object_id=object_id('MSsnapshot_agents'))
		BEGIN         
			ALTER TABLE MSsnapshot_agents ADD dynamic_filter_hostname sysname NULL
		END

		IF NOT EXISTS (select * from sys.columns where object_id=object_id('MSsnapshot_agents') and name = 'publisher_security_mode')
		BEGIN
			ALTER TABLE MSsnapshot_agents ADD publisher_security_mode int NULL
		END

		IF NOT EXISTS (select * from sys.columns where object_id=object_id('MSsnapshot_agents') and name = 'publisher_login')
		BEGIN
			ALTER TABLE MSsnapshot_agents ADD publisher_login sysname NULL
		END

		IF NOT EXISTS (select * from sys.columns where object_id=object_id('MSsnapshot_agents') and name = 'publisher_password')
		BEGIN
			ALTER TABLE MSsnapshot_agents ADD publisher_password nvarchar(524) NULL
		END

		IF NOT EXISTS (select * from sys.columns where object_id=object_id('MSsnapshot_agents') and name = 'job_step_uid')
		BEGIN
			ALTER TABLE MSsnapshot_agents ADD job_step_uid uniqueidentifier NULL
		END

		IF NOT EXISTS (select * from sys.columns where object_id=object_id('MSsnapshot_agents') and name = 'job_login')
		BEGIN
			ALTER TABLE MSsnapshot_agents ADD job_login nvarchar(257) NULL -- used for CL only
   END

		IF NOT EXISTS (select * from sys.columns where object_id=object_id('MSsnapshot_agents') and name = 'job_password')
		BEGIN
			ALTER TABLE MSsnapshot_agents ADD job_password nvarchar(524) NULL -- used for CL only
		END
   END


   IF NOT EXISTS (SELECT * from sys.objects WHERE name = 'MSlogreader_agents' and type = 'U')
   BEGIN
		/****************************************************************************/
		raiserror('Creating table MSlogreader_agents', 0,1)
		/****************************************************************************/    

		CREATE TABLE dbo.MSlogreader_agents
		(
		id                  int IDENTITY NOT NULL,
		name                nvarchar(100) NOT NULL,
		publisher_id        smallint NOT NULL,
		publisher_db        sysname NOT NULL,
		publication         sysname NOT NULL,-- Not used for SQL Server publisher
		local_job           bit NOT NULL,
		job_id              binary(16) NULL,
		profile_id  int     NOT NULL,
		publisher_security_mode smallint NULL,
		publisher_login 	sysname NULL,
		publisher_password 	nvarchar(524) NULL,
		job_step_uid		uniqueidentifier NULL,
		job_login          nvarchar(257) NULL, -- used for CL only
		job_password       nvarchar(524) NULL  -- used for CL only
		)

	  exec dbo.sp_MS_marksystemobject 'MSlogreader_agents'

	raiserror('Creating clustered index ucMSlogreader_agents', 0,1)
	CREATE CLUSTERED INDEX ucMSlogreader_agents ON dbo.MSlogreader_agents
		(publisher_db, publisher_id) 

	raiserror('Creatingindex iMSlogreader_agents', 0,1)
	CREATE UNIQUE INDEX iMSlogreader_agents ON dbo.MSlogreader_agents
		(id)
   END
   ELSE
   BEGIN
	   IF NOT EXISTS (select * from sys.columns where object_id=object_id('MSlogreader_agents') and name = 'publisher_security_mode')
	   BEGIN
		   ALTER TABLE MSlogreader_agents ADD publisher_security_mode smallint NULL
	   END

	   IF NOT EXISTS (select * from sys.columns where object_id=object_id('MSlogreader_agents') and name = 'publisher_login')
	   BEGIN
		   ALTER TABLE MSlogreader_agents ADD publisher_login sysname NULL
	   END	

	   IF NOT EXISTS (select * from sys.columns where object_id=object_id('MSlogreader_agents') and name = 'publisher_password')
	   BEGIN	 
		   ALTER TABLE MSlogreader_agents ADD publisher_password nvarchar(524) NULL
	   END
	   
	   IF NOT EXISTS (select * from sys.columns where object_id=object_id('MSlogreader_agents') and name = 'job_step_uid')
	   BEGIN
		   ALTER TABLE MSlogreader_agents ADD job_step_uid uniqueidentifier NULL
	   END

	   IF NOT EXISTS (select * from sys.columns where object_id=object_id('MSlogreader_agents') and name = 'job_login')
	   BEGIN
		   ALTER TABLE MSlogreader_agents ADD job_login nvarchar(257) NULL -- used for CL only
	   END

	   IF NOT EXISTS (select * from sys.columns where object_id=object_id('MSlogreader_agents') and name = 'job_password')
	   BEGIN
		   ALTER TABLE MSlogreader_agents ADD job_password nvarchar(524) NULL -- used for CL only
	   END
   END

   IF NOT EXISTS (SELECT * from sys.objects WHERE name = 'MSdistribution_agents' and type = 'U')
   BEGIN
		/****************************************************************************/
		raiserror('Creating table MSdistribution_agents', 0,1)
		/****************************************************************************/    

		CREATE TABLE dbo.MSdistribution_agents
		(
		id                  int IDENTITY NOT NULL,
		   name 			    nvarchar(100) NOT NULL,
		publisher_database_id int NOT NULL,
		publisher_id        smallint NOT NULL,
		publisher_db        sysname NOT NULL,
		publication         sysname NOT NULL,
		subscriber_id       smallint NULL, 
		subscriber_db       sysname NULL,
		subscription_type   int NOT NULL,
		local_job           bit NULL,
		job_id              binary(16) NULL,
		subscription_guid   binary(16) NOT NULL,
		profile_id  int     NOT NULL,
		anonymous_subid     uniqueidentifier NULL,
		subscriber_name     sysname NULL,
		virtual_agent_id    int NULL,
		anonymous_agent_id  int NULL,
		creation_date       datetime default (getdate()) not NULL,
		queue_id            sysname null,
		queue_status        int default 0 not null,
		offload_enabled     bit default 0 NOT NULL,
		offload_server      sysname NULL,
		dts_package_name    sysname NULL,
		dts_package_password nvarchar(524) NULL,
		dts_package_location int default 0 not null,
		sid                 varbinary(85) default suser_sid() not null,
		queue_server        sysname NULL,
		-- used for subscription based security
		subscriber_security_mode 	smallint NULL,
		subscriber_login			sysname NULL,
		subscriber_password 		nvarchar(524) NULL,
		reset_partial_snapshot_progress bit default 0 not null,
		job_step_uid				uniqueidentifier NULL
		,subscriptionstreams tinyint NULL
		,subscriber_type tinyint NULL
		,subscriber_provider sysname NULL
		,subscriber_datasrc nvarchar(4000) NULL
		,subscriber_location nvarchar(4000) NULL
		,subscriber_provider_string nvarchar(4000) NULL
		,subscriber_catalog sysname NULL
		,memory_optimized bit default 0
		,job_login          nvarchar(257) NULL -- used for CL only
		,job_password       nvarchar(524) NULL -- used for CL only
		)

		exec dbo.sp_MS_marksystemobject 'MSdistribution_agents'

		raiserror('Creating clustered index ucMSdistribution_agents', 0,1)
		CREATE UNIQUE CLUSTERED INDEX ucMSdistribution_agents ON dbo.MSdistribution_agents
			(id)

		raiserror('Creatingindex iMSdistribution_agents', 0,1)
		CREATE INDEX iMSdistribution_agents ON dbo.MSdistribution_agents
			(publication, publisher_db, publisher_id, subscriber_id, subscriber_db, anonymous_subid) 
   END
   
	if not exists (select * from sys.columns where 
		object_id = object_id('MSdistribution_agents') and
		name = 'creation_date')
	begin
		alter table MSdistribution_agents add creation_date datetime default (getdate()) not null
	end 

	if not exists (select * from sys.columns where 
		object_id = object_id('MSdistribution_agents') and
		name = 'offload_enabled')
	begin
		alter table MSdistribution_agents add offload_enabled bit default 0 not null
	end 

	if not exists (select * from sys.columns where 
		object_id = object_id('MSdistribution_agents') and
		name = 'offload_server')
	begin
		alter table MSdistribution_agents add offload_server sysname null
	end 

	if not exists (select * from sys.columns where 
		object_id = object_id('MSdistribution_agents') and
		name = 'queue_id')
	begin
		alter table MSdistribution_agents add queue_id sysname null
	end 

	if not exists (select * from sys.columns where 
		object_id = object_id('MSdistribution_agents') and
		name = 'queue_status')
	begin
		alter table MSdistribution_agents add queue_status int default 0 not null
	end 

	if not exists (select * from sys.columns where 
		object_id = object_id('MSdistribution_agents') and
		name = 'dts_package_name')
	begin
		alter table MSdistribution_agents add dts_package_name sysname null
	end 
	if not exists (select * from sys.columns where 
		object_id = object_id('MSdistribution_agents') and
		name = 'dts_package_password')
	begin
		alter table MSdistribution_agents add dts_package_password nvarchar(524) null
	end 

	if not exists (select * from sys.columns where 
		object_id = object_id('MSdistribution_agents') and
		name = 'dts_package_location')
	begin
		alter table MSdistribution_agents add dts_package_location int default 0 not null
	end 

	if not exists (select * from sys.columns where 
		object_id = object_id('MSdistribution_agents') and
		name = 'sid')
	begin
		-- set sid to be the upgrade user. db_owner or sysadmin
		-- can drop the agent entry
		alter table MSdistribution_agents add sid varbinary(85) default suser_sid() not null
	end 

	if not exists (select * from sys.columns where 
		object_id = object_id('MSdistribution_agents') and
		name = 'queue_server')
	begin
		alter table MSdistribution_agents add queue_server sysname null
		EXEC sys.sp_MSupdate_mqserver_distdb
	end 

	-- used for subscription based security
	if not exists (select * from sys.columns where 
		object_id = object_id('MSdistribution_agents') and
		name = 'subscriber_security_mode')
	begin
		alter table MSdistribution_agents add subscriber_security_mode smallint null 
	end 

	if not exists (select * from sys.columns where 
		object_id = object_id('MSdistribution_agents') and
		name = 'subscriber_login')
	begin
		alter table MSdistribution_agents add subscriber_login sysname null 
	end 

	if not exists (select * from sys.columns where 
		object_id = object_id('MSdistribution_agents') and
		name = 'subscriber_password')
	begin
		alter table MSdistribution_agents add subscriber_password nvarchar(524) null 
	end 

	if not exists (select * from sys.columns where 
		object_id = object_id('MSdistribution_agents') and
		name = 'reset_partial_snapshot_progress')
	begin
		ALTER TABLE MSdistribution_agents ADD reset_partial_snapshot_progress bit default 0 not null
	end 

	if not exists (select * from sys.columns where 
		object_id = object_id('MSdistribution_agents') and
		name = 'job_step_uid')
	begin
		ALTER TABLE MSdistribution_agents ADD job_step_uid uniqueidentifier NULL
	end 

	if not exists (select * from sys.columns where 
		object_id = object_id('MSdistribution_agents') and
		name = 'subscriptionstreams')
	begin
		ALTER TABLE MSdistribution_agents ADD subscriptionstreams tinyint NULL
	end
	
	if not exists (select * from sys.columns where 
		object_id = object_id('MSdistribution_agents') and
		name = 'subscriber_type')
	begin
		ALTER TABLE MSdistribution_agents ADD subscriber_type tinyint NULL
	end 

	if not exists (select * from sys.columns where 
		object_id = object_id('MSdistribution_agents') and
		name = 'subscriber_provider')
	begin
		ALTER TABLE MSdistribution_agents ADD subscriber_provider sysname NULL
	end 
	
	if not exists (select * from sys.columns where 
		object_id = object_id('MSdistribution_agents') and
		name = 'subscriber_datasrc')
	begin
		ALTER TABLE MSdistribution_agents ADD subscriber_datasrc nvarchar(4000) NULL
	end 
	
	if not exists (select * from sys.columns where 
		object_id = object_id('MSdistribution_agents') and
		name = 'subscriber_location')
	begin
		ALTER TABLE MSdistribution_agents ADD subscriber_location nvarchar(4000) NULL
	end 

	if not exists (select * from sys.columns where 
		object_id = object_id('MSdistribution_agents') and
		name = 'subscriber_provider_string')
	begin
		ALTER TABLE MSdistribution_agents ADD subscriber_provider_string nvarchar(4000) NULL
	end
	 
	if not exists (select * from sys.columns where 
		object_id = object_id('MSdistribution_agents') and
		name = 'subscriber_catalog')
	begin
		ALTER TABLE MSdistribution_agents ADD subscriber_catalog sysname NULL
	end 

	if not exists (select * from sys.columns where 
		object_id = object_id('MSdistribution_agents') and
		name = 'memory_optimized')
	begin
		ALTER TABLE MSdistribution_agents ADD memory_optimized bit default 0
	end

	IF NOT EXISTS (select * from sys.columns where object_id = object_id('MSdistribution_agents') and name = 'job_login')
	BEGIN
		ALTER TABLE MSdistribution_agents ADD job_login nvarchar(257) NULL -- used for CL only
	END

	IF NOT EXISTS (select * from sys.columns where object_id = object_id('MSdistribution_agents') and name = 'job_password')
	BEGIN
		ALTER TABLE MSdistribution_agents ADD job_password nvarchar(524) NULL -- used for CL only
	END

   IF NOT EXISTS (SELECT * from sys.objects WHERE name = 'MSmerge_agents' and type = 'U')
   BEGIN
		/****************************************************************************/
		raiserror('Creating table MSmerge_agents', 0,1)
		/****************************************************************************/    

		CREATE TABLE dbo.MSmerge_agents
		(
		id                  int IDENTITY NOT NULL,
		name                nvarchar(100) NOT NULL,
		publisher_id        smallint NOT NULL,
		publisher_db        sysname NOT NULL,
		publication         sysname NOT NULL,
		subscriber_id       smallint NULL,
		subscriber_db       sysname NULL,
		local_job           bit NULL,
		job_id              binary(16) NULL,
		profile_id          int NULL,
		anonymous_subid     uniqueidentifier NULL,
		subscriber_name     sysname NULL,
		creation_date       datetime default (getdate()) not NULL,
		offload_enabled     bit default 0 NOT NULL,
		offload_server      sysname NULL,
		sid                 varbinary(85) default suser_sid() not null,
		-- used for subscription based security
		subscriber_security_mode 	smallint NULL,
		subscriber_login			sysname NULL,
		subscriber_password 		nvarchar(524) NULL,
		publisher_security_mode 	smallint NULL,
		publisher_login 			sysname NULL,
		publisher_password 			nvarchar(524) NULL,
		job_step_uid				uniqueidentifier NULL
		)

	  exec dbo.sp_MS_marksystemobject 'MSmerge_agents'

		raiserror('Creating clustered index ucMSmerge_agents', 0,1)
		
		CREATE UNIQUE clustered INDEX ucMSmerge_agents ON dbo.MSmerge_agents(id)
		
		CREATE INDEX iMSmerge_agents ON dbo.MSmerge_agents
			(publication, publisher_db, publisher_id, subscriber_id, subscriber_db, anonymous_subid) 
		
		CREATE INDEX i2MSmerge_agents ON dbo.MSmerge_agents
			(subscriber_id, subscriber_db) 
		
	END
	else
	begin
		if EXISTS (select * from sys.indexes where name='ucMSmerge_agents' and object_id=object_id('MSmerge_agents'))
		begin
			drop index MSmerge_agents.ucMSmerge_agents
		end
		
		if EXISTS (select * from sys.indexes where name='iMSmerge_agents' and object_id=object_id('MSmerge_agents'))
		begin
			drop index MSmerge_agents.iMSmerge_agents
		end
		
		if EXISTS (select * from sys.indexes where name='i2MSmerge_agents' and object_id=object_id('MSmerge_agents'))
		begin
			drop index MSmerge_agents.i2MSmerge_agents
		end
		
		CREATE UNIQUE clustered INDEX ucMSmerge_agents ON dbo.MSmerge_agents(id)
		
		CREATE INDEX iMSmerge_agents ON dbo.MSmerge_agents
			(publication, publisher_db, publisher_id, subscriber_id, subscriber_db, anonymous_subid) 
		
		CREATE INDEX i2MSmerge_agents ON dbo.MSmerge_agents
			(subscriber_id, subscriber_db) 
	end
	
	if not exists (select * from sys.columns where 
		object_id = object_id('MSmerge_agents') and
		name = 'creation_date')
	begin
		alter table MSmerge_agents add creation_date datetime default (getdate()) not null
	end 

	if not exists (select * from sys.columns where 
		object_id = object_id('MSmerge_agents') and
		name = 'offload_enabled')
	begin
		alter table MSmerge_agents add offload_enabled bit default 0 not null
	end 

	if not exists (select * from sys.columns where 
		object_id = object_id('MSmerge_agents') and
		name = 'offload_server')
	begin
		alter table MSmerge_agents add offload_server sysname null
	end 

	if not exists (select * from sys.columns where 
		object_id = object_id('MSmerge_agents') and
		name = 'sid')
	begin
		-- set sid to be the upgrade user. db_owner or sysadmin
		-- can drop the agent entry
		alter table MSmerge_agents add sid varbinary(85) default suser_sid() not null
	end 

	-- used for subscription based security
	if not exists (select * from sys.columns where 
		object_id = object_id('MSmerge_agents') and
		name = 'subscriber_security_mode')
	begin
		alter table MSmerge_agents add subscriber_security_mode smallint null 
	end 

	if not exists (select * from sys.columns where 
		object_id = object_id('MSmerge_agents') and
		name = 'subscriber_login')
	begin
		alter table MSmerge_agents add subscriber_login sysname null 
	end 

	if not exists (select * from sys.columns where 
		object_id = object_id('MSmerge_agents') and
		name = 'subscriber_password')
	begin
		alter table MSmerge_agents add subscriber_password nvarchar(524) null 
	end 

	   if not exists (select * from sys.columns where 
	   object_id = object_id('MSmerge_agents') and
	   name = 'publisher_security_mode')
	begin
	   alter table MSmerge_agents add publisher_security_mode smallint null 
	end 

	if not exists (select * from sys.columns where 
	   object_id = object_id('MSmerge_agents') and
	   name = 'publisher_login')
	begin
	   alter table MSmerge_agents add publisher_login sysname null 
	end 

	if not exists (select * from sys.columns where 
	   object_id = object_id('MSmerge_agents') and
	   name = 'publisher_password')
	begin
	   alter table MSmerge_agents add publisher_password nvarchar(524) null 
	end 

	if not exists (select * from sys.columns where 
	   object_id = object_id('MSmerge_agents') and
	   name = 'job_step_uid')
	begin
	   alter table MSmerge_agents add job_step_uid uniqueidentifier NULL
	end
	
	   -- Need to re_visit the indexing of this table
	if not exists (select * from sys.objects where name = 'MSrepl_identity_range')
	begin 	  
		raiserror('Creating table MSrepl_identity_range',0,1)

		create table dbo.MSrepl_identity_range (
			publisher 			  sysname not NULL, 
			publisher_db			  sysname not NULL,
			tablename 			  sysname not NULL,
			identity_support		  int NULL,
			next_seed 			  bigint NULL, --resource control
			pub_range 			  bigint NULL, --publisher range
			range 				  bigint NULL, -- set by sp_addmergearticle
			max_identity			  bigint NULL, --resource control
			threshold 			  int NULL,   --in percentage, set by sp_addmergearticle
			current_max			  bigint NULL, --max value for current check constraint,set by sp_addmergearticle
			constraint pkMSrepl_identity_range
				primary key(publisher,publisher_db,tablename)
		)
		exec dbo.sp_MS_marksystemobject MSrepl_identity_range
	end

	IF NOT EXISTS (SELECT * from sys.objects WHERE name = 'MSpublication_access' and type = 'U')
	BEGIN
		/****************************************************************************/
		raiserror('Creating table MSpublication_access', 0,1)
		/****************************************************************************/    

		CREATE TABLE dbo.MSpublication_access
		(
		publication_id      int NULL,       	-- Publication_id is unique in distribution database.
		login               sysname NOT NULL,	-- Logins in the publication access list, they nust
												-- exist at both publisher and distributor side.
		sid					varbinary(85) NULL
		)

		exec dbo.sp_MS_marksystemobject 'MSpublication_access'

		raiserror('Creating clustered index ucMSpublication_access', 0,1)
		CREATE UNIQUE CLUSTERED INDEX ucMSpublication_access ON dbo.MSpublication_access
			(publication_id, sid) 
	END

	-- For b3 upgrade
	if NOT EXISTS (select * from sys.columns where name='retention' and object_id=object_id('MSpublications'))
	begin
		alter table MSpublications add retention int NULL 
		UPDATE msdb..MSdistributiondbs set max_distretention=72 where
			name = db_name() collate database_default
	end
	
	if NOT EXISTS (select * from sys.columns where name='retention_period_unit' and object_id=object_id('MSpublications'))
	begin
		alter table MSpublications add retention_period_unit tinyint default 0 not null
	end

	-- drop default_access column
	if exists (select * from sys.columns where object_id = object_id('MSpublications') and
		name = 'default_access')
	begin
		alter table MSpublications drop column default_access
	end 

	IF NOT EXISTS (SELECT * FROM sys.columns WHERE name='sid' and object_id=object_id('MSpublication_access'))
	BEGIN
		ALTER TABLE dbo.MSpublication_access ADD sid varbinary(85) NULL

		EXEC('UPDATE MSpublication_access SET sid = SUSER_SID(login,0)')
	END
	
	-- Drop publisher_id column
	if EXISTS (select * from sys.columns where name='publisher_id' and object_id=object_id('MSpublication_access'))
	begin
		drop index MSpublication_access.ucMSpublication_access

		alter table MSpublication_access drop column publisher_id

		raiserror('Creating clustered index ucMSpublication_access', 0,1)
		CREATE CLUSTERED INDEX ucMSpublication_access ON dbo.MSpublication_access
		(publication_id, sid) 
	end

	IF NOT EXISTS (SELECT * from sys.objects WHERE name = 'MSqreader_agents' and type = 'U')
	BEGIN
		/****************************************************************************/
		raiserror('Creating table MSqreader_agents', 0,1)
		/****************************************************************************/    

		CREATE TABLE dbo.MSqreader_agents
		(
		id                  int IDENTITY NOT NULL,
		name                nvarchar(100) NULL,
		job_id              binary(16) NULL,
		profile_id          int NULL,
		job_step_uid		uniqueidentifier NULL
		)

	  exec dbo.sp_MS_marksystemobject 'MSqreader_agents'

	raiserror('Creating unique index ucMSqreader_agents', 0,1)
	CREATE UNIQUE INDEX ucMSqreader_agents ON dbo.MSqreader_agents
		(id)
   END

	-- add columns for existing table
	if not exists (select * from sys.columns where 
		object_id = object_id('MSqreader_agents') and
		name = 'profile_id')
	begin
		alter table dbo.MSqreader_agents add profile_id int NULL
	end 

   if not exists (select * from sys.columns where 
	   object_id = object_id('MSqreader_agents') and
	   name = 'job_step_uid')
   begin
	   alter table dbo.MSqreader_agents add job_step_uid uniqueidentifier NULL
   end 
		 

	IF NOT EXISTS (SELECT * from sys.objects WHERE name = 'MSqreader_history' and type = 'U')
	BEGIN
	/****************************************************************************/
	raiserror('Creating table MSqreader_history', 0,1)
	/****************************************************************************/    

	CREATE TABLE dbo.MSqreader_history
	(
	agent_id int NOT NULL,
	publication_id int NULL,
	runstatus int NOT NULL,
	start_time datetime NOT NULL,
	time datetime NOT NULL,
	duration int NOT NULL,
	comments nvarchar(1000) NOT NULL,
	transaction_id nvarchar(40) NULL, 
	transaction_status int NULL,
	transactions_processed int NULL DEFAULT 0,
	commands_processed int NULL DEFAULT 0,
	delivery_rate float NOT NULL DEFAULT 0.0,
	transaction_rate float NOT NULL DEFAULT 0.0,
	subscriber sysname NULL,
	subscriberdb sysname NULL,
	error_id int NULL,    
	timestamp NOT NULL
	)

	exec dbo.sp_MS_marksystemobject 'MSqreader_history'

	raiserror('Creating clustered index ucMSqreader_history', 0,1)
	CREATE CLUSTERED INDEX ucMSqreader_history ON dbo.MSqreader_history
	(agent_id, timestamp, runstatus, start_time, time) 
	END
	ELSE
	BEGIN
	   if exists (select * from sys.columns where name = 'comments' and object_id=object_id('MSqreader_history'))
	   begin 
		alter table MSqreader_history alter column comments nvarchar(1000) NOT NULL
	   end	    
	END

	-- alter column publication_id
	if not exists (select * from sys.columns where 
		object_id = object_id('MSqreader_history') and
		name = 'publication_id')
	begin
		alter table dbo.MSqreader_history alter column publication_id int NULL
	end

	-- add columns for existing table
	if not exists (select * from sys.columns where 
		object_id = object_id('MSqreader_history') and
		name = 'error_id')
	begin
		alter table dbo.MSqreader_history add error_id int NULL
	end 

	if not exists (select * from sys.columns where 
		object_id = object_id('MSqreader_history') and
		name = 'transactions_processed')
	begin
		alter table dbo.MSqreader_history add transactions_processed int NULL DEFAULT 0
	end 

	if not exists (select * from sys.columns where 
		object_id = object_id('MSqreader_history') and
		name = 'delivery_rate')
	begin
		alter table dbo.MSqreader_history add delivery_rate float NOT NULL DEFAULT 0.0
	end 

	if not exists (select * from sys.columns where 
		object_id = object_id('MSqreader_history') and
		name = 'transaction_rate')
	begin
		alter table dbo.MSqreader_history add transaction_rate float NOT NULL DEFAULT 0.0
	end 

	IF NOT EXISTS (SELECT * from sys.objects WHERE name = 'MSrepl_backup_lsns' and type = 'U')
	BEGIN
		/****************************************************************************/
		raiserror('Creating table MSrepl_backup_lsns', 0,1)
		/****************************************************************************/    

		CREATE TABLE dbo.MSrepl_backup_lsns
		(
		publisher_database_id int NOT NULL,
		valid_xact_id varbinary(16) NULL,
		valid_xact_seqno varbinary (16 ) NULL,
		next_xact_id varbinary(16) NULL,
		next_xact_seqno varbinary (16 )  NULL
		)

		exec dbo.sp_MS_marksystemobject 'MSrepl_backup_lsns'

		raiserror('Creating clustered index ucMSrepl_backup_lsns', 0,1)
		CREATE UNIQUE CLUSTERED INDEX ucMSrepl_backup_lsns ON dbo.MSrepl_backup_lsns
			(publisher_database_id)

		if exists (select * from MSpublisher_databases)
		begin
			/****************************************************************************/
			raiserror('Upgrading MSrepl_backup_lsns', 0,1)
			/****************************************************************************/    
			insert into MSrepl_backup_lsns select d.id, 
				NULL, NULL, NULL, NULL from MSpublisher_databases d
			-- No need to set the lsns in the table since the 'sync with backup' option is 
			-- new in 8.0
		end

	END

	--
	-- Table for replication monitor thresholds for publications
	--
	if (object_id('dbo.MSpublicationthresholds') is null)
	begin
		raiserror('Creating table MSpublicationthresholds', 0,1)
		create table dbo.MSpublicationthresholds
		(
			publication_id int not null
			,metric_id int not null
			,value sql_variant null
			,shouldalert bit not null default 0
			,isenabled bit not null default 0
		)
		exec dbo.sp_MS_marksystemobject 'MSpublicationthresholds'
		raiserror('Creating clustered index ucmspublicationthresholds', 0,1)
		create unique clustered index ucmspublicationthresholds 
			on dbo.MSpublicationthresholds (publication_id,  metric_id)
		create nonclustered index nc1mspublicationthresholds 
			on dbo.MSpublicationthresholds (publication_id)
		create nonclustered index nc2mspublicationthresholds 
			on dbo.MSpublicationthresholds (metric_id)
	end

	IF NOT EXISTS (SELECT * from sys.objects WHERE name = 'IHpublishers' and type = 'U')
	BEGIN
		/****************************************************************************/
		raiserror('Creating table IHpublishers', 0,1)
		/****************************************************************************/    

		create table IHpublishers
		(
		publisher_id		smallint			not null,	-- use same ID as dbo.sysservers.srvid
		vendor				sysname				not null,
		publisher_guid		uniqueidentifier	not null,
		flush_request_time	datetime			null,
		version				sysname				null
		-- ,CONSTRAINT pk_IHpublishers PRIMARY KEY (publisher_id)
		)

		exec dbo.sp_MS_marksystemobject 'IHpublishers'
	END

	IF NOT EXISTS (SELECT * from sys.objects WHERE name = 'IHpublishertables' and type = 'U')
	BEGIN
		/****************************************************************************/
		raiserror('Creating table IHpublishertables', 0,1)
		/****************************************************************************/    

		create table IHpublishertables
		(
		 table_id       int         IDENTITY	NOT NULL
		,publisher_id   smallint    NOT NULL 
		,name           sysname     NOT NULL
		,owner          sysname     NOT NULL
		-- ,CONSTRAINT pk_IHpublishertables PRIMARY KEY (table_id, publisher_id)
		-- ,CONSTRAINT fk_IHpublishertables_publisher FOREIGN KEY (publisher_id) REFERENCES IHpublishers (publisher_id)
		-- ,CONSTRAINT uk_IHpublishertables_name UNIQUE NONCLUSTERED (publisher_id, name, owner)
		)

		create unique clustered index idx_IHpublishertables_tableid ON IHpublishertables (table_id)
		create index idx_IHpublishertables_name ON IHpublishertables (name)
		
		exec dbo.sp_MS_marksystemobject 'IHpublishertables'
	END

	IF NOT EXISTS (SELECT * from sys.objects WHERE name = 'IHarticles' and type = 'U')
	BEGIN
		/****************************************************************************/
		raiserror('Creating table IHarticles', 0,1)
		/****************************************************************************/    

		create table IHarticles
		(
			article_id					int             NOT NULL IDENTITY,
			name						sysname         NOT NULL,
			publication_id				smallint        NOT NULL,
			table_id					int             NOT NULL,
			publisher_id				smallint        NOT NULL,
			creation_script				nvarchar(255)   NULL,
			del_cmd						nvarchar(255)   NULL,
			filter						int             NOT NULL,
			filter_clause				nvarchar(max)   NULL,
			ins_cmd						nvarchar(255)   NULL,
			pre_creation_cmd			tinyint         NOT NULL,
			status						tinyint         NOT NULL,
			type						tinyint         NOT NULL,
			upd_cmd						nvarchar(255)   NULL,
			schema_option				binary(8)       NULL,
			dest_owner					sysname         NULL,
			dest_table					sysname         NOT NULL,
			tablespace_name				nvarchar(255)   NULL,
			objid						int             NULL,
			sync_objid					int             NULL,
			description					nvarchar(255)   NULL,
			publisher_status			int             NULL,
			article_view_owner			nvarchar(255)	NULL,
			article_view				nvarchar(255)	NULL,
			ins_scripting_proc			int             NULL,
			del_scripting_proc			int             NULL,
			upd_scripting_proc			int             NULL,
			custom_script				nvarchar(2048)  NULL,
			fire_triggers_on_snapshot	bit             NOT NULL DEFAULT 0,
			instance_id					int             NOT NULL DEFAULT 0,
			use_default_datatypes		bit				NOT NULL DEFAULT 0
			-- ,CONSTRAINT pk_IHarticles PRIMARY KEY (article_id)
			-- ,CONSTRAINT uk_IHarticles_article UNIQUE  (name, publication_id)
			-- ,CONSTRAINT fk_IHarticles_tableid FOREIGN KEY (table_id, publisher_id) REFERENCES IHpublishertables (table_id, publisher_id)
			)

		create unique clustered index idx_IHarticles_articleid ON IHarticles (article_id)
		create index idx_IHarticles_tableid ON IHarticles (table_id)
		create index idx_IHarticles_name ON IHarticles (name)
		
		exec dbo.sp_MS_marksystemobject 'IHarticles'
	END

	IF NOT EXISTS (SELECT * from sys.objects WHERE name = 'IHpublishercolumns' and type = 'U')
	BEGIN
		/****************************************************************************/
		raiserror('Creating table IHpublishercolumns', 0,1)
		/****************************************************************************/    

		create table IHpublishercolumns
		(
		 publishercolumn_id int             IDENTITY
		,table_id           int             not null
		,publisher_id       smallint        not null
		,name               sysname         not null
		,column_ordinal     int             not null
		,type               varchar(255)    not null
		,length             bigint          not null
		,prec               int             null
		,scale              int             null
		,isnullable         bit             not null
		,iscaptured         bit             not null -- Column is begin captured by tracking trigger but might not be in any articles
		-- ,CONSTRAINT pk_IHpublishercolumns PRIMARY KEY (publishercolumn_id)
		-- ,CONSTRAINT fk_IHpublishercolumns_tableid FOREIGN KEY (table_id, publisher_id) REFERENCES IHpublishertables (table_id, publisher_id)
		)

		create index idx_IHpublishercolumns_tableid on IHpublishercolumns (table_id)
		create index idx_IHpublishercolumns_name on IHpublishercolumns (name)
		create index idx_IHpublishercolumns_type on IHpublishercolumns (type)
		create index idx_IHpublishercolumns_pubcolumnid on IHpublishercolumns (publishercolumn_id)
		
		exec dbo.sp_MS_marksystemobject 'IHpublishercolumns'
	END

	IF NOT EXISTS (SELECT * from sys.objects WHERE name = 'IHcolumns' and type = 'U')
	BEGIN
		/****************************************************************************/
		raiserror('Creating table IHcolumns', 0,1)
		/****************************************************************************/    

		create table IHcolumns
		(
		 column_id          int             IDENTITY
		,publishercolumn_id int             not null
		,name               sysname         not null
		,article_id         int             not null
		,column_ordinal     int             not null
		,mapped_type        tinyint         not null
		,mapped_length      bigint          null
		,mapped_prec        int             null
		,mapped_scale       int             null
		,mapped_nullable	bit				null default 1
		-- ,CONSTRAINT pk_IHcolumns PRIMARY KEY (column_id)
		-- ,CONSTRAINT uk_IHcolumns_pubcolid UNIQUE  (publishercolumn_id, article_id)
		-- ,CONSTRAINT uk_IHcolumns_name UNIQUE  (name, article_id)
		-- ,CONSTRAINT fk_IHcolumns_publishrecolumnid FOREIGN KEY(publishercolumn_id) REFERENCES IHpublishercolumns (publishercolumn_id)
		-- ,CONSTRAINT fk_IHcolumns_articleid FOREIGN KEY (article_id) REFERENCES IHarticles (article_id)
		)

		create clustered index idx_IHcolumns_pubcolumnid ON IHcolumns (publishercolumn_id)
		create index idx_IHcolumns_mappedtype ON IHcolumns (mapped_type)
		create index idx_IHcolumns_articleid ON IHcolumns (article_id)
		create index idx_IHcolumns_columnid ON IHcolumns (column_id)
		create index idx_IHcolumns_name ON IHcolumns (name)
		
		exec dbo.sp_MS_marksystemobject 'IHcolumns'
	END

	IF NOT EXISTS (SELECT * from sys.objects WHERE name = 'IHindextypes' and type = 'U')
	BEGIN
		/****************************************************************************/
		raiserror('Creating table IHindextypes', 0,1)
		/****************************************************************************/    

		create table IHindextypes
		(
		 type   NVARCHAR(255)   NOT NULL
		-- ,CONSTRAINT pk_IHindextypes PRIMARY KEY (type)
		)

		insert into IHindextypes (type) values ('UNIQUE');
		insert into IHindextypes (type) values ('NONUNIQUE');
		
		exec dbo.sp_MS_marksystemobject 'IHindextypes'
	END


	IF NOT EXISTS (SELECT * from sys.objects WHERE name = 'IHpublisherindexes' and type = 'U')
	BEGIN
		/****************************************************************************/
		raiserror('Creating table IHpublisherindexes', 0,1)
		/****************************************************************************/    

		create table IHpublisherindexes
		(
		 publisherindex_id  INT IDENTITY    NOT NULL
		,table_id           INT             NOT NULL
		,publisher_id       SMALLINT        NOT NULL
		,name               NVARCHAR(255)   NOT NULL
		,type               NVARCHAR(255)   NOT NULL
		-- ,CONSTRAINT pk_IHindexes PRIMARY KEY (publisherindex_id)
		-- ,CONSTRAINT fk_IHindexes_indextypeid FOREIGN KEY (type) REFERENCES IHindextypes (type)
		-- ,CONSTRAINT fk_IHindexes_tableid FOREIGN KEY (table_id, publisher_id) REFERENCES IHpublishertables (table_id, publisher_id)
		)

		create unique clustered index idx_IHpublisherindexes_pubindexid ON IHpublisherindexes (publisherindex_id)
		create index idx_IHpublisherindexes_tableid ON IHpublisherindexes (table_id)
		create index idx_IHpublisherindexes_name ON IHpublisherindexes (name)
		
		exec dbo.sp_MS_marksystemobject 'IHpublisherindexes'
	END

	IF NOT EXISTS (SELECT * from sys.objects WHERE name = 'IHpublishercolumnindexes' and type = 'U')
	BEGIN
		/****************************************************************************/
		raiserror('Creating table IHpublishercolumnindexes', 0,1)
		/****************************************************************************/    

		create table IHpublishercolumnindexes
		(
			publishercolumn_id	int NOT NULL,
			publisherindex_id	int NOT NULL,
			indid				int NOT NULL
			-- ,CONSTRAINT pk_IHpublishercolumnindexes PRIMARY KEY (publishercolumn_id, publisherindex_id)
			-- ,CONSTRAINT fk_IHpublishercolumnindexes_columnid FOREIGN KEY (publishercolumn_id) REFERENCES IHpublishercolumns (publishercolumn_id)
			-- ,CONSTRAINT fk_IHpublishercolumnindexes_constraintid FOREIGN KEY (publisherindex_id) REFERENCES IHpublisherindexes (publisherindex_id)
		)

		create clustered index idx_IHpublishercolumnindexes_pubcolumnid ON  IHpublishercolumnindexes (publishercolumn_id)
		create index idx_IHpublishercolumnindexes_pubindexid ON  IHpublishercolumnindexes (publisherindex_id)
		
		exec dbo.sp_MS_marksystemobject 'IHpublishercolumnindexes'
	END

	IF NOT EXISTS (SELECT * from sys.objects WHERE name = 'IHpublications' and type = 'U')
	BEGIN
		/****************************************************************************/
		raiserror('Creating table IHpublications', 0,1)
		/****************************************************************************/    

		create table IHpublications
		(
			pubid							int				not null,
			name							sysname			not null,
			repl_freq						tinyint			not null,
			status							tinyint			not null,
			sync_method						tinyint			not null,
			snapshot_jobid					binary(16)		null,
			enabled_for_internet			bit				not null,
			immediate_sync_ready			bit				not null,
			allow_queued_tran				bit				not null default 0,
			allow_sync_tran					bit				not null default 0,
			autogen_sync_procs				bit				not null,
			snapshot_in_defaultfolder		bit				not null,
			alt_snapshot_folder				nvarchar(510)	null,
			pre_snapshot_script				nvarchar(510)	null,
			post_snapshot_script			nvarchar(510)	null,
			compress_snapshot				bit				not null,
			ftp_address						sysname			null,
			ftp_port						int				not null,
			ftp_subdirectory				nvarchar(510)	null,
			ftp_login						nvarchar(256)	null,
			ftp_password					nvarchar(1048)	null,
			allow_dts						bit				not null default 0,
			allow_anonymous					bit				not null default 0,
			centralized_conflicts			bit				NULL, -- 0 False, 1 True
			conflict_retention				int				NULL, -- 60
			conflict_policy					int				NULL, -- 1 = PubWins, 2 = SubWins, 3 = Reinit
			queue_type						int				NULL, -- 1 = MSMQ, 2 = SQL       
			ad_guidname						sysname			null,
			backward_comp_level				int				not NULL default 10, -- default is sphinx
			description						nvarchar(255)	NULL,
			independent_agent				bit				NOT NULL default 0,
			immediate_sync					bit				NOT NULL default 0,
			allow_push						bit				NOT NULL default 1,
			allow_pull						bit				NOT NULL default 0,
			retention						int				NULL,
			allow_subscription_copy			bit				default 0 not null,
			allow_initialize_from_backup	bit				not null default 0,
			min_autonosync_lsn				binary			null,
			replicate_ddl					int	null			default 1,
			options							int		null		default 0,
			originator_id					int 	null
		)

		create index idx_IHpublications_replfreq ON IHpublications (repl_freq)
		create index idx_IHpublications_name ON IHpublications (name)
		create index idx_IHpublications_pubid ON IHpublications (pubid)
	 
		exec dbo.sp_MS_marksystemobject 'IHpublications'
	END



	IF NOT EXISTS (SELECT * from sys.objects WHERE name = 'IHextendedArticleView' and type = 'V')
	BEGIN
		/****************************************************************************/
		raiserror('Creating table IHextendedArticleView', 0,1)
		/****************************************************************************/    

		SELECT @Cmd =
		' create view IHextendedArticleView as '
		+ ' SELECT msa.publisher_id, '
		+ '      msa.publication_id, '
		+ '      msa.article, '
		+ '      msa.destination_object, '
		+ '      msa.source_owner, '
		+ '      msa.source_object, '
		+ '      msa.description, '
		+ '      iha.creation_script, '
		+ '      iha.del_cmd, '
		+ '      iha.filter, '
		+ '      iha.filter_clause, '
		+ '      iha.ins_cmd, '
		+ '      iha.pre_creation_cmd, '
		+ '      iha.status, '
		+ '      iha.type, '
		+ '      iha.upd_cmd, '
		+ '      iha.schema_option, '
		+ '      iha.dest_owner '
		+ ' FROM   MSarticles msa '
		+ ' JOIN   IHarticles iha   ON  msa.article_id     = iha.article_id '

		EXEC (@Cmd)
		
		exec dbo.sp_MS_marksystemobject 'IHextendedArticleView'
	END


	IF NOT EXISTS (SELECT * from sys.objects WHERE name = 'IHconstrainttypes' and type = 'U')
	BEGIN
		/****************************************************************************/
		raiserror('Creating table IHconstrainttypes', 0,1)
		/****************************************************************************/    

		create table IHconstrainttypes
		(
			type NVARCHAR(255) NOT NULL 
			-- ,CONSTRAINT pk_IHcontrainttypes PRIMARY KEY (type)
		)

		insert into IHconstrainttypes (type) values ('PRIMARYKEY')
		
		exec dbo.sp_MS_marksystemobject 'IHconstrainttypes'
	END



	IF NOT EXISTS (SELECT * from sys.objects WHERE name = 'IHpublisherconstraints' and type = 'U')
	BEGIN
		/****************************************************************************/
		raiserror('Creating table IHpublisherconstraints', 0,1)
		/****************************************************************************/    

		create table IHpublisherconstraints
		(
			 publisherconstraint_id int             IDENTITY NOT NULL
			,table_id       int             NOT NULL -- denormalized
			,publisher_id   smallint        NOT NULL -- denormalized
			,name           sysname         NOT NULL
			,type           NVARCHAR(255)   NOT NULL 
			-- ,CONSTRAINT pk_IHpublisherconstraints PRIMARY KEY (publisherconstraint_id)
			-- ,CONSTRAINT uk_IHpublisherconstriaints_name UNIQUE (name, table_id)
			-- ,CONSTRAINT fk_IHpublisherconstraints_constraint FOREIGN KEY (type) REFERENCES IHconstrainttypes (type)
			-- ,CONSTRAINT fk_IHpublisherconstraints_tableid FOREIGN KEY (table_id, publisher_id) REFERENCES IHpublishertables (table_id, publisher_id)
		)
		create unique clustered index idx_IHpublisherconstraints_pubconstraintid ON IHpublisherconstraints (publisherconstraint_id)
		create index idx_IHpublisherconstraints_tableid ON IHpublisherconstraints (table_id)
		create index idx_IHpublisherconstraints_name ON IHpublisherconstraints (name)
		
		exec dbo.sp_MS_marksystemobject 'IHpublisherconstraints'
	END

	IF NOT EXISTS (SELECT * from sys.objects WHERE name = 'IHpublishercolumnconstraints' and type = 'U')
	BEGIN
		/****************************************************************************/
		raiserror('Creating table IHpublishercolumnconstraints', 0,1)
		/****************************************************************************/    

		create table IHpublishercolumnconstraints
		(
			publishercolumn_id		int NOT NULL,
			publisherconstraint_id	int NOT NULL,
			indid					int NOT NULL
		)

		create clustered index idx_IHpublishercolumnconstraints_pubcolumnid ON IHpublishercolumnconstraints (publishercolumn_id)
		create index idx_IHpublishercolumnconstraints_pubconstraintid ON IHpublishercolumnconstraints (publisherconstraint_id)
		
		exec dbo.sp_MS_marksystemobject 'IHpublishercolumnconstraints'
	END

	IF NOT EXISTS (SELECT * from sys.objects WHERE name = 'IHsubscriptions' and type = 'U')
	BEGIN
		/****************************************************************************/
		raiserror('Creating table IHsubscriptions', 0,1)
		/****************************************************************************/    

        create table IHsubscriptions
        (
            article_id			int         NOT NULL,
            srvid				smallint    NOT NULL,
            dest_db				sysname     NOT NULL,
            login_name			sysname     NOT NULL,
            distribution_jobid	binary(16)	NOT NULL,
            timestamp			timestamp	NULL,
            queued_reinit		bit			NOT NULL DEFAULT 0,
            status				tinyint		NOT NULL DEFAULT 0,
            sync_type			tinyint		NOT NULL DEFAULT 0,
            subscription_type	int			NOT NULL DEFAULT 0,
            update_mode			tinyint		NOT NULL DEFAULT 0, -- 0 (read only),
            loopback_detection	bit			NOT NULL DEFAULT 0,
            nosync_type			tinyint		NOT NULL DEFAULT 0
            ,srvname	sysname NOT NULL DEFAULT ''
        )
        create unique clustered index [idx_IHsubscriptions_article_id] ON [dbo].[IHsubscriptions] 
        (
            [article_id] ASC,
            [srvid] ASC,
            [dest_db] ASC
        )WITH (SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF ) ON [PRIMARY]
        
        exec dbo.sp_MS_marksystemobject 'IHsubscriptions'
    END
	ELSE
	BEGIN
		IF NOT EXISTS (select * from sys.columns
			where name = 'srvname'
			and object_id=object_id('IHsubscriptions'))
		BEGIN
			ALTER TABLE IHsubscriptions ADD srvname sysname NOT NULL DEFAULT N'' with values
			   exec('update dbo.IHsubscriptions
			         set srvname = upper(ss.srvname collate database_default)
			         from dbo.IHsubscriptions sub 
	            	         join MSreplservers ss on ss.srvid = sub.srvid')
		END
		ELSE
		BEGIN
			exec ('update dbo.IHsubscriptions
			set srvname = upper(ss.srvname collate database_default)
			from dbo.IHsubscriptions sub 
			join MSreplservers ss on ss.srvid = sub.srvid
			where sub.srvname = N'''' ')
		END
 	END

	IF not exists (select * from sys.objects where name = 'sysschemaarticles' and type = 'U')
		BEGIN
		/****************************************************************************/
		raiserror('Creating table sysschemaarticles', 0,1)
		/****************************************************************************/ 
	 
			create table sysschemaarticles
			(
				artid               int                 NOT NULL,
				creation_script     nvarchar(255)       NULL,
				description         nvarchar(255)       NULL,
				dest_object         sysname             NOT NULL,
				name                sysname             NOT NULL,
				objid               int                 NOT NULL,
				pubid               int                 NOT NULL,
				pre_creation_cmd    tinyint             NOT NULL,
				status              int                 NOT NULL,
				type                tinyint             NOT NULL,
				schema_option       binary(8)           NULL,
				dest_owner          sysname             NULL
			)

			CREATE UNIQUE CLUSTERED INDEX [c1sysschemaarticles] ON [dbo].[sysschemaarticles] 
			(
				[artid] ASC,
				[pubid] ASC
			)WITH (SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF) ON [PRIMARY]
			
			exec dbo.sp_MS_marksystemobject 'sysschemaarticles'
		END

	------------------------------------------------------------------------------
	-- Create the cache table for PeerToPeer replication
	------------------------------------------------------------------------------
	IF NOT EXISTS (SELECT * from sys.objects WHERE name = 'MScached_peer_lsns' and type = 'U')
	BEGIN
		/****************************************************************************/
		raiserror('Creating table MScached_peer_lsns', 0,1)
		/****************************************************************************/
		CREATE TABLE dbo.MScached_peer_lsns 
		(
			agent_id					int null,
			originator					sysname,			
			originator_db				sysname,
			originator_publication_id	int null,
			originator_db_version		int null,
			originator_lsn				varbinary(16) null
		)

		CREATE UNIQUE CLUSTERED INDEX ucMScached_peer_lsns
			ON dbo.MScached_peer_lsns (agent_id, originator_db_version, originator_lsn, originator_db, originator, originator_publication_id)
			
		exec dbo.sp_MS_marksystemobject 'dbo.MScached_peer_lsns'
	END

	IF NOT EXISTS (SELECT * from sys.objects WHERE name = 'IHextendedSubscriptionView' and type = 'V')
	BEGIN
		/****************************************************************************/
		raiserror('Creating view IHextendedSubscriptionView', 0,1)
		/****************************************************************************/    

		SELECT @Cmd =
		  ' create view IHextendedSubscriptionView as '
		+ ' SELECT '
		+ ' ihs.article_id, '
		+ ' ihs.dest_db, '
		+ ' ihs.srvid, '
		+ ' ihs.login_name, '
		+ ' ihs.distribution_jobid, '
		+ ' mss.publisher_database_id, '
		+ ' mss.subscription_type, '
		+ ' mss.sync_type, '
		+ ' mss.status, '
		+ ' mss.snapshot_seqno_flag, '
		+ ' mss.independent_agent, '
		+ ' mss.subscription_time, '
		+ ' mss.loopback_detection, '
		+ ' mss.agent_id, '
		+ ' mss.update_mode, '
		+ ' mss.publisher_seqno, '
		+ ' mss.ss_cplt_seqno  '    
		+ ' FROM IHsubscriptions ihs '
		+ ' JOIN MSsubscriptions mss ON ihs.article_id = mss.article_id '
		+ '                         and ihs.srvid = mss.subscriber_id '
		+ '                         and ihs.dest_db = mss.subscriber_db '

		EXEC (@Cmd)
		
		exec dbo.sp_MS_marksystemobject 'IHextendedSubscriptionView'
	END

	DECLARE @Cmd1 varchar(2000)
	IF NOT EXISTS (SELECT * from sys.objects WHERE name = 'syssubscriptions' and type = 'V')
		or 
		(EXISTS (SELECT * from sys.objects WHERE name = 'syssubscriptions' and type = 'V')
		and NOT EXISTS (select * from sys.columns where name = 'srvname' and object_id=object_id('syssubscriptions')))
	BEGIN
		IF NOT EXISTS (SELECT * from sys.objects WHERE name = 'syssubscriptions' and type = 'V')
		begin 
			/****************************************************************************/
			raiserror('Creating view syssubscriptions', 0,1)
			/****************************************************************************/    

			SELECT @Cmd1 = ' create '
		end 
		else if NOT EXISTS (select * from sys.columns where name = 'srvname' and object_id=object_id('syssubscriptions'))
		begin 
			/****************************************************************************/
			raiserror('Altering view syssubscriptions to include srvname column', 0,1)
			/****************************************************************************/    

			SELECT @Cmd1 = ' alter '
		end
		select @Cmd1 =  @Cmd1 + 'view dbo.syssubscriptions (artid, srvid, dest_db, status, sync_type, login_name, subscription_type, '
		+ ' distribution_jobid, timestamp, update_mode, loopback_detection, queued_reinit, nosync_type, srvname) AS '
		+ ' SELECT ihsub.article_id, '
		+ '     ihsub.srvid, '
		+ '     ihsub.dest_db, '
		+ '     ihsub.status, '
		+ '     ihsub.sync_type, '
		+ '     ihsub.login_name, '
		+ '     ihsub.subscription_type, '
		+ '     ihsub.distribution_jobid, '
		+ '     ihsub.timestamp, '
		+ '     ihsub.update_mode, '
		+ '     ihsub.loopback_detection, '
		+ '     ihsub.queued_reinit, '
		+ '     ihsub.nosync_type '
		+ '     ,ihsub.srvname '
		+ ' FROM   dbo.IHsubscriptions ihsub '

		EXEC (@Cmd1)
		
		exec dbo.sp_MS_marksystemobject 'syssubscriptions'
	END

	IF NOT EXISTS (SELECT * from sys.objects WHERE name = 'syspublications' and type = 'V')
	BEGIN
		/****************************************************************************/
		raiserror('Creating view syspublications', 0,1)
		/****************************************************************************/    

		SELECT @Cmd1 =
		' create view syspublications (description, name, pubid, repl_freq, status, sync_method, snapshot_jobid, '
		+ ' independent_agent, immediate_sync, enabled_for_internet, allow_push, allow_pull, allow_anonymous, immediate_sync_ready, '
		+ ' allow_sync_tran, autogen_sync_procs, retention, allow_queued_tran, snapshot_in_defaultfolder, alt_snapshot_folder, '
		+ ' pre_snapshot_script, post_snapshot_script, compress_snapshot, ftp_address, ftp_port, ftp_subdirectory, ftp_login, '
		+ ' ftp_password, allow_dts, allow_subscription_copy, centralized_conflicts, conflict_retention, conflict_policy, queue_type, '
		+ ' ad_guidname, backward_comp_level, allow_initialize_from_backup, min_autonosync_lsn, replicate_ddl, options, originator_id) AS '
		+ ' SELECT ihpub.description, '
		+ '     ihpub.name, '
		+ '     ihpub.pubid, '
		+ '     ihpub.repl_freq, '
		+ '     ihpub.status, '
		+ '     ihpub.sync_method, '
		+ '     ihpub.snapshot_jobid, '
		+ '     ihpub.independent_agent, '
		+ '     ihpub.immediate_sync, '
		+ '     ihpub.enabled_for_internet, '
		+ '     ihpub.allow_push, '
		+ '     ihpub.allow_pull, '
		+ '     ihpub.allow_anonymous, '
		+ '     ihpub.immediate_sync_ready, '
		+ '     ihpub.allow_sync_tran, '
		+ '     ihpub.autogen_sync_procs, '
		+ '     ihpub.retention, '
		+ '     ihpub.allow_queued_tran, '
		+ '     ihpub.snapshot_in_defaultfolder, '
		+ '     ihpub.alt_snapshot_folder, '
		+ '     ihpub.pre_snapshot_script, '
		+ '     ihpub.post_snapshot_script, '
		+ '     ihpub.compress_snapshot, '
		+ '     ihpub.ftp_address, '
		+ '     ihpub.ftp_port, '
		+ '     ihpub.ftp_subdirectory, '
		+ '     ihpub.ftp_login, '
		+ '     ihpub.ftp_password, '
		+ '     ihpub.allow_dts, '
		+ '     ihpub.allow_subscription_copy, '
		+ '     ihpub.centralized_conflicts, '
		+ '     ihpub.conflict_retention, '
		+ '     ihpub.conflict_policy, '
		+ '     ihpub.queue_type,'
		+ '     ihpub.ad_guidname, '
		+ '     ihpub.backward_comp_level, '
		+ '     ihpub.allow_initialize_from_backup, '
		+ '     ihpub.min_autonosync_lsn, '
		+ '     ihpub.replicate_ddl,'
		+ '     ihpub.options,'
	 + '     ihpub.originator_id'
		+ ' FROM   IHpublications ihpub '
		
		EXEC (@Cmd1)
		
		exec dbo.sp_MS_marksystemobject 'syspublications'
	END

	IF NOT EXISTS (SELECT * from sys.objects WHERE name = 'sysarticles' and type = 'V')
	BEGIN
		/****************************************************************************/
		raiserror('Creating view sysarticles', 0,1)
		/****************************************************************************/    

		SELECT @Cmd1 =
		' create view sysarticles (artid, creation_script, del_cmd, description, dest_table, filter, '
		+ 'filter_clause, ins_cmd, name, objid, pubid, pre_creation_cmd, status, sync_objid, type, upd_cmd, schema_option, dest_owner, '
		+ 'ins_scripting_proc, del_scripting_proc, upd_scripting_proc, custom_script, fire_triggers_on_snapshot) AS '
		+ ' SELECT ihart.article_id, ihart.creation_script, ihart.del_cmd, ihart.description, '
		+ 'ihart.dest_table, ihart.filter, ihart.filter_clause, ihart.ins_cmd, '
		+ 'ihart.name, ihart.objid, ihart.publication_id, ihart.pre_creation_cmd, '
		+ 'ihart.status, ihart.sync_objid, ihart.type, ihart.upd_cmd, ihart.schema_option, '
		+ 'ihart.dest_owner, ihart.ins_scripting_proc, ihart.del_scripting_proc, ihart.upd_scripting_proc, ihart.custom_script, ihart.fire_triggers_on_snapshot '
		+ 'FROM IHarticles ihart '
		
		EXEC (@Cmd1)
		
		exec dbo.sp_MS_marksystemobject 'sysarticles'
	END

	IF NOT EXISTS (SELECT * from sys.objects WHERE name = 'sysarticlecolumns' and type = 'V')
	BEGIN
		/****************************************************************************/
		raiserror('Creating view sysarticlecolumns', 0,1)
		/****************************************************************************/    

		SELECT @Cmd1 = 'create view sysarticlecolumns (artid, colid, is_udt, is_xml, is_max ) AS SELECT article_id, publishercolumn_id, 0, 0, 0 FROM IHcolumns'
		EXEC (@Cmd1)
		
		exec dbo.sp_MS_marksystemobject 'sysarticlecolumns'
	END

	-- NOTE:
	-- IHsyscolumns is a view of PUBLISHED columns in dbo.syscolumns format.  It is NOT the
	-- full list of base columns like it is in normal SQL Server dbo.syscolumns
	IF NOT EXISTS (SELECT * from sys.objects WHERE name = 'IHsyscolumns' and type = 'V')
	BEGIN
		/****************************************************************************/
		raiserror('Creating view IHsyscolumns', 0,1)
		/****************************************************************************/    

		SELECT @Cmd1 =
		' create view IHsyscolumns (name, id, xtype, typestat, xusertype, length, '
		+ ' xprec, xscale, colid, xoffset, bitpos, reserved, colstat, cdefault, domain, number, colorder, autoval, '
		+ ' offset, collationid, language, status, type, usertype, printfmt, prec, scale, iscomputed, isoutparam, isnullable, '
		+ ' collation, tdscollation ) AS '
		+ ' SELECT ihcol.name, '
		+ '     ihcol.article_id, '
		+ '     ihcol.mapped_type, '
		+ '     NULL, '
		+ '     ihcol.mapped_type, '
		+ '     ihcol.mapped_length, '
		+ '     ihcol.mapped_prec, '
		+ '     ihcol.mapped_scale, '
		+ '     ihcol.column_id, '
		+ '     NULL, '
		+ '     NULL, '
		+ '     NULL, '
		+ '     NULL, '
		+ '     NULL, '
		+ '     NULL, '
		+ '     NULL, '
		+ '     ihcol.column_ordinal, '
		+ '     NULL, '
		+ '     NULL, '
		+ '     NULL, '
		+ '     NULL, '
		+ '     NULL, '
		+ '     0, '
		+ '     ihcol.mapped_type, '
		+ '     NULL, '
		+ '     ihcol.mapped_prec, '
		+ '     ihcol.mapped_scale, '
		+ '     0, '
		+ '     0, '
		+ '     0, '
		+ '     NULL, '
		+ '     NULL '
		+ ' FROM   IHcolumns ihcol '
		
		EXEC (@Cmd1)
		
		exec dbo.sp_MS_marksystemobject 'IHsyscolumns'
	END

    IF NOT EXISTS (SELECT * from sys.objects WHERE name = 'MSrepl_agent_jobs' and type = 'U')
    BEGIN
        /****************************************************************************/
        raiserror('Creating table MSrepl_agent_jobs', 0,1)
        /****************************************************************************/

        create table dbo.MSrepl_agent_jobs
        (
        job_id                      uniqueidentifier    NOT NULL,
        name                        sysname             NOT NULL,
        enabled                     tinyint             NOT NULL,
        description                 nvarchar(512)       NULL,
        category_name               sysname             NOT NULL,
        owner_login_name            nvarchar(60)        NOT NULL,
        notify_level_eventLog       int                 NOT NULL,
        notify_level_email          int                 NOT NULL,
        notify_email_operator_name  sysname             NULL,
        job_step_uid                uniqueidentifier    NOT NULL,
        subsystem                   nvarchar(40)        NOT NULL,
        command                     nvarchar(3200)      NOT NULL,
        cmdexec_success_code        int                 NOT NULL,
        server                      sysname             NULL,
        database_user_name          sysname             NULL,
        retry_attempts              int                 NOT NULL,
        retry_interval              int                 NOT NULL,
        os_run_priority             int                 NOT NULL,
        job_login                   nvarchar(257)       NULL,
        freq_type                   int                 NOT NULL,
        freq_interval               int                 NOT NULL,
        freq_subday_type            int                 NOT NULL,
        freq_subday_interval        int                 NOT NULL,
        freq_relative_interval      int                 NOT NULL,
        freq_recurrence_factor      int                 NOT NULL,
        active_start_date           int                 NULL,
        active_end_date             int                 NULL,
        active_start_time           int                 NULL,
        active_end_time             int                 NULL,
        agent_id                    int                 NULL
        )

        exec dbo.sp_MS_marksystemobject 'MSrepl_agent_jobs'

        CREATE UNIQUE CLUSTERED INDEX ucMSrepl_agent_jobs ON dbo.MSrepl_agent_jobs
            (job_id)
    END

    IF not exists (select * from sys.objects where name = 'sysextendedarticlesview')
    BEGIN
        exec ('create view dbo.sysextendedarticlesview
               as
               select * from sysarticles
               union all
               select artid, creation_script, NULL, description,
               dest_object, NULL, NULL, NULL, name, objid, pubid, 
               pre_creation_cmd, status, NULL, type, NULL, 
               schema_option, dest_owner, NULL, NULL, NULL, NULL, 0 from sysschemaarticles
               go')

		exec dbo.sp_MS_marksystemobject 'sysextendedarticlesview'

   END

	if object_id('MStracer_tokens') is null
	begin
		create table MStracer_tokens
		(
			tracer_id			int identity(-2147483648, 1) primary key clustered,
			publication_id		int not null,
			publisher_commit	datetime not null,
			distributor_commit	datetime null
		)
		if @@error <> 0
		begin
			return 1
		end

		exec dbo.sp_MS_marksystemobject 'MStracer_tokens'
	end

	if object_id('MStracer_history') is null
	begin
		create table MStracer_history
		(
			parent_tracer_id	int not null,
			agent_id			int not NULL,
			subscriber_commit	datetime null
			
			constraint pkuc_tracer_subs primary key nonclustered
			(
				parent_tracer_id,
				agent_id
			)

			constraint fk_MStracer_tokens_parent_tracer_id foreign key 
			(
				parent_tracer_id
			) references MStracer_tokens
			(
				tracer_id
			)
		)
		if @@error <> 0
		begin
			return 1
		end
		
		exec dbo.sp_MS_marksystemobject 'MStracer_history'
	end

	   IF NOT EXISTS (SELECT * from sys.objects WHERE name = 'MSmerge_articleresolver' and type = 'U')
   BEGIN
	   create table dbo.MSmerge_articleresolver
	   (
			article_resolver        nvarchar(255)   primary key not null ,
			resolver_clsid          nvarchar(50)    not null, 
			is_dotnet_assembly      bit null default 0, 
			dotnet_assembly_name    nvarchar(255)   null, 
			dotnet_class_name       nvarchar(255)   null
	   )

	   if @@error <> 0
		   return 1
	   exec dbo.sp_MS_marksystemobject 'MSmerge_articleresolver'

   END  

	if object_id('dbo.MSreplication_monitordata') is null
	begin
		create table dbo.MSreplication_monitordata
		(
			-- internal use
			lastrefresh datetime null
			,computetime int null -- in seconds
			,publication_id int null
			-- static
			,publisher sysname
			,publisher_srvid int null
			,publisher_db sysname 
			,publication sysname 
			,publication_type int null
			,agent_type int null
			,agent_id int null
			,agent_name sysname
			,job_id uniqueidentifier null
			-- dynamic
			,status int null
			,isagentrunningnow bit null
			,warning int null				-- latest session's warning
			,last_distsync datetime	null	-- last sync time
			,agentstoptime datetime null	-- agent stop time
			,distdb sysname null
			,retention int null
			,time_stamp datetime null
			-- tran specific  
			,worst_latency int null
			,best_latency int null
			,avg_latency int null
			,cur_latency int null 			
			-- <<merge specific>>
			-- this is per subscription, depending on latest session type (fast/slow)
			-- there is a subset of all sessions for this subscription with this type
			-- get the value by session_speed/average
			-- the following 3 are statistics of the above set, unit is percentage        
			,worst_runspeedPerf int null
			,best_runspeedPerf int null       
			,average_runspeedPerf int null
			-- this is mergerunspeed/average above
			,mergePerformance int null
			-- latest session's running duration
			,mergelatestsessionrunduration int null
			-- latest session's row/second raw number
			,mergelatestsessionrunspeed float null
			-- lastest session's running type (LAN or DUN)
			,mergelatestsessionconnectiontype int null
			,retention_period_unit tinyint null
			/*
			,worst_runduration int
			,best_runduration int        
			,average_runduration int
			,cur_runduration int
			,mergeexpirationthreshold int
			,mergerundurationthreshold int
			,mergestoppedcontinuousagentthreshold int
			,mergerunspeedthreshold int
			,mergerunspeed float	 
			*/	 
		)
		if (@@error != 0)
			return 1
		exec dbo.sp_MS_marksystemobject 'MSreplication_monitordata'
		--
		-- build indices
		--
 
		create nonclustered index nc2MSreplication_monitordata 
			on MSreplication_monitordata(publication, publisher_db) 
		if (@@error != 0)
			return 1
			
		create nonclustered index nc6MSreplication_monitordata 
			on MSreplication_monitordata(lastrefresh) 
		if (@@error != 0)
			return 1

		--
		-- grant control access to replmonitor role for refresh computation
		--
		grant control on dbo.MSreplication_monitordata to replmonitor
	end

	IF NOT EXISTS (SELECT * from sys.objects WHERE name = 'MSnosyncsubsetup' and type = 'U')
	BEGIN
		/****************************************************************************/
		raiserror('Creating table MSnosyncsubsetup', 0,1)
		/****************************************************************************/
		-- The parameterName corresponds to each parameter name
		-- of stored proc sp_MSsetupnosyncsubwithlsnatdist.
		create table dbo.MSnosyncsubsetup
		(
			 publisher_database_id int,
			 publication_id int,
			 artid int,
			 next_valid_lsn varbinary(10),
			 parameterName sysname,
			 parameterValue nvarchar(max),
			 primary key (publisher_database_id,
								 publication_id,
								 artid,
								 next_valid_lsn,
								 parameterName)
		)
		if @@error <> 0
			return 1
		exec dbo.sp_MS_marksystemobject 'MSnosyncsubsetup'
	END

end
GO
GRANT EXECUTE ON [sys].[sp_MScreate_dist_tables] TO [public] AS [dbo]
GO
