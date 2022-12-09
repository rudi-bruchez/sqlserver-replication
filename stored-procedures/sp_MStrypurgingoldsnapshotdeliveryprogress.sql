SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MStrypurgingoldsnapshotdeliveryprogress]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MStrypurgingoldsnapshotdeliveryprogress] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MStrypurgingoldsnapshotdeliveryprogress]
WITH EXECUTE AS CALLER
AS
begin
    set nocount on
    declare @retcode int
    declare @resource nvarchar(255)
    declare @lock_acquired int 
    declare @cursor_allocated bit
    declare @cursor_opened bit
    declare @pubidprefix nvarchar(100)    
    declare @pubid uniqueidentifier
    declare @cutofftime datetime
    select @retcode = 0

    select @cutofftime = datediff(day, 3, getdate())
    if @@error<>0 or @retcode<>0 begin select @retcode=1 goto Failure end

    select @lock_acquired = 0
    exec @retcode = sys.sp_MSreplcheck_subscribe 
    if @retcode <> 0 or @@error <> 0
    begin
        select @retcode = 1
        goto Failure
    end

    select @resource = 'snapshot_delivery_in_progress_' + 
        db_name() collate database_default
    select @cursor_allocated = 0
    select @cursor_opened = 0
    select @pubidprefix = N'<MergePubId>:'

    exec @retcode = sys.sp_getapplock @Resource = @resource,
                                      @LockMode = 'Exclusive',
                                      @LockOwner = 'Session',
                                      @LockTimeout = 0,
                                      @DbPrincipal = N'db_owner'
    -- Bail on critical errors from sp_getapplock
    if @retcode < -1 or @@error <> 0
    begin
        select @retcode = 1
        goto Failure
    end

    -- Lock request timeout because a snapshot is being delivered; bail
    -- without raising an error
    if @retcode = -1
    begin
        select @retcode = 0
        goto Failure
    end
    select @retcode = 0
    select @lock_acquired = 1

    -- Delete all sessions containing tokens that are more than 3 days old
    if object_id('dbo.MSsnapshotdeliveryprogress') is not null
    begin
        -- Eliminating merge snapshot progress requires additional cleanup in
        -- the merge meta-data tables so do it separately
        declare hpubid cursor local fast_forward for 
            select convert(uniqueidentifier, right(progress_token, len(progress_token) - len(@pubidprefix))) 
              from dbo.MSsnapshotdeliveryprogress
             where left(progress_token, len(@pubidprefix)) = @pubidprefix
               and session_token in
                    (select session_token
                       from dbo.MSsnapshotdeliveryprogress sdp_inner
                      where progress_timestamp < @cutofftime)
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

        delete dbo.MSsnapshotdeliveryprogress
        where session_token in 
            (select session_token
               from dbo.MSsnapshotdeliveryprogress sdp_inner
              where progress_timestamp < @cutofftime)
        if @@error <> 0
        begin
            select @retcode = 1
            goto Failure
        end
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
        exec @retcode = sys.sp_releaseapplock @Resource = @resource,
                                              @LockOwner = 'Session',
                                              @DbPrincipal = N'db_owner'

        if @retcode < 0 or @@error <> 0
        begin
            select @retcode = 1
        end
    end
    return @retcode            
end
GO
GRANT EXECUTE ON [sys].[sp_MStrypurgingoldsnapshotdeliveryprogress] TO [public] AS [dbo]
GO
