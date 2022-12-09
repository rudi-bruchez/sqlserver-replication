SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSsetconflicttable]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSsetconflicttable] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSsetconflicttable]
	@article [sysname],
	@conflict_table [sysname],
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname]
WITH EXECUTE AS CALLER
AS
declare @artid uniqueidentifier
    declare @pubid uniqueidentifier
    declare @quoted_conflict_table nvarchar(270)
    declare @qual_conflict_table nvarchar(270)
    declare @basetableid    int
    declare @conflicttableowner nvarchar(270)
    declare @retcode int

    --special case'd this out for backward compatibility with 7.0 subscribers.
    if @publisher is NULL and @publisher_db is NULL and @publication is NULL
        return (0)

    /* 
    ** Security Check get @pubid
    */
    SELECT @pubid = NULL
    exec @retcode = sys.sp_MSmerge_validate_publication_presence @publication, @publisher_db, @publisher, @pubid output
    if @retcode <> 0 or @@error <> 0
        return 1

       
    select @artid = artid, @basetableid=objid FROM dbo.sysmergearticles WHERE name = @article and pubid=@pubid  
    if @artid IS NULL
    BEGIN
        RAISERROR (20027, 16, -1, @article)
        RETURN (1)
    END

    select @quoted_conflict_table = quotename(@conflict_table)

    -- in yukon the conflict table will always be owned by dbo schema
    select @qual_conflict_table = '[dbo].' + @quoted_conflict_table
    
    exec @retcode = sys.sp_MS_marksystemobjectwitherror @qual_conflict_table
    if @retcode<>0 or @@ERROR<>0 return (1)
    update dbo.sysmergearticles set conflict_table = @conflict_table where artid = @artid and pubid=@pubid
    if @@ERROR <> 0
        return (1)

    declare @rgcol nvarchar(258)
    declare @indname nvarchar(258)
    declare @owner sysname
    declare @quotedname nvarchar(517)
        
    select @rgcol = QUOTENAME(name) from sys.columns where object_id = @basetableid and is_rowguidcol = 1
    select @owner=SCHEMA_NAME(schema_id) from sys.objects where name=@conflict_table
    select @indname = 'uc_' + @conflict_table
    if len(@indname) > 128
        begin
            select @indname = substring(@indname,1,92) + convert(nvarchar(36), newid())
        end
    set @indname = QUOTENAME(@indname)
    set @quotedname = QUOTENAME(@owner) + '.' + QUOTENAME(@conflict_table)

    --only create the conflict table index when needed.
    if not exists (select * from sys.indexes where object_id = object_id(@quotedname) and index_id = 1)
                    and exists (select * from sys.columns where object_id = object_id(@quotedname) and quotename(name) = @rgcol)
                    and exists (select * from sys.columns where object_id = object_id(@quotedname) and name = 'origin_datasource')
    begin
        exec ('Create unique clustered index ' + @indname + ' on ' + @quotedname +
                ' (' + @rgcol + ',origin_datasource)' )
        if @@error <> 0
            return (1)
    end

    /* Create the conflict insert proc only when necessary for performance reason */
    if exists (select * from dbo.sysmergearticles where artid = @artid and pubid=@pubid and OBJECT_ID(ins_conflict_proc) is null)
    BEGIN
        exec sys.sp_MSgetconflictinsertproc @pubid=@pubid, @artid = @artid, @output = 0, @force_generate_proc = 1
        IF @@ERROR<> 0 OR @retcode <> 0
            return (1)
    END

    return (0)
GO
GRANT EXECUTE ON [sys].[sp_MSsetconflicttable] TO [public] AS [dbo]
GO
