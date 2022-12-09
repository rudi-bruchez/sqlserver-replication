SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSobjectprivs]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSobjectprivs] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSobjectprivs]
	@objname [nvarchar](776),
	@mode [nvarchar](10),
	@objid [int],
	@srvpriv [int],
	@prottype [int],
	@grantee [nvarchar](258),
	@flags [int],
	@rollup [int]
WITH EXECUTE AS CALLER
AS
create table #objs(
		id  int NOT NULL
	)

	/* Temp table will hold output for final select */
	create table #output (
		action      int  NOT NULL,
		colid       int  NULL,
		uid         int  NOT NULL,
		protecttype int  NOT NULL,
		id          int  NOT NULL,
		grantor     int
	)

	create table #tmp(
		action   int   NOT NULL,
		uid      int   NOT NULL,
		protecttype int  NOT NULL,
	)

   /* mode    : 'object', 'user' or 'column'*/
   /*
    * Note:  This was expanded for 6.5 due to changes in sysprotects.columns usage, affecting
    * CPermission::ListPrivilegeColumns.  The following additional parameters are for this.
    */
   /* objid   : ID of the object we're querying */
   /* srvpriv : privilege that we're querying for (e.g. select) */
   /* prottype: Protect type, e.g. GRANT/REVOKE */
   /* grantee : Grantee name. */

   /*** @flags added for DaVinci uses.  If the bit isn't set, use 6.5 ***/
   /*** sp_MSobjectprivs '%s'                                         ***/

   /* 8.0: mode 'column', and grantee != null, we want user column level permissions for CTable/CView::ListUserColumnPermissions */
   /*      @rollup added to indicate special rollup result set for column level permission, set to 1 to roll up */

	/* @flags is for daVinci */
	if (@flags is null)
		select @flags = 0

	/* If @objid is not null, this is for the new query for perm cols. */
	if (@objid is not null) begin
		select schema_name(syso.schema_id), syso.name, a = col_name(p.id, a.number), a.low, a.high, a.number
			from master.dbo.spt_values a, dbo.sysprotects p, sys.all_objects syso
			where p.id = @objid and p.action = @srvpriv and p.protecttype = @prottype
			and p.uid = user_id(@grantee)
			and p.columns != 0x01 and syso.object_id = p.id
				and convert(tinyint, substring(isnull(p.columns, 0x01), a.low, 1)) &
					-- 6.5 changed so that the bit 0 position is an "invert the bits" indicator:
					--		when 0, behaviour is the same as in prior versions, and other bits
					--			indicate columns with the specified privilege
					--		when 1, the other bits are indicate columns lacking the specified privilege
					a.high <> (case when (substring(isnull(p.columns, 0x00), 1, 1) & 1 = 0) then 0 else a.high end)
					and col_name(p.id, a.number) is not null
					and a.type = N'P' and a.number <= (select count(*) from dbo.syscolumns where id = @objid) order by a
		return 0
	end

	set nocount on

	/*
	 * To get around a 4.21 subquery bug where returning count(*) of 0 (for proc cols)
	 * causes the result set to return no rows, we need two passes; one to get the
	 * objects, and another to explicitly use a value (@cols) instead of a subquery.
	 */
	declare @id int, @uid int, @cols int
	select @id = null, @uid = null
	if (@mode like N'us%') begin
	   select @uid = user_id(@objname)
   end else if (@mode like N'col%') and (@objname is null) and (@grantee is not null) begin
      /* 8.0, special path to get column level permissions from all objects on the specified user */
      select @uid = user_id(@grantee)
	end else begin
      select @id = object_id(@objname)
   end
	if (@id is null and @uid is null) begin
		RAISERROR (15001, -1, -1, @objname)
		return 1
	end

	/* Get a temp list of objects we're interested in.  Do not include repl_* users. */
   /* This is the original code */
   insert #objs select distinct p.id from dbo.sysprotects p
	   where (@id is null or p.id = @id)
  		and (@uid is null or p.uid = @uid)
   	and p.action in (193, 195, 196, 197, 224, 26) and p.uid not in (16382, 16383)

	/* Use a "fake cursor" by deleting successive id's from #objs, as this must run on 4.21 */
	select @id = min(id) from #objs
	while (@id is not null) begin
		select @cols = count(*) from dbo.syscolumns c where c.id = @id
      /* sysprotects.columns is for SELECT and UPDATE, NULL if it is INSERT or DELETE, since INSERT and DELETE can not be applied to column level */
      insert #output select p.action, (case when p.columns is null then -1 else a.number end), p.uid, p.protecttype, p.id, p.grantor
         from master.dbo.spt_values a, dbo.sysprotects p
         where convert(tinyint, substring( isnull(p.columns, 0x01), a.low, 1)) & a.high !=0
         and (p.id = @id)
         and (@uid is null or p.uid = @uid)
         and a.number <= @cols
         and a.type = N'P'

      declare @count int, @whataction int, @whatid int, @dup int, @whatprot int

      /* First pass to correct duplicates */
      select @count = count(*) from #output where id = @id and colid in (0, -1) and protecttype in (205, 204)
      if ( @count > 0 ) begin
         /* We might have duplicate rows for permission on single coulmn(s) at this point */
         /* Use a fake cursor to remove the duplicates first. */
         insert #tmp select action, uid, protecttype from #output where id = @id and colid in (0, -1) and protecttype in (205, 204)
         select @whataction = min(action) from #tmp
         select @whatid = uid from #tmp where action = @whataction
         while (@whataction is not null) begin
            if (@mode like N'col%') and (@objname is null) and (@grantee is not null) begin
               /* Special case for column level permissions on ALL objects for the specified user, we don't want the row(s) on the entire table */
               /* and we don't want the possible duplicate rows in single column(s) */
               delete #output where (@whatid = uid) and (colid not in (0, -1)) and (protecttype in (205, 204)) and action = @whataction
                      and (exists (select * from #output where (@whatid = uid) and (colid in (0, -1)) and action = @whataction) and (id = @id))
               delete #output where (@whatid = uid) and (colid in (0, -1)) and (action = @whataction) and (id = @id)
            end else if (@mode like N'use%') and (@objname is not null) begin
               /* Special case for the user mode, we do want to keep the entire table permissions */
               delete #output where (@whatid = uid) and (colid not in (0, -1)) and (protecttype in (205, 204)) and action = @whataction and (id = @id)
            end else begin
               /* Other cases */
               delete #output where (@whatid = uid) and (colid not in (0, -1)) and (protecttype in (205, 204)) and action = @whataction
            end

            delete #tmp where @whatid = uid
            select @whataction = min(action) from #tmp
            select @whatid = uid from #tmp where action = @whataction
         end
         delete #tmp
      end

      /* Second pass to correct protect type */
      select @count = count(*) from #output where id = @id and colid in (0, -1)
      if ( @count > 0 ) begin
         /* use another fake cursor to correct the protecttype */
         /* if there are multiple rows in #output for the same id and action, and if colid = 0 exist */
         /* then other rows should have different protecttype from the one in colid = 0 row */
         insert #tmp select action, uid, protecttype from #output where id = @id and colid in (0, -1)
         select @whataction = min(action) from #tmp
         select @whatid = uid from #tmp where action = @whataction
         select @whatprot = protecttype from #tmp where uid = @whatid and action = @whataction
         while (@whataction is not null) begin
               delete #output where id = @id and colid not in (0, -1) and @whataction = action and @whatid = uid and @whatprot = protecttype
               delete #tmp where action = @whataction and @whatid = uid
               select @whataction = min(action) from #tmp
               select @whatid = uid from #tmp where action = @whataction
               select @whatprot = protecttype from #tmp where uid = @whatid and action = @whataction
         end
         delete #tmp
      end

		/* Increment our "fake cursor" column and get the next one. */
		delete #objs where id = @id
		select @id = min(id) from #objs
	end

	/*
	 * Organize so that the non-collist privileges are returned first.. this allows
	 * scripting to combine them.  sysprotects.action is tinyint, so the hibyte won't conflict.
	 */

	update #output set action = action | 0x10000000 where colid <> 0

	/*
	 *  BUG 235637  
	 *  Delete the columns that was droped
	 */
	delete from #output where colid not in (0, -1) and col_name(id, colid) is null

	/*
	 * Order output by uid so Public will script before other groups (we need to script privs for public before
	 * other groups, before users; otherwise sysprotects doesn't hold onto things right).  Sub-order is by object id
	 * so we know when we're done with one object and onto the next, then by protecttype to group all GRANTs and
	 * REVOKEs together, and lastly by action (including ORDER_ACTION_BIT so scripting can be more efficient)
	 * because we may have multiple rows for columns.
	 */

	set nocount off
   if (@mode not like N'col%') begin
      /* Mode is not 'column', do the regular stuff */
      /*SQLDMO90OK - grantor can be only a user and the use of user_name is safe here*/
	   select p.action & ~convert(int, 0x10000000), N'column' = col_name(p.id, p.colid), p.uid, N'username' = user_name(p.uid),/*SQLDMO90OK*/
		       p.protecttype, o.name, N'owner' = schema_name(syso.schema_id), p.id, N'grantor' = user_name(p.grantor) /*SQLDMO90OK*/
             from #output p, dbo.sysobjects o, sys.all_objects syso
             where o.id = p.id and o.id = syso.object_id
             order by p.uid, p.id, p.protecttype, p.action
   end else
   /* Below are spcial cases for column level permissions */
   if (@objname is null) and (@grantee is not null) and (@rollup = 0) begin
      /* 8.0, special path to get column level permissions from all objects on the specified user */
      select N'ObjectName' = o.name, N'Owner' = schema_name(syso.schema_id), N'ColumnName' = col_name(p.id, p.colid), o.sysstat & 0x0f, p.id,
             p.action & ~convert(int, 0x10000000), p.protecttype
             from #output p, dbo.sysobjects o, sys.all_objects syso
             where p.id = o.id and o.id = syso.object_id and p.uid = user_id(@grantee) and col_name(p.id, p.colid) is not null
             order by p.uid, p.id, p.protecttype, p.action
	end else if (@objname is not null) and (@grantee is not null) and (@rollup = 0) begin
      /* 8.0, mode 'column', and grantee != null, we want column level permissions on this object for this user */
      select N'column' = col_name(p.id, p.colid), N'owner' = schema_name(syso.schema_id), N'username' = user_name(p.uid), o.sysstat & 0x0f, p.id, /*SQLDMO90OK*/
             p.action & ~convert(int, 0x10000000), p.protecttype
             from #output p, dbo.sysobjects o, sys.all_objects syso
             where o.id = p.id and o.id = syso.object_id and p.uid = user_id(@grantee) and col_name(p.id, p.colid) is not null
             order by p.uid, p.id, p.protecttype, p.action
   end else if (@objname is not null) and (@grantee is null) and (@rollup = 0) begin
      /* 8.0, mode 'column', and grantee = null, we want column level permissions on this object for all users */
      select N'column' = col_name(p.id, p.colid), N'owner' = schema_name(syso.schema_id), N'username' = user_name(p.uid), o.sysstat & 0x0f, p.id, /*SQLDMO90OK*/
             p.action & ~convert(int, 0x10000000), p.protecttype
             from #output p, dbo.sysobjects o, sys.all_objects syso
             where o.id = p.id and o.id = syso.object_id and col_name(p.id, p.colid) is not null
             order by p.uid, p.id, p.protecttype, p.action
   end else if (@objname is null) and (@grantee is not null) and (@rollup <> 0) begin
      /* 8.0, roll up version of the special path to get column level permissions from all objects on the specified user */
      select distinct N'ObjectName' = o.name, N'owner' = schema_name(syso.schema_id),
             N'Select' = (case when ((p.action & ~convert(int, 0x10000000))=193) then 1 else 0 end),
             N'Update' = (case when ((p.action & ~convert(int, 0x10000000))=197) then 1 else 0 end),
             N'Type' = p.protecttype
             from #output p, dbo.sysobjects o, sys.all_objects syso
             where p.id = o.id and o.id = syso.object_id and p.uid = user_id(@grantee) and col_name(p.id, p.colid) is not null
             order by o.name
   end else if (@objname is not null) and (@grantee is null) and (@rollup <> 0) begin
      /* 8.0, roll up version of the special path to return column level permissions on this object for all users */
      select distinct N'UserName' = user_name(p.uid), /*SQLDMO90OK*/
             N'Select' = (case when ((p.action & ~convert(int, 0x10000000))=193) then 1 else 0 end),
             N'Update' = (case when ((p.action & ~convert(int, 0x10000000))=197) then 1 else 0 end),
             N'Type' = p.protecttype
             from #output p, dbo.sysobjects o
             where o.id = p.id and col_name(p.id, p.colid) is not null
             order by user_name(p.uid)/*SQLDMO90OK*/
   end else begin
	/* localize message without changing message number */
   	declare @errtxt nvarchar(1024)
	select @errtxt=text from sys.messages where message_id=29003
	RAISERROR(55555, 16, 1); -- @errtxt
		return 1
   end
GO
GRANT EXECUTE ON [sys].[sp_MSobjectprivs] TO [public] AS [dbo]
GO
