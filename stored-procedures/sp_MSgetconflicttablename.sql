SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSgetconflicttablename]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSgetconflicttablename] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSgetconflicttablename]
	@publication [sysname],
	@source_object [nvarchar](520),
	@conflict_table [sysname] OUTPUT
WITH EXECUTE AS CALLER
AS
declare @objid              int
declare @retcode            int
declare @current_conflict   sysname
declare @object_name        sysname
declare @name_out           sysname
declare @pubid              uniqueidentifier
declare @article            sysname
declare @tablename          sysname
declare @ownername          sysname
declare @artid              uniqueidentifier
declare @create_conflict_table_on_pub bit

-- Security check
exec @retcode= dbo.sp_MSreplcheck_publish
if @@error <> 0 or @retcode <> 0 return (1)

select @tablename = null
select @ownername = null

select @pubid=pubid from dbo.sysmergepublications where name=@publication and publisher=publishingservername() and publisher_db=db_name()

select @objid = object_id(@source_object)

-- Raise error if objid is still null at this point
if @objid is null
begin
    declare @db_name nvarchar(130)
    select @db_name = db_name()
    raiserror(15009,16, -1,@source_object,@db_name)
    return 1  
end
select @article=name, @current_conflict = conflict_table, @artid = artid from dbo.sysmergearticles where objid = @objid and pubid=@pubid
if @current_conflict is not NULL
begin
    -- schema_id 1 is dbo. In yukon we enforce dbo schema for the conflict table
    if exists (select 1 from sys.objects where name = @current_conflict and schema_id = 1)
        select @create_conflict_table_on_pub = 0
    else
        select @create_conflict_table_on_pub = 1
    
    if @conflict_table is NULL
        select @current_conflict, @create_conflict_table_on_pub
    else    
        select @conflict_table = @current_conflict
    return (0)
end

if len(@publication) + len(@article) > 110         -- SYSNAME minus 'MSmerge_conflict_'
    select @object_name = 'MSmerge_conflict_' + sys.fn_MSguidtostr(@pubid) + '_' + sys.fn_MSguidtostr(@artid)
else
    select @object_name = 'MSmerge_conflict_' + @publication + '_' + @article

-- return one more column here indicating that the conflict table should be created
select @create_conflict_table_on_pub = 1
if @conflict_table is NULL
    select @object_name, @create_conflict_table_on_pub
else
    select @conflict_table = @object_name
    
return @retcode
GO
GRANT EXECUTE ON [sys].[sp_MSgetconflicttablename] TO [public] AS [dbo]
GO
