SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_resetsnapshotdeliveryprogress]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_resetsnapshotdeliveryprogress] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_resetsnapshotdeliveryprogress]
	@verbose_level [int],
	@drop_table [nvarchar](5)
WITH EXECUTE AS CALLER
AS
begin
    set nocount on
    declare @retcode int
    declare @lock_acquired int
    declare @lock_resource nvarchar(255)
    declare @cursor_allocated bit
    declare @cursor_opened bit
    declare @pubidprefix nvarchar(100)    
    declare @pubid uniqueidentifier

    select @retcode = 0
    select @lock_acquired = 0
    select @lock_resource = N'snapshot_delivery_in_progress_' + 
                            db_name() collate database_default  
    select @cursor_allocated = 0
    select @cursor_opened = 0
    select @pubidprefix = N'<MergePubId>:'

    exec @retcode = sys.sp_MSreplcheck_subscribe 
    if @retcode <> 0 or @@error <> 0
    begin
        select @retcode = 1
        goto Failure
    end

    -- Parameter validation
    select @drop_table = lower(@drop_table collate SQL_Latin1_General_CP1_CS_AS)
    if @drop_table not in (N'true', N'false')
    begin
        raiserror (14148, 16,-1, '@drop_table')
        select @retcode = 1
        goto Failure
    end

    -- Wiping out the content of the MSsnapshotdeliveryprogress table
    -- can disrupt snapshots that are being applied to this subscription
    -- database. Try to acquire the snapshot-delivery-in-progress application 
    -- lock in exclusive mode prior to wiping out the table. Note that the
    -- the distribution/merge agent will acquire the same application lock in 
    -- shared mode while a snapshot is being applied. Don't try to wait
    -- for the lock for too long as other snapshot delivery processes may be
    -- blocked by our waiting. In effect, we are saying that it is OK to 
    -- starve the process that is trying to truncate the progress table.    
    
    exec @retcode = sys.sp_getapplock @Resource = @lock_resource,
                                             @LockMode = N'Exclusive',
                                             @LockOwner = N'Session',
                                             @LockTimeout = 5000, -- 5 seconds
                                             @DbPrincipal = N'db_owner'

    if @@error <> 0
    begin
        select @retcode = 1
        goto Failure
    end

    if @retcode < 0
    begin
        if @retcode = -1 and @verbose_level >= 1
        begin
            raiserror(21514,16,-1)
            select @retcode = 1
        end
        else
        begin  
            select @retcode = 0
        end
        goto Failure
    end

    select @retcode = 0, @lock_acquired = 1

    if object_id('dbo.MSsnapshotdeliveryprogress') is not null
    begin
        -- Eliminating merge snapshot progress requires additional cleanup in
        -- the merge meta-data tables so do it separately
        declare hpubid cursor local fast_forward for 
            select convert(uniqueidentifier, right(progress_token, len(progress_token) - len(@pubidprefix)))
              from dbo.MSsnapshotdeliveryprogress
             where left(progress_token, len(@pubidprefix)) = @pubidprefix

        if @@error<>0 or @retcode<>0 begin select @retcode=1 goto Failure end
        select @cursor_allocated = 1    

        open hpubid
        if @@error<>0 or @retcode<>0 begin select @retcode=1 goto Failure end
        select @cursor_opened = 1    
        
        fetch hpubid into @pubid
        while (@@fetch_status <> -1)
        begin

            exec @retcode = sys.sp_MSpurgepartialmergesnapshot
                    @pubid = @pubid
            if @@error<>0 or @retcode<>0 begin select @retcode=1 goto Failure end
            fetch hpubid into @pubid
        end

        close hpubid 
        if @@error<>0 or @retcode<>0 begin select @retcode=1 goto Failure end
        select @cursor_opened = 0
   
        deallocate hpubid
        if @@error<>0 or @retcode<>0 begin select @retcode=1 goto Failure end
        select @cursor_allocated = 0

        if @drop_table = N'false'
        begin
            truncate table dbo.MSsnapshotdeliveryprogress
            if @@error <> 0
            begin
                select @retcode = 1
                goto Failure
            end
        end
        else
        begin
            drop table dbo.MSsnapshotdeliveryprogress 
            if @@error <> 0
            begin
                select @retcode = 1
                goto Failure
            end
        end 
    end
    if @retcode <> 0 or @@error <> 0
    begin
        select @retcode = 1
        goto Failure
    end

Failure:
    if @cursor_opened = 1
    begin
        close hpubid
    end
    
    if @cursor_allocated = 1
    begin
        deallocate hpubid
    end

    if @lock_acquired = 1
    begin
        exec @retcode = sys.sp_releaseapplock @Resource = @lock_resource, 
                                                     @LockOwner = N'Session',
                                                     @DbPrincipal = N'db_owner'
        if @@error <> 0 or @retcode < 0
        begin
           select @retcode = 1
        end
    end
    return @retcode    
end
GO
GRANT EXECUTE ON [sys].[sp_resetsnapshotdeliveryprogress] TO [public] AS [dbo]
GO
