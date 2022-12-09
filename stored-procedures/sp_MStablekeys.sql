SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MStablekeys]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MStablekeys] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MStablekeys]
	@tablename [nvarchar](776),
	@colname [nvarchar](258),
	@type [int],
	@keyname [nvarchar](517),
	@flags [int]
WITH EXECUTE AS CALLER
AS
create table #tempID
	   (
      cName nvarchar(132) COLLATE database_default NOT NULL,      /* Index name */
      cPK1  int, cPK2  int, cPK3  int, cPK4  int, cPK5  int, cPK6  int, cPK7  int, cPK8  int,
      cPK9  int, cPK10 int, cPK11 int, cPK12 int, cPK13 int, cPK14 int, cPK15 int, cPK16 int    /* 1 if DESC  */
      )

   create table #tempID2
      (
      cPKName  nvarchar(132) COLLATE database_default NOT NULL,      /* PK name */
      cPK      int                                   /* Combined info for PK */
      )

	create table #spkeys
	(
		cType          tinyint NOT NULL, /* key Type */
		cName          nvarchar(258) COLLATE database_default NOT NULL, /* key Name */
		cFlags         int  NULL,  /* e.g., 1 = clustered for PK/Unique */
		cColCount      int  NULL,  /* number of columns (or column pairs) in the key */
		cFillFactor    tinyint NULL, /* Fill factor of index creation */
		cRefTable      nvarchar(520) COLLATE database_default NULL,		/* owner-qual Referenced table name for FKs */
		cRefKey        nvarchar(260)  COLLATE database_default NULL,		/* name of referenced key in referenced table */
			-- Note:  cConstID replaces the column list used in 6.0, for speed.
			-- The output set MUST replace this with either index_col(@tablename, cIndexID, 1-16) and NULL * 16
			-- (for PK/UQ) UNION col_name(r.fkeyid, r.fkey1-16) and col_name(r.rkeyid, r.rkey1-16), for SQLDMO,
			-- and these MUST BE nvarchar(132) for alignment in the SQLDMO cache structure!
		cConstID       int  NULL, /* Reference constraint ID, if Foreign Key  */
		cIndexID       int  NULL, /* ID of this key's index, if PK/UQ */
		cGroupName     sysname COLLATE database_default  NULL,  /* FileGroup name of this key, if PK/UQ */
		cDisabled      int  NULL,  /* 0 if enabled, 1 if disabled */
		cPrimaryFG     int  NULL,  /* 1 if primary FG, 0 otherwise */
      cDeleteCascade int  NULL,    /* 1 if it is a foreign key constraint with a cascade delete */
      cUpdateCascade int  NULL     /* 1 if it is a foreign key constraint with a cascade update */
	)

	/* This proc returns the table's DRI keys.  @type is the type(s) of key(s) to return. */
	/* Make sure @type is only the key types (DRI_PRIMARYKEY, DRI_UNIQUE, DRI_REFERENCE). */
	if (@type is null)
		select @type = 0x000e
	else
		select @type = @type & 0x000e

	/* Flags usage:  For daVinci, to pass call thru to sp_MStablerefs. */
	if (@flags is null)
		select @flags = 0

	set nocount on
	declare @cType int, @cName nvarchar(258), @cFlags int, @cRefTable nvarchar(520), @fillfactor tinyint
	declare @objid int, @constid int, @indid int, @keycnt int, @q1 nvarchar(2000), @q2 nvarchar(2000), @objtype int, @groupname sysname
	declare @cDisabled int, @PrimaryFG int, @cDeleteCascade int, @cUpdateCascade int

	/* First see if @keyname was defined, and override @tablename and @type if so. */
	if (@keyname is not null)
	begin
         select @objid = id, @type = power(2, status & 0x0f) from dbo.sysconstraints where constid = object_id(@keyname)
         if (@objid is null)	begin
            RAISERROR (15001, -1, -1, @keyname)
            return 1
         end
         /* Now get the tablename for the index_col below */
         select @tablename = N'[' + REPLACE(schema_name(syso.schema_id), N']', N']]') + N']' + N'.' + N'[' + REPLACE(syso.name, N']', N']]') + N']' from sys.all_objects syso where syso.object_id = @objid
	end else begin
		/* Want all keys for this table (of @type type). */
		select @objid = id, @objtype = (case when OBJECTPROPERTY(id, N'IsTable') = 1 then 1 else 0 end)
			from dbo.sysobjects where id = object_id(@tablename)
		if (@objid is null)	begin
			RAISERROR (15001, -1, -1, @tablename)
			return 1
		end
		if (@objtype <> 1)	begin
			RAISERROR (15218, -1, -1, @tablename)
			return 1
		end
		if @colname is not null and not exists (select * from dbo.syscolumns where id = @objid and name = @colname) begin
			RAISERROR (14305, -1, -1, @colname, @tablename)
			return 1
		end

		/* Skip cursor opening if we don't have any keys (of the type wanted); return a set anyway, for the cache. */
		if (((@type & power(2, 1)) = 0 or objectproperty(@objid, 'TableHasPrimaryKey') = 0) and
			((@type & power(2, 2)) = 0 or objectproperty(@objid, 'TableHasUniqueCnst') = 0) and
			((@type & power(2, 3)) = 0 or objectproperty(@objid, 'TableHasForeignKey') = 0))
			goto ReturnSet
	end

	/* Preprocessor won't replace within quotes so have to use str(). */
	declare @sysgenname nvarchar(12), @pkstr nvarchar(12), @uqstr nvarchar(12), @fkstr nvarchar(12), @objtypebits nvarchar(12)
	select @sysgenname = ltrim(str(convert(int, 0x00020000)))
	select @pkstr = ltrim(str(convert(int, 1)))
	select @uqstr = ltrim(str(convert(int, 2)))
	select @fkstr = ltrim(str(convert(int, 3)))
	select @objtypebits = ltrim(str(convert(int, 0x0f)))

	/* Other ints we need strings for */
	declare @objidstr nvarchar(12), @typestr nvarchar(12)
	select @objidstr = ltrim(str(@objid))
	select @typestr = ltrim(str(@type))

	/* Qualifying key name. Size buffer = 517 (keyname)+ 517 (for escaping) + 100 (misc string)*/
	declare @qualkeyname nvarchar(1134)
	select @qualkeyname = null
	if (@keyname is not null) begin
      select @qualkeyname = N' and constid = object_id(''' + REPLACE(@keyname, '''', '''''') + N''')'
   end

	/*********************/
	/* Main cursor loop. */
	/*********************/
