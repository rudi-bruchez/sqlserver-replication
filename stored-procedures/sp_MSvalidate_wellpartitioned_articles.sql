SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSvalidate_wellpartitioned_articles]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSvalidate_wellpartitioned_articles] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSvalidate_wellpartitioned_articles]
	@publication [sysname]
WITH EXECUTE AS CALLER
AS
begin
    declare @pubid uniqueidentifier, @use_partition_groups smallint, @allow_subscriber_initiated_snapshot bit
    
    select @pubid = pubid, @use_partition_groups = use_partition_groups,
        @allow_subscriber_initiated_snapshot = allow_subscriber_initiated_snapshot
    from dbo.sysmergepublications 
    where name = @publication and UPPER(publisher)=UPPER(publishingservername()) and publisher_db=db_name()

    if @pubid is null
        return 0
        
    /*
    ** Check to see if current publication has permission
    */
    if ({fn ISPALUSER(@pubid)} <> 1)
    begin
        RAISERROR (14126, 11, -1)
        return 1
    end

    -- if none of the articles in this publication claim to be well-partitioned, we don't
    -- need to do any further checks.
    if not exists (select * from dbo.sysmergepartitioninfo smpi1 inner join dbo.sysmergepartitioninfo smpi2
                    on smpi1.artid = smpi2.artid
                    where smpi1.pubid = @pubid 
                    and (smpi2.partition_options = 2 or smpi2.partition_options = 3))
        return 0
        
    -- if we are here, that means there is at least one article that has been declared to be
    -- well-partitioned. make sure we are using partition groups functionality.
    if @use_partition_groups <= 0
    begin
        raiserror(21578, 16, -1, @publication)
        return 1
    end

    if exists (select * from dbo.sysmergepartitioninfo where pubid = @pubid and partition_options = 3)
    begin
    
        -- Automatically turn on allow_subscriber_initiated_snapshot property for subscription based filtering.
        /* commenting since this is not really necessary. The users can do initdynamic
        if @allow_subscriber_initiated_snapshot != 1
        begin
            -- based on usability feeback, we should set the allow_subscriber_initiated_snapshot
            -- option to 1 rather than raise an error.
            update dbo.sysmergepublications set allow_subscriber_initiated_snapshot = 1
                where pubid = @pubid
        end*/
    
        if exists (select partition_id, count(*) from dbo.sysmergesubscriptions 
            where pubid = @pubid and partition_id is not null group by  partition_id having count(*) > 1)
        begin
            raiserror(22525, 16, -1, @publication)
            return 1
        end    
    end
    
    -- get each article that has been declared to be well-partitioned, and run some checks on each.
    declare well_partitioned_articles cursor local fast_forward for 
    select sma.nickname, sma.name, smpi.partition_options, sma.artid
    from dbo.sysmergearticles sma
    join dbo.sysmergepartitioninfo smpi
    on sma.artid = smpi.artid
    and sma.pubid = @pubid
    and (smpi.partition_options = 2 or smpi.partition_options = 3)
    for read only
    
    declare @nickname int, @article_name sysname, @retcode int, @partition_options tinyint,
            @artid uniqueidentifier
    
    set @retcode = 0
    
    open well_partitioned_articles
    
    fetch next from well_partitioned_articles into @nickname, @article_name, @partition_options, @artid
    while @@fetch_status <> -1
    begin
        
        -- check that this article has the same filtering type in all publications and subscriptions.
        if exists (select * from dbo.sysmergepartitioninfo smpi1 inner join dbo.sysmergepartitioninfo smpi2
                    on smpi1.artid = smpi2.artid
                    where smpi1.artid = @artid
                    and smpi2.artid = @artid
                    and (smpi1.partition_options <> smpi2.partition_options))
        begin
            set @retcode = 1
            raiserror(22524, 16, -1, @article_name)
            goto EXIT_PROC
        end
        
        if @partition_options = 3 and (select count(*) from dbo.sysmergearticles where nickname = @nickname) > 1
        begin
            set @retcode = 1
            raiserror(22522, 16, -1, @article_name)
            goto EXIT_PROC
        end
        
        -- Has this article been published already in another publication ?
        -- the following checks apply to the well_partitioned_multiple_hops articles
        if @partition_options = 2 and (select count(*) from dbo.sysmergearticles 
                    where nickname = @nickname 
                    and sys.fn_MSmerge_islocalpubid(pubid) = 1) > 1
        begin
        
            -- a well-partitioned article should not be published in more than one publication.
            set @retcode = 1
            raiserror(21535, 16, -1, @article_name)
            goto EXIT_PROC
        end
        
        -- check recursively that all articles above this article in join filter hierarchy are well-partitioned articles.
        exec @retcode = sys.sp_MScheck_allparents_wellpartitioned @pubid, @nickname, @publication, @article_name
        if @@error <> 0 or @retcode <> 0
        begin
            set @retcode = 1
            goto EXIT_PROC
        end
        
        -- check that this article has at most one immediate parent in join filter hierarchy.
        if (select count(*) from dbo.sysmergesubsetfilters 
            where pubid = @pubid 
            and art_nickname = @nickname
            and (filter_type & 1) = 1) > 1
        begin
            set @retcode = 1
            raiserror(21579, 16, -1, @article_name, @publication)
            goto EXIT_PROC
        end
        
        -- check that this article does not have a subset filter AND is a child in a join filter hierarchy.
        if exists (select * from dbo.sysmergearticles 
                    where pubid = @pubid 
                    and nickname = @nickname
                    and len(subset_filterclause) > 0) 
            and exists (select * from dbo.sysmergesubsetfilters 
                    where pubid = @pubid 
                    and art_nickname = @nickname
                    and (filter_type & 1) = 1)
        begin
            set @retcode = 1
            raiserror(21580, 16, -1, @article_name, @publication)
            goto EXIT_PROC
        end
                    
        -- check that this article is a child in a join filter hierarchy only using join-unique-key.
        if exists (select * from dbo.sysmergesubsetfilters 
                    where pubid = @pubid 
                    and art_nickname = @nickname
                    and (filter_type & 1) = 1
                    and join_unique_key = 0)
        begin
            set @retcode = 1
            raiserror(21581, 16, -1, @article_name, @publication)
            goto EXIT_PROC
        end
        
        if exists (select * from dbo.sysmergesubsetfilters where (filter_type & 2) = 2 
            and (art_nickname = @nickname or join_nickname = @nickname))
        begin
            set @retcode = 1
            raiserror(22523, 16, -1, @article_name)
            goto EXIT_PROC
        end
            
        fetch next from well_partitioned_articles into @nickname, @article_name, @partition_options, @artid
    end
    
EXIT_PROC:
    close well_partitioned_articles
    deallocate well_partitioned_articles
    return @retcode
end
GO
GRANT EXECUTE ON [sys].[sp_MSvalidate_wellpartitioned_articles] TO [public] AS [dbo]
GO
