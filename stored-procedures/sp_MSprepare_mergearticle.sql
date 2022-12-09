SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSprepare_mergearticle]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSprepare_mergearticle] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSprepare_mergearticle]
	@source_owner [sysname],
	@source_table [sysname],
	@publication [sysname],
	@qualified_tablename [nvarchar](270)
WITH EXECUTE AS CALLER
AS
declare @retcode            int
    declare @id                 int
    declare @qualified_name     nvarchar(270)
    declare @pubid              uniqueidentifier
    declare @article_status     tinyint
    declare @snapshot_ready     tinyint
    declare @article sysname
        
    set nocount on

    -- Security check
    if 1 <> is_member('db_owner')
    begin
        raiserror(15247,-1,-1)
        return 1
    end
    
    -- Security check
    exec @retcode= dbo.sp_MSreplcheck_publish
    if @@error <> 0 or @retcode <> 0 return (1)
    
    select @pubid = pubid, @snapshot_ready = snapshot_ready
    from dbo.sysmergepublications 
    where name=@publication and upper(publisher)=upper(publishingservername()) and publisher_db=db_name()
    
    select @qualified_name = QUOTENAME(@source_owner) + '.' + QUOTENAME(@source_table)
    select @id = object_id(@qualified_name)
        
    select top 1 @article_status = sma.status 
    from dbo.sysmergearticles sma join dbo.sysmergepublications smp
    on sma.pubid = smp.pubid
    where sma.objid = @id
    
    if @snapshot_ready = 2 or (@article_status <> 2 and @article_status <> 6)
    begin

        -- addguidcolumn needs to be called even if article is active. This is needed to 
        -- drop and recreate rowguid default constraint - to make it go back and forth 
        -- between newid() and newsequentialid().
        exec @retcode = sys.sp_MSaddguidcolumn @source_owner, @source_table
        if @@error <> 0 or @retcode <> 0
            return (1)
    end

    select @article_status = status, @article = name 
        from dbo.sysmergearticles where objid=@id and pubid=@pubid
        
    if (@article_status = 2 or @article_status = 6) and @snapshot_ready = 1
        return 0

    begin tran 
    save tran prep_merge_article
    
    exec @retcode = sys.sp_MSaddguidindex @publication, @source_owner, @source_table
    if @@error <> 0 or @retcode <> 0
        goto FAILURE
        
    exec @retcode = sys.sp_MSsetup_publisher_idrange @publication, @source_table, @source_owner
    if @@error <> 0 or @retcode <> 0
        goto FAILURE

    -- snapshot will separately call creating the triggers
    --exec @retcode = sys.sp_MSaddmergetriggers @qualified_tablename
    --if @@error <> 0 or @retcode <> 0
    --    goto FAILURE

    commit tran
    return 0

FAILURE:
    rollback tran prep_merge_article
    raiserror(20714, 10, -1, @article, @publication)
    return 1
    
GO
GRANT EXECUTE ON [sys].[sp_MSprepare_mergearticle] TO [public] AS [dbo]
GO
