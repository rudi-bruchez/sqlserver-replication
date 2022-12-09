SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSdbuseraccess]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSdbuseraccess] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSdbuseraccess]
	@mode [nvarchar](10),
	@qual [nvarchar](128)
WITH EXECUTE AS CALLER
AS
set deadlock_priority low
   
   create table #TmpDbUserProfile (
      dbid        int NOT NULL PRIMARY KEY,
      accessperms int NOT NULL
      )

   create table #TmpOut (
      name        nvarchar(132) NOT NULL,
      version     smallint,
      crdate      datetime,
      owner       nvarchar(132),
      dbid        smallint NOT NULL,
      status      int,
      category    int,
      status2     int,
      fulltext    int,
      )

   set nocount on

   declare @accessbit int
	if (lower(@mode) like N'perm%') begin
      /* verify */
      declare @id int, @stat int, @inval int
      select @id = dbid, @stat = status from master.dbo.sysdatabases where name = @qual
      if (@id is null) begin
         RAISERROR (15001, -1, -1, @qual)
         return 1
      end

      /* Can we access this db? */
      declare @single int
      select @single = (CASE WHEN DATABASEPROPERTYEX(@qual, N'UserAccess') = N'SINGLE_USER' THEN 1 ELSE 0 END)
/*      if ((@single <> 0) or ((@stat & SQLDMODBStat_Inaccessible) <> 0)) begin  */
      if ((@single <> 0) or
         (DATABASEPROPERTYEX(@qual, 'Status') = 'SUSPECT') or
         (DATABASEPROPERTYEX(@qual, 'Status') = 'OFFLINE') or
         (DATABASEPROPERTYEX(@qual, 'Status') = 'RESTORING') or
         (DATABASEPROPERTYEX(@qual, 'Status') = 'RECOVERING'))
      begin
         select @inval = 0x80000000
         select @inval
         return 0
      end
      select @accessbit = has_dbaccess(@qual)
      if ( @accessbit <> 1) begin
         select @inval = 0x40000000
         select @inval
         return 0
      end

      /** OK, we can access this db, need to go to the specified database to get priv bit **/
      declare @dbTempname nvarchar(258)
      declare @tempindex int
      SELECT @dbTempname = REPLACE(@qual, N']', N']]')
      exec (N'[' + @dbTempname + N']' + N'..sp_MSdbuserpriv ')
      return 0
   end

   /* If 'db', we want to know if what kind of access we have to the specified databases */
   /* If we are not in master, then we are selecting single database, we want to correct role bit to save round trip */
   if (lower(@mode) like N'db%') begin
      /* Make sure we're either in master or only doing it to current db. */
      declare @dbrole int
      select @dbrole = 0x0000

      if (db_id() <> 1)
         select @qual = db_name()

      /* If dbname contains ', double it for the cursor, since cursor statement is inside of '' */
      declare @qual2 nvarchar(517)
      SELECT @qual2 = REPLACE(@qual, N'''', N'''''')

      /* Preprocessor won't replace within quotes so have to use str(). */
      declare @invalidlogin nvarchar(12)
      select @invalidlogin = ltrim(str(convert(int, 0x40000000), 11))
      declare @inaccessible nvarchar(12)
      select @inaccessible = ltrim(str(convert(int, 0x80000000), 11))

      /* We can't 'use' a database with a version below the minimum. */
      /* SQL6.0 minimum is 406; SQL65 requires 408.  SQL70 database version is 408 now, it might change later */
      declare @mindbver smallint
      if (@@microsoftversion >= 0x07000000)
         select @mindbver = 408
      else
         select @mindbver = 406

      /* Select all matching databases -- we want an entry even for inaccessible ones. */
      declare @dbid smallint, @dbidstr nvarchar(12), @dbstat int, @dbname nvarchar(258), @dbver smallint
      declare @dbbits int, @dbbitstr nvarchar(12)

      /* !!! work around here, if name contains '[', LIKE operator can't find it, since LIKE operator it treating '[' as a wild char */
      /* !!! but @qual2 might be '%', then = operator does not work */
      declare @temp int
      select @tempindex = charindex(N'[', @qual2)
      if (@tempindex <> 0)
         exec(N'declare hCdbs cursor global for select name, dbid, status, version from master.dbo.sysdatabases where name = N''' + @qual2 + N'''')
      else
         exec(N'declare hCdbs cursor global for select name, dbid, status, version from master.dbo.sysdatabases where name like N''' + @qual2 + N'''')

      open hCdbs

      /* Loop for each database, and if it's accessible, recursively call ourselves to add it. */
      fetch hCdbs into @dbname, @dbid, @dbstat, @dbver
      while (@@fetch_status >= 0) begin
         /* Preprocessor won't replace within quotes so have to use str(). */
         select @dbidstr = ltrim(str(convert(int, @dbid)))

         /* If it's a single user db and there's an entry for it in sysprocesses who isn't us, we can't use it. */
         declare @single_lockedout int
         select @single_lockedout = (CASE WHEN DATABASEPROPERTYEX(@dbname, N'UserAccess') = N'SINGLE_USER' THEN 1 ELSE 0 END)
         if (@single_lockedout <> 0)
            select @single_lockedout = 0 where not exists
               (select * from master.dbo.sysprocesses p where dbid = @dbid and p.spid <> @@spid)

         /* First see if the db is accessible (not in load, recovery, offline, single-use with another user besides us, etc.) */
/*         if ((@single_lockedout <> 0) or ((@dbstat & SQLDMODBStat_Inaccessible) <> 0) or (@dbver < @mindbver)) begin   */
         if ((@single_lockedout <> 0) or
            (@dbver < @mindbver) or
            (DATABASEPROPERTYEX(@dbname, 'Status') = 'SUSPECT') or
            (DATABASEPROPERTYEX(@dbname, 'Status') = 'OFFLINE') or
            (DATABASEPROPERTYEX(@dbname, 'Status') = 'RESTORING') or
            (DATABASEPROPERTYEX(@dbname, 'Status') = 'RECOVERING'))
            begin
            /* Inaccessible, but we can set dbo if we're sa or suser_id() is db owner sid. */
            exec (N'insert #TmpDbUserProfile values (' + @dbidstr + N', ' + @inaccessible + N')')
            end
         else begin
            /* Find out whether the current user has access to the database */
            select @accessbit = has_dbaccess(@dbname)
            if ( @accessbit <> 1) begin
               exec (N'insert #TmpDbUserProfile values (' + @dbidstr + N', ' + @invalidlogin + N')')
               end
            else begin
               /* Yes, current user does have access to this database, we are not trying to get priv at this point */
               select @dbbits = 0x03ff
               select @dbbitstr = ltrim(convert(nvarchar(12), @dbbits))
               exec (N'insert #TmpDbUserProfile values (' + @dbidstr + N', ' + @dbbitstr + N')')
               end
            end

         fetch hCdbs into @dbname, @dbid, @dbstat, @dbver
      end /* while FETCH_SUCCESS */
      close hCdbs
      deallocate hCdbs

      /* Select sysdatabases info into temp table first to avoid deadlock in restore process */
      if (@tempindex <> 0)
         insert #TmpOut
         select o.name, o.version, o.crdate, suser_sname(o.sid), o.dbid, o.status, o.category, o.status2, CONVERT(INT, DatabasePropertyEx(o.name, N'isfulltextenabled'))
            from master.dbo.sysdatabases o where o.name = @qual
      else
         insert #TmpOut
         select o.name, o.version, o.crdate, suser_sname(o.sid), o.dbid, o.status, o.category, o.status2, CONVERT(INT, DatabasePropertyEx(o.name, N'isfulltextenabled'))
            from master.dbo.sysdatabases o where o.name like @qual

      /* 1. If on all databases, then dbrole is dummy, need to get it later */
      /* 2. Do not double the ' character(s) in database name */
      /* 3. To speed up connection, accessperms column only indicate whether the login user can access the db, it does not contain */
      /*    permission info, we will retrieve the permission info through sp_MSdbuserpriv when necessary */
      /* !!! work around here, if name contains '[', LIKE operator can't find it, since LIKE operator it treating '[' as a wild char */
      /* !!! but @qual2 might be '%', then = operator does not work */
      if (@tempindex <> 0)
         select o.name, o.version, o.crdate, o.owner, o.dbid, lSize = 0, NonDbo = 0, Status = o.status, spaceavail = 0,
            LogOnSepDev = 1, o.category, t.accessperms, @dbrole, o.fulltext, o.status2,
            collation = convert(sysname, databasepropertyex(o.name, N'collation'))
            from #TmpOut o left outer join #TmpDbUserProfile t on t.dbid = o.dbid where o.name = @qual order by o.name
      else
         select o.name, o.version, o.crdate, o.owner, o.dbid, lSize = 0, NonDbo = 0, Status = o.status, spaceavail = 0,
            LogOnSepDev = 1, o.category, t.accessperms, @dbrole, o.fulltext, o.status2,
            collation = convert(sysname, databasepropertyex(o.name, N'collation'))
            from #TmpOut o left outer join #TmpDbUserProfile t on t.dbid = o.dbid where o.name like @qual order by o.name

      DROP TABLE #TmpDbUserProfile
      DROP TABLE #TmpOut
      return 0
   end
GO
GRANT EXECUTE ON [sys].[sp_MSdbuseraccess] TO [public] AS [dbo]
GO