/*	exec(N'declare hC insensitive cursor for select constid, status & ' + @objtypebits + N', status & ' + @sysgenname + */
	exec(N'declare hC cursor global for select constid, status & ' + @objtypebits + N', status & ' + @sysgenname +
			N' from dbo.sysconstraints where id = ' + @objidstr + N' and (' + @typestr + N' & power(2, status & 0x0f) != 0) ' + @qualkeyname)
	open hC
	fetch hC into @constid, @cType, @cFlags
	while (@@fetch_status >= 0) begin
		if (object_name(@constid) is null) begin
			RAISERROR(55555, 16, 1); -- N'Assert failed:  object_name(@constid) is null in sp_MStablekeys (pk/uq)'
			return 1
		end

		/* DRI_PRIMARYKEY, DRI_UNIQUE */
		if (@cType in (1, 2)) begin
			/* Get the index id enforcing this constraint. */
			select @indid = i.indid, @cName = o.name, @fillfactor = i.OrigFillFactor,
					@cFlags = @cFlags | (case indid when 1 then 0x00000001 else 0 end),		/* test for clustered index */
               /* clustered index keys are part of non-clustered index key list, which cause incorrect sysindexes.keycnt */
					@keycnt = case indid when 1 then keycnt else (select count(x.id) from dbo.sysindexkeys x where i.indid = x.indid and x.id = @objid) end,
               @groupname = f.groupname,
               @PrimaryFG = FILEGROUPPROPERTY( f.groupname, N'IsPrimaryFG' )
				from dbo.sysindexes i, dbo.sysobjects o, dbo.sysfilegroups f
            /* Use '=' instead of 'LIKE' in comparision, so we can handle wide card character correctly */
				where o.id = @constid and i.name = o.name and i.status & 0x1800 <> 0 and i.groupid = f.groupid
			if (@indid is null) begin
				RAISERROR(77777, 16, 1); -- N'Assert failed:  @indid is null in sp_MStablekeys (pk/uq)'
				return 1
			end

			insert #spkeys values (@cType, @cName, @cFlags, @keycnt, @fillfactor, null, null, null, @indid, @groupname, 0, @PrimaryFG, 0, 0)
		end

		/* DRI_REFERENCE */
		else if (@cType in (3)) begin
			/* Get the key column information from sysreferences. */
         select @keycnt = r.keycnt, @cName = object_name(r.constid), @cRefTable = N'[' + schema_name(syso.schema_id) + N']' + N'.' + N'[' + o.name + N']',
               @cDisabled = OBJECTPROPERTY( r.constid, N'CnstIsDisabled' ),
               @cDeleteCascade = OBJECTPROPERTY( r.constid, N'CnstIsDeleteCascade'),
               @cUpdateCascade = OBJECTPROPERTY( r.constid, N'CnstIsUpdateCascade')
            from dbo.sysreferences r, dbo.sysobjects o, sys.all_objects syso where r.constid = @constid and o.id = r.rkeyid and o.id = syso.object_id

			/* Follow r.rkeyindid back to sysindexes to get the ref key name. */
			declare @cRefKey nvarchar(132)
			select @cRefKey = i.name, @cFlags = c.status from dbo.sysreferences r, dbo.sysindexes i, dbo.sysconstraints c
				where c.constid = r.constid and r.constid = @constid
				and i.id = r.rkeyid and i.indid = r.rkeyindid and i.status & 0x1800 <> 0

			/* Load our temp table. */
			insert #spkeys values (@cType, @cName, @cFlags, @keycnt, null, @cRefTable, @cRefKey, @constid, null, null, @cDisabled, 0, @cDeleteCascade, @cUpdateCascade)
		end		/* Key type */

		/* Get the next row. */
		fetch hC into @constid, @cType, @cFlags
	end			/* PRIMARY/UNIQUE */
	deallocate hC

   /* Work on the descending information */
   set nocount on
   insert #tempID
      select cName,
      indexkey_property(object_id(@tablename), cIndexID, 1, N'isdescending'),
      indexkey_property(object_id(@tablename), cIndexID, 2, N'isdescending'),
      indexkey_property(object_id(@tablename), cIndexID, 3, N'isdescending'),
      indexkey_property(object_id(@tablename), cIndexID, 4, N'isdescending'),
      indexkey_property(object_id(@tablename), cIndexID, 5, N'isdescending'),
      indexkey_property(object_id(@tablename), cIndexID, 6, N'isdescending'),
      indexkey_property(object_id(@tablename), cIndexID, 7, N'isdescending'),
      indexkey_property(object_id(@tablename), cIndexID, 8, N'isdescending'),
      indexkey_property(object_id(@tablename), cIndexID, 9, N'isdescending'),
      indexkey_property(object_id(@tablename), cIndexID, 10, N'isdescending'),
      indexkey_property(object_id(@tablename), cIndexID, 11, N'isdescending'),
      indexkey_property(object_id(@tablename), cIndexID, 12, N'isdescending'),
      indexkey_property(object_id(@tablename), cIndexID, 13, N'isdescending'),
      indexkey_property(object_id(@tablename), cIndexID, 14, N'isdescending'),
      indexkey_property(object_id(@tablename), cIndexID, 15, N'isdescending'),
      indexkey_property(object_id(@tablename), cIndexID, 16, N'isdescending')
      from #spkeys
		order by cType, cName

   /* Construct the bit */
   declare @idx int
   declare @Name nvarchar(132)
   declare @Inx_1 int, @Inx_2 int, @Inx_3 int, @Inx_4 int, @Inx_5 int, @Inx_6 int, @Inx_7 int, @Inx_8 int
   declare @Inx_9 int, @Inx_10 int, @Inx_11 int, @Inx_12 int, @Inx_13 int, @Inx_14 int, @Inx_15 int, @Inx_16 int

   declare hCur cursor global for select * from #tempID
   open hCur
   fetch next from hCur into @Name, @Inx_1, @Inx_2, @Inx_3, @Inx_4, @Inx_5, @Inx_6, @Inx_7, @Inx_8,
                             @Inx_9, @Inx_10, @Inx_11, @Inx_12, @Inx_13, @Inx_14, @Inx_15, @Inx_16
   while (@@FETCH_STATUS = 0)
      begin
      select @idx = 0x0000
      select @idx = (case when (@Inx_1 = 1) then @idx | 0x0001 else @idx end), @idx = (case when (@Inx_2 = 1) then @idx | 0x0002 else @idx end), @idx = (case when (@Inx_3 = 1) then @idx | 0x0004 else @idx end), @idx = (case when (@Inx_4 = 1) then @idx | 0x0008 else @idx end), @idx = (case when (@Inx_5 = 1) then @idx | 0x0010 else @idx end), @idx = (case when (@Inx_6 = 1) then @idx | 0x0020 else @idx end), @idx = (case when (@Inx_7 = 1) then @idx | 0x0040 else @idx end), @idx = (case when (@Inx_8 = 1) then @idx | 0x0080 else @idx end),
             @idx = (case when (@Inx_9 = 1) then @idx | 0x0100 else @idx end), @idx = (case when (@Inx_10 = 1) then @idx | 0x0200 else @idx end), @idx = (case when (@Inx_11 = 1) then @idx | 0x0400 else @idx end), @idx = (case when (@Inx_12 = 1) then @idx | 0x0800 else @idx end), @idx = (case when (@Inx_13 = 1) then @idx | 0x1000 else @idx end), @idx = (case when (@Inx_14 = 1) then @idx | 0x2000 else @idx end), @idx = (case when (@Inx_15 = 1) then @idx | 0x4000 else @idx end), @idx = (case when (@Inx_16 = 1) then @idx | 0x8000 else @idx end)
      insert #tempID2 select @Name, @idx

      fetch next from hCur into @Name, @Inx_1, @Inx_2, @Inx_3, @Inx_4, @Inx_5, @Inx_6, @Inx_7, @Inx_8,
                                @Inx_9, @Inx_10, @Inx_11, @Inx_12, @Inx_13, @Inx_14, @Inx_15, @Inx_16
      end
   close hCur
   deallocate hCur
   set nocount off


	/* Now output the data */
