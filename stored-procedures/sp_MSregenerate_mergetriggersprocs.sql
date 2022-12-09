SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSregenerate_mergetriggersprocs]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSregenerate_mergetriggersprocs] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSregenerate_mergetriggersprocs]
	@pubid [uniqueidentifier]
WITH EXECUTE AS CALLER
AS
begin
    declare @publication sysname
    , @publisher sysname
    , @publisher_db sysname
    , @retcode int
    , @artid uniqueidentifier
    , @prev_artid uniqueidentifier
    , @article sysname
    , @snapshot_ready tinyint
    , @local_pub bit
    
    -- security check
    exec @retcode = sys.sp_MSreplcheck_subscribe
    if @retcode<>0 or @@ERROR<>0
        return 1
    
    select @publication = name, @publisher = publisher, @publisher_db = publisher_db, @snapshot_ready = snapshot_ready 
    from dbo.sysmergepublications
    where pubid = @pubid
    
    if @publication is null
    begin
        return 1
    end

    select @local_pub = sys.fn_MSmerge_islocalpubid(@pubid)

    -- for a local publication if the snapshot is not ready there is not need to regenerate this since the snapshot will
    -- be made ready when the snaphsot is run and the snapshot will regenerate the procs and triggers.
    if @local_pub = 1 and @snapshot_ready <> 1
        return 0
    
    exec @retcode = sys.sp_MSregenerate_mergetriggers @publication, @publisher, @publisher_db
    if @@error<>0 OR @retcode<>0 
    begin
        return 1
    end 
    
    -- Call sp_MSsetartprocs if running on publisher. Else, call sp_MSmakearticleprocs.
    if @local_pub = 1
    begin
        -- at publisher
        select top 1 @artid = artid, @article = name from sysmergearticles where pubid = @pubid order by artid
        while @artid is not null
        begin
            exec @retcode = sys.sp_MSsetartprocs @publication=@publication, @article=@article, 
                                                 @force_flag=0, @pubid=@pubid
            if @@error<>0 OR @retcode<>0 
            begin
                return 1
            end 
            
            select @prev_artid = @artid
            select @artid = NULL
            
            select top 1 @artid = artid, @article = name from sysmergearticles where pubid = @pubid and artid > @prev_artid order by artid
        end
    end
    else
    begin
        -- at subscriber
        select top 1 @artid = artid, @article = name from sysmergearticles where pubid = @pubid order by artid
        while @artid is not null
        begin
            exec @retcode = sys.sp_MSmakearticleprocs @pubid, @artid, 1
            if @@error<>0 OR @retcode<>0 
            begin
                return 1
            end 
            
            select @prev_artid = @artid
            select @artid = NULL
            
            select top 1 @artid = artid, @article = name from sysmergearticles where pubid = @pubid and artid > @prev_artid order by artid
        end
    end
end
GO
GRANT EXECUTE ON [sys].[sp_MSregenerate_mergetriggersprocs] TO [public] AS [dbo]
GO
