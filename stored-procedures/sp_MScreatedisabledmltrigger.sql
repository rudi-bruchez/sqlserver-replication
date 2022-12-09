SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MScreatedisabledmltrigger]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MScreatedisabledmltrigger] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MScreatedisabledmltrigger]
	@source_object [sysname],
	@source_owner [sysname]
WITH EXECUTE AS CALLER
AS
declare @artid uniqueidentifier
    declare @cmd nvarchar(1000)
    declare @triggername nvarchar(130)
    declare @guidstr nchar(32)
    declare @retcode int
    declare @qualified_tablename nvarchar(517)
    declare @qualified_trig_name nvarchar(517)
    declare @objid int

    /*
    ** Security Check
    */
    EXEC @retcode = sys.sp_MSreplcheck_publish
    IF @@ERROR <> 0 or @retcode <> 0
        return (1)

    select @qualified_tablename = quotename(@source_owner) + '.' + quotename(@source_object)

    select @objid = object_id(@qualified_tablename)
    if @objid is NULL
        return 1

    select top 1 @artid = artid from dbo.sysmergearticles where objid=@objid
    if @artid is NULL
        return 1
    
    exec @retcode=sys.sp_MSguidtostr @artid, @guidstr out
    if @retcode <> 0 or @@error <> 0 
        return (1)

    -- remove disable dml trigger, if it exists
    set @triggername= 'MSmerge_disabledml_' + @guidstr
    if @source_owner is not NULL
        select @qualified_trig_name = quotename(@source_owner) + '.' + quotename(@triggername)
    else
        select @qualified_trig_name = quotename(@triggername)
    
    if object_id(@qualified_trig_name, 'TR') is not null
    begin
        set @cmd= 'drop trigger ' + @qualified_trig_name 
        exec sys.sp_executesql @cmd
        if @@error <> 0 
            return 1
    end

    set @cmd='
    create trigger ' + quotename(@triggername) + ' on ' + @qualified_tablename + ' for update, insert, delete
        not for replication
    as
        set nocount on

        if @@trancount > 0 rollback tran
        raiserror (20092, 16, -1, ''' + sys.fn_replreplacesinglequote(@qualified_tablename) + ''')

        return'

    exec sys.sp_executesql @cmd
    if @@error <> 0 
        return 1

    -- Only mark the trigger as system object if it is owned by dbo.
    if exists (select * from sys.objects where name = @triggername and SCHEMA_NAME(schema_id) = 'dbo')
    begin
        exec @retcode = sys.sp_MS_marksystemobject  @triggername 
        if @@ERROR<>0 OR @retcode <>0 
            return 1
    end

    return 0
GO
GRANT EXECUTE ON [sys].[sp_MScreatedisabledmltrigger] TO [public] AS [dbo]
GO
