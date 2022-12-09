SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSupdatesysmergearticles]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSupdatesysmergearticles] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSupdatesysmergearticles]
	@object [sysname],
	@artid [uniqueidentifier],
	@owner [sysname],
	@pubid [uniqueidentifier],
	@recreate_repl_view [bit]
WITH EXECUTE AS CALLER
AS
declare @merge_pub_object_bit   int
    declare @id                     int
    declare @qualified_name         nvarchar(270)
    declare @colid                  int
    declare @colname                sysname
    declare @dynamic_filters        bit
    declare @mergepublish           int
    declare @retcode int
    declare @objid int
    
    SET NOCOUNT ON
    
    /*
    ** Check for subscribing permission
    */
    exec @retcode=sys.sp_MSreplcheck_subscribe
    if @retcode<>0 or @@ERROR<>0 return (1)

    set @dynamic_filters=0
    if @owner is NULL or @owner = ''
    begin
        if object_id(@object) is not NULL
            select @owner = SCHEMA_NAME(schema_id) from sys.objects where object_id = object_id(QUOTENAME(@object))
        else 
        begin
            raiserror(21078, 16, -1, @object)
            return (1)
        end
    end

    select @mergepublish = 0x4000
    
    select @qualified_name = QUOTENAME(@owner) + '.' + QUOTENAME(@object)
    select @objid = object_id(@qualified_name)
        
    select @merge_pub_object_bit    = 128

    if (@artid is NULL)
    BEGIN
        RAISERROR (14057, 16, -1)
        RETURN (1)
    END
    begin tran
    save tran sp_MSupdatesysmergearticles
    
    if exists (select name from sys.objects where object_id = @objid)
    begin

        exec %%Object(MultiName=@qualified_name).LockMatchID(ID=@objid, Exclusive = 1, BindInternal = 0)
        --exec %%Object(MultiName=@qualified_name).LockExclusiveMatchID(ID=@objid)
        if @@error<>0 goto UNDO
        exec %%Relation(ID=@objid).SetMergePublished(Value=1,SetColumns=1)
        if @@ERROR<>0 goto UNDO

        /*
        ** update dbo.sysmergearticles.objid for all articles sharing the same base table
        */
        update dbo.sysmergearticles set objid = @objid where artid = @artid
        IF @@ERROR <> 0
        BEGIN
            RAISERROR (14057, 16, -1)
            goto UNDO
        END

        /*
        ** update dbo.sysmergearticles.sysnc_objid for only the article in this publication
        ** and for articles that no longer has a valid sync_objid (usually for the
        ** non-filtered case)
        */
        update dbo.sysmergearticles set sync_objid=@objid 
         where artid = @artid 
           and (pubid = @pubid or 
                (object_name(sync_objid) is null and isnull(view_type,0) = 0))
        IF @@ERROR <> 0
        BEGIN
            RAISERROR (14057, 16, -1)
            goto UNDO
        END

        if @recreate_repl_view = 1
        begin
            exec @retcode = sys.sp_MScreate_article_repl_view @pubid, @artid
            if @retcode <> 0 or @@error <> 0
                goto UNDO
        end
    end
    else -- THIS IS FINE. This dynamic query is there to provide a good error message. No need to use SP.
        raiserror(21078, 16, -1, @object)
        
    exec sys.sp_replupdateschema @qualified_name
    if @@error<>0 goto UNDO

    commit tran
    RETURN 0
UNDO:
    rollback tran sp_MSupdatesysmergearticles
    commit tran
    RETURN 1
GO
GRANT EXECUTE ON [sys].[sp_MSupdatesysmergearticles] TO [public] AS [dbo]
GO
