SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_mergemetadataretentioncleanup]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_mergemetadataretentioncleanup] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_mergemetadataretentioncleanup]
	@num_genhistory_rows [int] OUTPUT,
	@num_contents_rows [int] OUTPUT,
	@num_tombstone_rows [int] OUTPUT,
	@aggressive_cleanup_only [bit]
WITH EXECUTE AS CALLER
AS
declare @artnick int
    declare @gen bigint
    declare @retcode smallint
    declare @bi_view_objid int
    declare @cmd nvarchar(4000)
    declare @delbatchsize int
    declare @delcount int
    declare @applockname nvarchar(255)
    declare @cutoffdate datetime
    declare @DbPrincipal sysname
    declare @curdate datetime
    declare @min_last_local_sentgen bigint = 0, @min_last_local_recgen bigint = 0

    set @num_genhistory_rows= 0
    set @num_contents_rows= 0
    set @num_tombstone_rows= 0

    SET XACT_ABORT ON

    -- Security check
    exec @retcode= sys.sp_MSrepl_PAL_rolecheck
    if @retcode <> 0 or @@error <> 0
    begin    
        RAISERROR (15247, 11, -1)
        return (1)
    end

    if exists (select * from sys.database_principals where name=N'MSmerge_PAL_role' and type = 'R')
        select @DbPrincipal = N'MSmerge_PAL_role'
    else
        select @DbPrincipal = N'db_owner'

    -- if somebody else is already cleaning up in this database, we simply return
    set @applockname= 'MS_sp_mergemetadataretentioncleanup' + convert(nvarchar(11), db_id())
    exec @retcode= sp_getapplock @Resource= @applockname, @LockMode= 'Exclusive', @LockOwner= 'Session', @LockTimeout= 0, @DbPrincipal = @DbPrincipal 
    if @@error <> 0 or @retcode < 0 return (0)

    set @delbatchsize= 5000

    exec @retcode = sys.sp_MSmerge_subbased_downloadonly_metadatacleanup @num_genhistory_rows output, @num_contents_rows output, @num_tombstone_rows output
    if @@error <> 0 or @retcode <> 0
    begin
        select @retcode = 1
        goto ReleaseAppLockAndExit
    end

    if @aggressive_cleanup_only = 1    -- just do aggressive cleanup of single-hop articles and don't update 
                                -- last cleanup time.
    begin
        select @retcode = 0
        goto ReleaseAppLockAndExit
    end

    create table #oldgens (artnick int, gen bigint unique clustered, genstatus tinyint not null, coldate datetime not null)
    create table #activegens (gen bigint not null primary key clustered)

    -- map unresolved remote generations to local ones using provided guids
	UPDATE sysmergesubscriptions SET last_local_recgen = generation
		FROM sysmergesubscriptions INNER JOIN MSmerge_genhistory ON guidsrc = last_local_recguid WHERE last_local_recgen IS NULL

    -- build the list of last and current session's common generations. Generations from such ranges should be preserved
    -- as far as they can come on picture next sync as a common generation and such metadata shouldn't be cleaned up
    SELECT sub.partition_id, sub.pubid,
            CASE WHEN upper(sub.subscriber_server) COLLATE database_default = UPPER(publishingservername()) COLLATE database_default AND sub.db_name = db_name()
                    THEN pub.last_local_sentgen
                    ELSE sub.last_local_sentgen
            END AS oldsent,
            CASE WHEN upper(sub.subscriber_server) COLLATE database_default = UPPER(publishingservername()) COLLATE database_default AND sub.db_name = db_name()
                    THEN pub.sentgen
                    ELSE sub.sentgen
            END AS newsent,
            CASE WHEN upper(sub.subscriber_server) COLLATE database_default = UPPER(publishingservername()) COLLATE database_default AND sub.db_name = db_name()
                    THEN pub.last_local_recgen
                    ELSE sub.last_local_recgen
            END AS oldrecv,
            CASE WHEN upper(sub.subscriber_server) COLLATE database_default = UPPER(publishingservername()) COLLATE database_default AND sub.db_name = db_name()
                    THEN pubgen.generation
                    ELSE subgen.generation
            END AS newrecv
    INTO #ranges FROM sysmergesubscriptions AS sub INNER JOIN
            sysmergesubscriptions AS pub ON pub.pubid = sub.pubid AND pub.subid = sub.pubid LEFT OUTER JOIN
            MSmerge_genhistory as subgen ON subgen.guidsrc = sub.recguid LEFT OUTER JOIN
            MSmerge_genhistory as pubgen ON pubgen.guidsrc = pub.recguid
    WHERE sub.status <> 2 AND
            sub.subid <> sub.pubid AND
            isnull(sub.cleanedup_unsent_changes,0) <> 1

    -- identify minimal last sent and received generations to normalize to these values rather than use 0 if subscriber has never synchronized before
    SELECT @min_last_local_sentgen = isnull(min(oldsent),0), @min_last_local_recgen = isnull(min(oldrecv),0) FROM #ranges

    -- build the list of possible common generations for unexpired active subscribers considering possible common generations and their partitions belonging
    INSERT INTO #activegens
        SELECT DISTINCT gen.generation
        FROM #ranges as ranges INNER JOIN
            MSmerge_genhistory as gen ON
				(generation BETWEEN isnull(oldsent, @min_last_local_sentgen) + 1 AND newsent OR
				 generation BETWEEN isnull(oldrecv, @min_last_local_recgen) + 1 AND newrecv) LEFT OUTER JOIN
            dbo.MSmerge_generation_partition_mappings gpm ON gen.generation = gpm.generation AND
				(ranges.partition_id = gpm.partition_id OR gpm.partition_id = -1 OR ranges.partition_id = -1) INNER JOIN
            dbo.sysmergearticles sma on gen.art_nick = sma.nickname and sma.pubid = ranges.pubid
        WHERE ranges.partition_id = gpm.partition_id OR
			isnull(ranges.partition_id,0) = 0 OR
			gpm.partition_id = -1 OR
			(gen.generation = gpm.generation AND ranges.partition_id = -1) ORDER BY 1

    DROP TABLE #ranges

    -- iterate over all articles that do not belong to a publication with infinite retention
    declare article_curs cursor local fast_forward for 
        select distinct nickname from dbo.sysmergearticles where 
            nickname not in (select distinct a.nickname from dbo.sysmergearticles as a inner join dbo.sysmergepublications as p on (a.pubid = p.pubid) 
                                where isnull(p.retention,0) = 0) 
        for read only

    open article_curs
    fetch next from article_curs into @artnick

    while (@@fetch_status <> -1)
    begin
        select @curdate = getdate()
        select @cutoffdate = null
        -- find max retention of all pubs the article belongs to.
        -- add some safety margin to compensate for different clock speeds
        select @cutoffdate = min(sys.fn_subtract_units_from_date(isnull(retention,0), retention_period_unit, @curdate))
                                from dbo.sysmergepublications where
                                pubid in (select pubid from dbo.sysmergearticles where nickname = @artnick)

        truncate table #oldgens

        -- ensure we will not clean up generations which where part of last sync, because they can be accessed later as common generation in following cases:
        -- local (since next of last session's sent till currently sent one) or remote (since next of last session's received till currently received one)
        -- everything after a sent generation can be deleted safely which will set cleanedup_unsent_changes flag and expire subscription
        insert into #oldgens select distinct @artnick, generation, genstatus, coldate from dbo.MSmerge_genhistory where
                                art_nick = @artnick and
                                genstatus in (1,2) and
                                coldate < @cutoffdate
                                and not exists (select * from #activegens where generation = gen)

        -- go to next article if this one has no stale generations
        if @@rowcount = 0
        begin
            fetch next from article_curs into @artnick
            continue
        end

        exec @retcode = sys.sp_MSexpire_dynamic_snapshots_affected_by_cleanup
        if @retcode<>0 or @@error<>0 goto Failure

        exec @retcode = sys.sp_MSmark_expired_subscriptions
        if @retcode<>0 or @@error<>0 goto Failure

        -- set highest version in dbo.sysmergearticles
        exec @retcode= sys.sp_MSsethighestversion @artnick= @artnick
        if @retcode<>0 or @@error<>0 goto Failure

        -- clean up contents, tombstone, before image (if it exists), genhistory

        set @delcount= @delbatchsize
        while @delcount = @delbatchsize
        begin
            -- TAKE a table lock on MSmerge_contents to avoid deadlocks on the  DML trigger (390932)
            begin transaction
            select NULL from dbo.MSmerge_contents with(TABLOCK ,HOLDLOCK) where 1=2

            delete top (@delbatchsize) cpm from dbo.MSmerge_current_partition_mappings as cpm with (rowlock)
            where cpm.tablenick = @artnick 
            and exists
                (select mc.tablenick, mc.rowguid from dbo.MSmerge_contents as mc inner join #oldgens as og 
                    on (mc.generation = og.gen) 
                    where mc.tablenick = @artnick
                    and mc.tablenick = cpm.tablenick
                    and mc.rowguid = cpm.rowguid)

            set @delcount= @@rowcount
            commit  transaction
        end

        set @delcount= @delbatchsize
        while @delcount = @delbatchsize
        begin
            delete top (@delbatchsize) ppm from dbo.MSmerge_past_partition_mappings as ppm
            inner join #oldgens as og on (ppm.generation = og.gen) where ppm.tablenick = @artnick
                    
            set @delcount= @@rowcount
        end

        set @delcount= @delbatchsize
        while @delcount = @delbatchsize
        begin
            delete top (@delbatchsize) mc from dbo.MSmerge_contents as mc inner join #oldgens as og on (mc.generation = og.gen) where mc.tablenick = @artnick
            set @delcount= @@rowcount
            set @num_contents_rows= @num_contents_rows + @delcount
        end

        set @delcount= @delbatchsize
        while @delcount = @delbatchsize
        begin
            delete top (@delbatchsize) mt from dbo.MSmerge_tombstone as mt inner join #oldgens as og on (mt.generation = og.gen) where tablenick = @artnick
            set @delcount= @@rowcount
            set @num_tombstone_rows= @num_tombstone_rows + @delcount
        end

        set @bi_view_objid= (select top 1 before_upd_view_objid from dbo.sysmergearticles where nickname = @artnick)
        if @bi_view_objid is not null
        begin
            set @cmd= 'delete top (' + cast(@delbatchsize as nvarchar) + ') bi from ' + quotename(object_name(@bi_view_objid)) + ' as bi inner join #oldgens as og on (bi.generation = og.gen)'
            set @delcount= @delbatchsize
            while @delcount = @delbatchsize
            begin
                exec sys.sp_executesql @cmd
                set @delcount= @@rowcount
            end
        end

        set @delcount= @delbatchsize
        while @delcount = @delbatchsize
        begin
            delete top (@delbatchsize) gpm from dbo.MSmerge_generation_partition_mappings as gpm inner join #oldgens as og 
                on (gpm.generation = og.gen)
            set @delcount= @@rowcount
        end
        
        -- We do not clean up MSmerge_metadataaction_request, because reenumeration
        -- requests would be lost. Those rows get cleaned up by the corresponding
        -- ins/del/upd procs, so we should be fine.

        set @delcount= @delbatchsize
        while @delcount = @delbatchsize
        begin
            delete top (@delbatchsize) gh from dbo.MSmerge_genhistory as gh inner join #oldgens as og on (gh.generation = og.gen) where art_nick = @artnick
            set @delcount= @@rowcount
            set @num_genhistory_rows= @num_genhistory_rows + @delcount
        end

        -- get next article
        fetch next from article_curs into @artnick
    end

    close article_curs
    deallocate article_curs
    drop table #oldgens
    drop table #activegens

    exec sp_MScleanup_zeroartnick_genhistory @num_genhistory_rows output, @num_contents_rows output, @num_tombstone_rows output
    -- reset metadata cleanup time after the task is completed
    update dbo.sysmergesubscriptions set metadatacleanuptime = getdate() 
    -- ignore errors if any, intentionally.
    exec @retcode= sp_releaseapplock @Resource= @applockname, @LockOwner= 'Session', @DbPrincipal = @DbPrincipal
    if @@error <> 0 or @retcode < 0
        return (1)
    else
        return (0)

Failure:
    close article_curs
    deallocate article_curs
    drop table #oldgens
    drop table #activegens
    select @retcode = 1
    
ReleaseAppLockAndExit:

    exec sp_releaseapplock @Resource= @applockname, @LockOwner= 'Session', @DbPrincipal = @DbPrincipal
    return @retcode

GO
GRANT EXECUTE ON [sys].[sp_mergemetadataretentioncleanup] TO [public] AS [dbo]
GO