ReturnSet:
	set nocount off
	select cType, cName, cFlags, cColCount, cFillFactor, cRefTable, cRefKey,
			cKeyCol1 = convert(nvarchar(132), index_col(@tablename, cIndexID, 1)),
			cKeyCol2 = convert(nvarchar(132), index_col(@tablename, cIndexID, 2)),	
			cKeyCol3 = convert(nvarchar(132), index_col(@tablename, cIndexID, 3)),
			cKeyCol4 = convert(nvarchar(132), index_col(@tablename, cIndexID, 4)),
			cKeyCol5 = convert(nvarchar(132), index_col(@tablename, cIndexID, 5)),
			cKeyCol6 = convert(nvarchar(132), index_col(@tablename, cIndexID, 6)),	
			cKeyCol7 = convert(nvarchar(132), index_col(@tablename, cIndexID, 7)),
			cKeyCol8 = convert(nvarchar(132), index_col(@tablename, cIndexID, 8)),
			cKeyCol9 = convert(nvarchar(132), index_col(@tablename, cIndexID, 9)),
			cKeyCol10 = convert(nvarchar(132), index_col(@tablename, cIndexID, 10)),
			cKeyCol11 = convert(nvarchar(132), index_col(@tablename, cIndexID, 11)),
			cKeyCol12 = convert(nvarchar(132), index_col(@tablename, cIndexID, 12)),
			cKeyCol13 = convert(nvarchar(132), index_col(@tablename, cIndexID, 13)),
			cKeyCol14 = convert(nvarchar(132), index_col(@tablename, cIndexID, 14)),	
			cKeyCol15 = convert(nvarchar(132), index_col(@tablename, cIndexID, 15)),
			cKeyCol16 = convert(nvarchar(132), index_col(@tablename, cIndexID, 16)),
			cRefCol1 = convert(nvarchar(132), null),
			cRefCol2 = convert(nvarchar(132), null),
			cRefCol3 = convert(nvarchar(132), null),
			cRefCol4 = convert(nvarchar(132), null),
			cRefCol5 = convert(nvarchar(132), null),
			cRefCol6 = convert(nvarchar(132), null),
			cRefCol7 = convert(nvarchar(132), null),
			cRefCol8 = convert(nvarchar(132), null),
			cRefCol9 = convert(nvarchar(132), null),
			cRefCol10 = convert(nvarchar(132), null),
			cRefCol11 = convert(nvarchar(132), null),
			cRefCol12 = convert(nvarchar(132), null),
			cRefCol13 = convert(nvarchar(132), null),
			cRefCol14 = convert(nvarchar(132), null),
			cRefCol15 = convert(nvarchar(132), null),
			cRefCol16 = convert(nvarchar(132), null),
			cIndexID,
			cGroupName,
         cDisabled,
	      cPrimaryFG,
         cDeleteCascade,
         cUpdateCascade,
         Descending = t.cPK
		from #spkeys, #tempID2 t where cType in (1, 2)
         and cName = t.cPKName
			and (@colname is null or
				index_col(@tablename, cIndexID, 1) = @colname or
				index_col(@tablename, cIndexID, 2) = @colname or
				index_col(@tablename, cIndexID, 3) = @colname or
				index_col(@tablename, cIndexID, 4) = @colname or
				index_col(@tablename, cIndexID, 5) = @colname or
				index_col(@tablename, cIndexID, 6) = @colname or
				index_col(@tablename, cIndexID, 7) = @colname or
				index_col(@tablename, cIndexID, 8) = @colname or
				index_col(@tablename, cIndexID, 9) = @colname or
				index_col(@tablename, cIndexID, 10) = @colname or
				index_col(@tablename, cIndexID, 11) = @colname or
				index_col(@tablename, cIndexID, 12) = @colname or
				index_col(@tablename, cIndexID, 13) = @colname or
				index_col(@tablename, cIndexID, 14) = @colname or
				index_col(@tablename, cIndexID, 15) = @colname or
				index_col(@tablename, cIndexID, 16) = @colname
			)
		UNION
		select c.cType, c.cName, c.cFlags, c.cColCount, c.cFillFactor, c.cRefTable, c.cRefKey,
			cKeyCol1 = convert(nvarchar(132), col_name(r.fkeyid, r.fkey1)),
			cKeyCol2 = convert(nvarchar(132), col_name(r.fkeyid, r.fkey2)),
			cKeyCol3 = convert(nvarchar(132), col_name(r.fkeyid, r.fkey3)),
			cKeyCol4 = convert(nvarchar(132), col_name(r.fkeyid, r.fkey4)),
			cKeyCol5 = convert(nvarchar(132), col_name(r.fkeyid, r.fkey5)),
			cKeyCol6 = convert(nvarchar(132), col_name(r.fkeyid, r.fkey6)),
			cKeyCol7 = convert(nvarchar(132), col_name(r.fkeyid, r.fkey7)),
			cKeyCol8 = convert(nvarchar(132), col_name(r.fkeyid, r.fkey8)),
			cKeyCol9 = convert(nvarchar(132), col_name(r.fkeyid, r.fkey9)),
			cKeyCol10 = convert(nvarchar(132), col_name(r.fkeyid, r.fkey10)),
			cKeyCol11 = convert(nvarchar(132), col_name(r.fkeyid, r.fkey11)),
			cKeyCol12 = convert(nvarchar(132), col_name(r.fkeyid, r.fkey12)),
			cKeyCol13 = convert(nvarchar(132), col_name(r.fkeyid, r.fkey13)),
			cKeyCol14 = convert(nvarchar(132), col_name(r.fkeyid, r.fkey14)),
			cKeyCol15 = convert(nvarchar(132), col_name(r.fkeyid, r.fkey15)),
			cKeyCol16 = convert(nvarchar(132), col_name(r.fkeyid, r.fkey16)),
			cRefCol1 = convert(nvarchar(132), col_name(r.rkeyid, r.rkey1)),
			cRefCol2 = convert(nvarchar(132), col_name(r.rkeyid, r.rkey2)),	
			cRefCol3 = convert(nvarchar(132), col_name(r.rkeyid, r.rkey3)),
			cRefCol4 = convert(nvarchar(132), col_name(r.rkeyid, r.rkey4)),
			cRefCol5 = convert(nvarchar(132), col_name(r.rkeyid, r.rkey5)),
			cRefCol6 = convert(nvarchar(132), col_name(r.rkeyid, r.rkey6)),
			cRefCol7 = convert(nvarchar(132), col_name(r.rkeyid, r.rkey7)),
			cRefCol8 = convert(nvarchar(132), col_name(r.rkeyid, r.rkey8)),
			cRefCol9 = convert(nvarchar(132), col_name(r.rkeyid, r.rkey9)),
			cRefCol10 = convert(nvarchar(132), col_name(r.rkeyid, r.rkey10)),
			cRefCol11 = convert(nvarchar(132), col_name(r.rkeyid, r.rkey11)),
			cRefCol12 = convert(nvarchar(132), col_name(r.rkeyid, r.rkey12)),
			cRefCol13 = convert(nvarchar(132), col_name(r.rkeyid, r.rkey13)),
			cRefCol14 = convert(nvarchar(132), col_name(r.rkeyid, r.rkey14)),
			cRefCol15 = convert(nvarchar(132), col_name(r.rkeyid, r.rkey15)),
			cRefCol16 = convert(nvarchar(132), col_name(r.rkeyid, r.rkey16)),
			cIndexID,
			cGroupName,
         cDisabled,
	      cPrimaryFG,
         cDeleteCascade,
         cUpdateCascade,
         0
		from #spkeys c, dbo.sysreferences r where c.cType = 3 and r.constid = c.cConstID
			and (@colname is null or
				col_name(r.fkeyid, r.fkey1) = @colname or
				col_name(r.fkeyid, r.fkey2) = @colname or
				col_name(r.fkeyid, r.fkey3) = @colname or
				col_name(r.fkeyid, r.fkey4) = @colname or
				col_name(r.fkeyid, r.fkey5) = @colname or
				col_name(r.fkeyid, r.fkey6) = @colname or
				col_name(r.fkeyid, r.fkey7) = @colname or
				col_name(r.fkeyid, r.fkey8) = @colname or
				col_name(r.fkeyid, r.fkey9) = @colname or
				col_name(r.fkeyid, r.fkey10) = @colname or
				col_name(r.fkeyid, r.fkey11) = @colname or
				col_name(r.fkeyid, r.fkey12) = @colname or
				col_name(r.fkeyid, r.fkey13) = @colname or
				col_name(r.fkeyid, r.fkey14) = @colname or
				col_name(r.fkeyid, r.fkey15) = @colname or
				col_name(r.fkeyid, r.fkey16) = @colname
			)
		order by cType, cName

	if (@flags & 1 <> 0)
		exec sys.sp_MStablerefs @tablename, N'actualkeycols', N'foreign'

GO
GRANT EXECUTE ON [sys].[sp_MStablekeys] TO [public] AS [dbo]
GO
