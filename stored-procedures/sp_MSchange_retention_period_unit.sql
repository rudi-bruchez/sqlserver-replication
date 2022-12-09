SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSchange_retention_period_unit]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSchange_retention_period_unit] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSchange_retention_period_unit]
	@pubid [uniqueidentifier],
	@value [tinyint]
WITH EXECUTE AS CALLER
AS
declare @re_pubid            uniqueidentifier 
    declare @artid                uniqueidentifier
    declare @schemaversion      int 
    declare @schemaguid         uniqueidentifier
    declare @schematype         int
    declare @schematext         nvarchar(2000)
    declare @retcode            int
    declare @SCHEMA_TYPE_RETENTIONUNITCHANGE int

    -- Security check
    exec @retcode = dbo.sp_MSreplcheck_subscribe
    if @retcode <> 0 or @@error <> 0
        return 1

    set @SCHEMA_TYPE_RETENTIONUNITCHANGE= 29
    
    begin tran
    save tran change_retention_pu

    update dbo.sysmergepublications set retention_period_unit = @value where pubid = @pubid
    if @@ERROR<>0
        goto UNDO
        
    -- Declare a cursor that iterates over all publications which originate at this node.
    declare #change_retention_period_unit CURSOR LOCAL FAST_FORWARD for 
        select pubid from dbo.sysmergearticles 
            where pubid<>@pubid and 
                  nickname in (select nickname from dbo.sysmergearticles where pubid=@pubid) and
                  pubid in (select pubid from dbo.sysmergepublications 
                                  where upper(publisher) collate database_default = upper(publishingservername()) collate database_default and
                                        publisher_db = db_name())

    open #change_retention_period_unit
    fetch #change_retention_period_unit into @re_pubid
    while (@@fetch_status <> -1)
    BEGIN
        update dbo.sysmergepublications set retention_period_unit = @value where pubid = @re_pubid
        if @@ERROR<>0
            goto UNDO
        set @schematype= @SCHEMA_TYPE_RETENTIONUNITCHANGE
        set @artid = null
        select @schematext = 'exec dbo.sp_MSchange_retention_period_unit '+ '''' + convert(nchar(36),@re_pubid) + '''' + ',' + convert(nvarchar, @value)        
        select @schemaversion = schemaversion from dbo.sysmergeschemachange
        if (@schemaversion is NULL)
            set @schemaversion = 1
        else
            select @schemaversion = 1 + max(schemaversion) from dbo.sysmergeschemachange        
        set @schemaguid = newid()
        exec @retcode=sys.sp_MSinsertschemachange @re_pubid, @artid, @schemaversion, @schemaguid, @schematype, @schematext
        if @@ERROR<>0 or @retcode<>0 
            goto UNDO
        fetch #change_retention_period_unit into @re_pubid
    END
    close #change_retention_period_unit
    deallocate #change_retention_period_unit
    
    COMMIT TRAN
    return (0)
UNDO:
    ROLLBACK tran change_retention_pu
    COMMIT TRAN
    return(1)
GO
GRANT EXECUTE ON [sys].[sp_MSchange_retention_period_unit] TO [public] AS [dbo]
GO
