SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSgetconflictinsertproc]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSgetconflictinsertproc] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSgetconflictinsertproc]
	@artid [uniqueidentifier],
	@pubid [uniqueidentifier],
	@output [int],
	@force_generate_proc [bit]
WITH EXECUTE AS CALLER
AS
declare @conflict_table sysname
    declare @conflict_proc  sysname
	declare @quoted_conflict_proc nvarchar(258)
    declare @owner          sysname
    declare @object         sysname
    declare @retcode        int
    declare @basetableid    int
    declare @sync_objid         int
    declare @command            nvarchar(1000)
    declare @pubidstr           nvarchar(40)
    declare @dbname             sysname
    declare @conflict_table_id  int
    -- PARSENAME VARS
    declare @UnqualName     nvarchar(270)  --rightmost name node
    declare @QualName1      nvarchar(270)  
    declare @QualName2      nvarchar(270)  
    declare @qualified_conflict_proc nvarchar(300)
    -- END PARSENAME VARS

    declare @guidstr varchar(40)
    exec @retcode=sys.sp_MSguidtostr @artid, @guidstr out
    if @retcode<>0 or @@ERROR<>0 return (1)
    
    /*
    ** Check to see if current publication has permission
    */
    exec @retcode = sys.sp_MSrepl_PAL_rolecheck @pubid = @pubid, @artid = @artid
    if (@retcode <> 0) or (@@error <> 0)
        return 1
    /*
    ** @pubid is NULL - means that subscriber is 7.0, in which case there is no
    ** vertical partitioning allowed. getting the proc from any publication is fine.
    */
    select @conflict_table = conflict_table, @conflict_proc = ins_conflict_proc, 
            @basetableid = objid, @sync_objid = sync_objid 
    from dbo.sysmergearticles where artid = @artid and (pubid=@pubid OR @pubid is NULL)

    if @@ERROR <> 0
        return (1)

    select @conflict_table_id = object_id(@conflict_table)
    if @conflict_table_id is NULL  --check if it is caused by different owner name
        select @conflict_table_id=object_id from sys.objects where name=@conflict_table

    if ( @conflict_table_id is not null)
    begin           
        select @UnqualName = PARSENAME(@conflict_table, 1)
        select @QualName1 = PARSENAME(@conflict_table, 2)
        if @UnqualName IS NULL
             return 1
        
        -- fixup for variable length differences.  remove when vars expanded
        -- to new SQL SERVER 7.0 lengths

        select @owner=SCHEMA_NAME(schema_id) from sys.objects where object_id= @conflict_table_id
        if @owner is NULL
        begin
            select @owner =  @QualName1
        end
        select @object = @UnqualName
    end
    
    -- Create an index on the conflict table if it doesn't have one
    if ( @conflict_table_id is not null) and
        not exists (select * from sys.indexes where object_id = @conflict_table_id and index_id = 1)
    begin
        declare @rgcol nvarchar(258)
        declare @indname nvarchar(270)
        declare @quotedname nvarchar(517)
        
        select @rgcol = QUOTENAME(name) from sys.columns where object_id = @basetableid and is_rowguidcol = 1
        select @indname = 'uc_' + @conflict_table
        if len(@indname) > 128
        begin
            select @indname = substring(@indname,1,92) + convert(nvarchar(36), newid())
        end
        set @indname = QUOTENAME(@indname)
        set @quotedname = QUOTENAME(@owner) + '.' + QUOTENAME(@conflict_table)
        
        if exists (select * from sys.columns where object_id = @conflict_table_id and quotename(name) = @rgcol)
                and exists (select * from sys.columns where object_id = @conflict_table_id and name = 'origin_datasource')
        begin
            exec ('Create unique clustered index ' + @indname + ' on ' + @quotedname +
                    ' (' + @rgcol + ', origin_datasource)' )
            if @@error <> 0
                return (1)
        end
    end

    if @force_generate_proc = 1 and OBJECT_ID(@conflict_proc) is not NULL and (@conflict_table_id is not null)
    begin
        -- conflict proc should be owned by dbo. if not the object_id clause above would not have returned the proc name.
        -- I do not want to add the sys.objects query here to get the schama owner of the conflict proc because too many
        -- sys.objects queries causes deadlocks with sys.sysschobjs metadata table
		select @quoted_conflict_proc = quotename(@conflict_proc)
        exec ('drop proc ' + @conflict_proc)
        if @@error<>0
            return (1)
    end
    
    if ((OBJECT_ID(@conflict_proc) is null) and (@conflict_table_id is not null))
    begin
        -- first set up the procedure name variable

        exec @retcode = sys.sp_MSguidtostr @artid, @guidstr out
        if @@ERROR <>0 OR @retcode <>0 return (1)

        exec @retcode = sys.sp_MSguidtostr @pubid, @pubidstr out
        if @@ERROR <>0 OR @retcode <>0 return (1)

        if @pubid is not NULL
            select @conflict_proc = 'MSmerge_cft_sp_' + substring(@guidstr, 1, 16) + substring(@pubidstr, 1, 16)
        else
            select @conflict_proc = 'MSmerge_cft_sp_' + substring(@guidstr, 1, 32) 

        set @dbname = db_name()
        if @owner is NULL
            set @command = 'sys.sp_MSmakeconflictinsertproc ' + QUOTENAME(@conflict_table) + ' , NULL , ' + quotename(@conflict_proc)  + ' , ' + convert(nvarchar,@basetableid)
        else
            set @command = 'sys.sp_MSmakeconflictinsertproc ' + QUOTENAME(@conflict_table) + ' , ' + QUOTENAME(@owner) + ' , ' + quotename(@conflict_proc)  + ' , ' + convert(nvarchar,@basetableid) 

        if @pubid is not NULL
            set @command = @command + ', [' + convert(nchar(36), @pubid) + ']'
        exec @retcode = sys.xp_execresultset @command, @dbname
        if @@ERROR<>0 OR @retcode<>0 or object_id(@conflict_proc) is NULL
        begin
            return (1)
        end
        exec @retcode = sys.sp_MS_marksystemobject  @conflict_proc 
        if @@ERROR<>0 or @retcode<>0  return (1)
		select @command = 'grant exec on ' + quotename(@conflict_proc) + ' to public'
		exec(@command)
        if @@ERROR<>0 return (1)
        
        update dbo.sysmergearticles set ins_conflict_proc = @conflict_proc where artid = @artid and (pubid=@pubid OR @pubid is NULL)
    end

    if @output = 1
        select @conflict_table, @conflict_proc
    if @@ERROR <> 0
        return (1)
    return (0)
    
GO
GRANT EXECUTE ON [sys].[sp_MSgetconflictinsertproc] TO [public] AS [dbo]
GO
