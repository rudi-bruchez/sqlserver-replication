SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSmakeexpandproc]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSmakeexpandproc] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSmakeexpandproc]
	@pubname [sysname],
	@filterid [int],
	@procname [sysname]
WITH EXECUTE AS CALLER
AS
/* Declare additional variables */
    declare @pubid    uniqueidentifier
    declare @base_nick int
    declare @join_nick int
    declare @base_nickstr nvarchar(10)
    declare @join_nickstr nvarchar(10)
    declare @filterid_str nvarchar(10)
    declare @base_objid int
    declare @join_objid int
    declare @base_table nvarchar(270)
    declare @before_viewname    nvarchar(270)
    declare @join_table nvarchar(270)
    declare @base_owner nvarchar(270)
    declare @join_owner nvarchar(270)
    declare @join_clause nvarchar(4000)
    declare @retcode    int
    declare @must_check int
    declare @view_type    int
    declare @guidcolname    nvarchar(270)
    declare @joinguidname    nvarchar(270)
    declare @view_objid int
    declare @view_name    nvarchar(270)
    declare @cmd_piece    nvarchar(4000)
    select @retcode = 0
    exec @retcode = sys.sp_MSreplcheck_publish
    if @@error <> 0 or @retcode <> 0
    begin
        select 'a' = 'raiserror (''Error creating row change expansion procedure'' , 16, -1)'
        return 1
    end

    select @pubid = pubid from dbo.sysmergepublications where name = @pubname and UPPER(publisher)=UPPER(publishingservername()) and publisher_db=db_name()

    -- this procedure is to be called by xp_execresultset, so
    -- we create a temp table, put command pieces into it, and select them out

    -- create temp table to select the command text out of
    create table #tempcmd (step int identity NOT NULL, cmdtext nvarchar(max) collate database_default null)

    /* Figure out base table, join table for this join filter */
    select @base_nick = art_nickname, @join_nick = join_nickname,
        @join_clause = join_filterclause
        from dbo.sysmergesubsetfilters where pubid = @pubid and join_filterid = @filterid and (filter_type & 1) = 1
    select @base_objid = objid, @view_type = view_type, @view_objid = sync_objid from dbo.sysmergearticles where pubid = @pubid and nickname = @base_nick
    select @join_objid = objid, @before_viewname = object_name(before_view_objid)  from dbo.sysmergearticles where pubid = @pubid and nickname = @join_nick
    select @base_table = QUOTENAME(name), @base_owner = QUOTENAME(SCHEMA_NAME(schema_id)) from sys.objects where object_id = @base_objid
    select @join_table = QUOTENAME(name), @join_owner = QUOTENAME(SCHEMA_NAME(schema_id)) from sys.objects where object_id = @join_objid
    select @guidcolname = name from sys.columns where object_id = @base_objid and 
            is_rowguidcol=1
    select @joinguidname = name from sys.columns where object_id = @join_objid and 
            is_rowguidcol=1
    select @view_name = object_name(@view_objid)
    -- Quote the viewname.  It is made from pub name which may have odd characters.
    set @view_name = QUOTENAME(@view_name)
    set @base_nickstr = convert(nchar(10), @base_nick)
    set @join_nickstr = convert(nchar(10), @join_nick)
    set @filterid_str = convert(nchar(10), @filterid)
    
    set @cmd_piece = 'create procedure dbo.' + @procname + ' 
        @belong int 
        AS 
            '
    insert into #tempcmd(cmdtext) values (@cmd_piece)
    set @cmd_piece = 'if @belong = 1
            begin
            /* Do a bulk insert to expand #belong */
            update #belong set flag = ' + @filterid_str + ' where flag < ' + @filterid_str + ' 
            insert into #belong (tablenick, rowguid, flag, skipexpand) select distinct ' + @base_nickstr +
            ', ' + @base_table + '.rowguidcol, 0, 0 from ' + @base_owner + '.' + @base_table + ' ' + @base_table + ', ' +
            @join_owner + '.' + @join_table + ' ' + @join_table + ', #belong b where (' + @join_clause + ') and ' + 
            @join_table + '.rowguidcol = b.rowguid and b.tablenick = ' + @join_nickstr + ' and skipexpand = 0 '
    insert into #tempcmd(cmdtext) values (@cmd_piece)
    set @cmd_piece = '  
        if @@ERROR <>0 return (1)
        /* Delete duplicates */

        delete b1 from #belong b1, #belong b2 
            where b1.rowguid = b2.rowguid and b1.tablenick = b2.tablenick
                and b1.skipexpand=1 and b2.flag=0

        delete b1 from #belong b1, #belong b2 
            where b1.rowguid = b2.rowguid and b1.tablenick = b2.tablenick
                and b1.flag=0 and b2.flag <> 0
        end '

        insert into #tempcmd(cmdtext) values (@cmd_piece)
        
    /* Will we have to check rows that we add to #notbelong? */
    if exists (select * from dbo.sysmergearticles where pubid = @pubid and nickname = @join_nick and
        len(subset_filterclause) > 0)
        set @must_check = 1
    else if exists (select * from dbo.sysmergesubsetfilters where pubid = @pubid and join_filterid = @filterid and
        join_unique_key <> 1 and (filter_type & 1) = 1)
        set @must_check = 1
    else if not exists (select * from dbo.sysmergesubsetfilters where pubid = @pubid and  art_nickname = @base_nick
            and join_filterid <> @filterid and (filter_type & 1) = 1)
        set @must_check = 0
    
    set @cmd_piece = '
        else 
        begin
        update #notbelong set flag = ' + @filterid_str + ' where flag < ' + @filterid_str + ' 
        /* Do a bulk insert to expand #notbelong */
        insert into #notbelong (tablenick, rowguid, flag) select distinct ' + @base_nickstr +
            ', ' + @base_table + '.rowguidcol, -1 from ' + @base_owner + '.' + @base_table + ' ' + @base_table + ', ' +
            @join_owner + '.' + @join_table + ' '  + @join_table + ', #notbelong nb where (' + @join_clause + ') and ' + 
            @join_table + '.rowguidcol = nb.rowguid and nb.tablenick = ' + @join_nickstr + ' 
            /* Remove duplicates */
            delete from #notbelong where flag = -1 and rowguid in
                (select rowguid from #notbelong where flag <> -1)
            '
    if @before_viewname  is not null
    set @cmd_piece = @cmd_piece + '
        insert into #notbelong (tablenick, rowguid, flag) select distinct ' + @base_nickstr +
            ', ' + @base_table + '.rowguidcol, -1 from ' + @base_owner + '.' + @base_table + ' '  + @base_table + ', ' +
            @before_viewname + ' ' + @join_table + ', #notbelong nb where (' + @join_clause + ') and ' + 
            @join_table + '.' + @joinguidname + ' = nb.rowguid and nb.tablenick = ' + @join_nickstr + ' 
            /* Remove duplicates */
            delete from #notbelong where flag = -1 and rowguid in
                (select rowguid from #notbelong where flag <> -1)
            '
    if @must_check = 0
        begin
        insert into #tempcmd(cmdtext) values (@cmd_piece)
        set @cmd_piece = ' update #notbelong set flag = 0 where flag = -1 
            end '
        insert into #tempcmd(cmdtext) values (@cmd_piece)
        end
    else if @view_type = 1
        begin
        insert into #tempcmd(cmdtext) values (@cmd_piece)
        set @cmd_piece =  '     -- We can do our check with a bulk delete, bulk update
            delete from #notbelong where flag = -1 and rowguid in
                (select ' + @guidcolname + ' from ' + @view_name + ')
            update #notbelong set flag = 0 where flag = -1
            end '
        insert into #tempcmd(cmdtext) values (@cmd_piece)
        end
    -- else we don't bother expanding #notbelong for this filter since there are cyclic
    -- join filters and this is not a unique key join.  The cursored calls to sp_belongs
    -- are unacceptably slow, and there would still be cases where orphaned rows could occur.


-- Now we select out the command text pieces in proper order so that our caller,
-- xp_execresultset will execute the command that creates the stored procedure.

select cmdtext from #tempcmd order by step
GO
GRANT EXECUTE ON [sys].[sp_MSmakeexpandproc] TO [public] AS [dbo]
GO
