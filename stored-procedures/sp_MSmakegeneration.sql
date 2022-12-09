SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSmakegeneration]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSmakegeneration] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSmakegeneration]
	@gencheck [int],
	@commongen [bigint],
	@commongenguid [uniqueidentifier],
	@commongenvalid [int] OUTPUT,
	@compatlevel [int]
WITH EXECUTE AS CALLER
AS
set nocount on
    declare @gen bigint
    , @replnick binary(6)
    , @dt datetime
    , @art_nick int
    , @first_ts int
    , @makenewrow bit
    , @retcode smallint
    , @nickbin varbinary(255)
    , @maxgendiff_fornewrow bigint
    , @count_of_articles int
    , @lock_acquired bit
    , @lock_resource nvarchar(255)
    , @procfailed bit
    , @delete_old_genhistory bit
    , @close_old_genhistory bit
    , @changecount int
    , @dbname nvarchar(258)
    , @processing_order int
    , @prev_processing_order int
    , @prev_art_nick int
    , @force_leveling bit
    , @gen_change_threshold int

    declare @cmd nvarchar(4000)
    declare @old_bi_gen bigint
    declare @bi_view_objid int
    --declare @GENSTATUS_OPEN tinyint
    --declare @GENSTATUS_MERGE_INSERTED_OPEN tinyint
    --declare @GENSTATUS_LOCAL_CLOSED tinyint
    --declare @GENSTATUS_TEMPORARILY_CLOSED tinyint
    declare @min_changes_per_gen int
    declare @max_changes_per_gen int
    declare @median_changes_per_gen int
    declare @target_gen bigint
    declare @tombstone_rows_moved int
    declare @contents_rows_moved int
    declare @changes_in_gen int
    declare @changes_in_target_gen int
    declare @max_gen_to_close bigint
    declare @min_gen_to_close bigint
    declare @current_max_gen bigint
    declare @error int
    declare @max_gen_changecount_threshold int
    declare @makegeneration_needed int
    declare @needed int

    -- Security check
    exec @retcode = sys.sp_MSrepl_PAL_rolecheck 
    if (@retcode <> 0) or (@@error <> 0)
            return 1


    SET XACT_ABORT ON
    SET DEADLOCK_PRIORITY LOW
    
    select @dbname = quotename(db_name())
    select @force_leveling = 0

    if exists (select * from dbo.sysmergepartitioninfo where partition_options>1)
        select @gencheck = 3

    if @commongen is not NULL
    begin
        exec @retcode= sys.sp_MSvalidatecommongen @commongen = @commongen, @commongenguid = @commongenguid, @commongenvalid = @commongenvalid OUTPUT
        if @retcode<>0 or @@error<>0 goto EXIT_PROC
    end

    select @procfailed = 1
    select @retcode = 0
    --select @GENSTATUS_OPEN = 0
    --select @GENSTATUS_LOCAL_CLOSED = 1
    --select @GENSTATUS_TEMPORARILY_CLOSED = 3
    --select @GENSTATUS_MERGE_INSERTED_OPEN = 4
    
    exec @retcode= sys.sp_MSgetreplnick @replnick = @replnick out
    if @retcode<>0 or @@error<>0 goto EXIT_PROC

    -- add a guard byte
    set @nickbin= @replnick + 0xFF

    --we need to test if MakeGeneration is needed here again
    -- because the first time this proc is called might be at the time before the apploc is acquired. The last_makegeneration_datetime column is updated after MakeGeneration
    -- transaction is commited. All MakeGeneration calls queued up before apploc should be skipped if it is within the MakeGenerationInterval.
        exec @retcode = sys.sp_is_makegeneration_needed  @needed=@makegeneration_needed OUTPUT
        if @retcode<>0 or @@error<>0
        begin
            set @procfailed = 1
            goto EXIT_PROC
        end  

        if @makegeneration_needed=0
        begin
            set @procfailed = 0
            goto EXIT_PROC
        end      
    
    -- If @gencheck param is set to 1 ( = ForceConvergence), look for rows with missing generation numbers and set their
    -- gen to 0
    if @gencheck = 1 or @gencheck = 2
    begin
        update dbo.MSmerge_contents set generation = 0 where generation not in
            (select generation from dbo.MSmerge_genhistory)
        update dbo.MSmerge_tombstone set generation = 0 where generation not in
            (select generation from dbo.MSmerge_genhistory)
        update dbo.MSmerge_past_partition_mappings set generation = 0 where generation not in
            (select generation from dbo.MSmerge_genhistory)
    end

    select @max_gen_changecount_threshold = max(isnull(generation_leveling_threshold,0)) from dbo.sysmergepublications
    if @max_gen_changecount_threshold is NULL
        select @max_gen_changecount_threshold = 0

    /*
    ** If there are no zero generation tombstones or rows, add a dummy row in there. 
    */
    if not exists (select 1 from dbo.MSmerge_genhistory)
    begin
        set identity_insert dbo.MSmerge_genhistory on
        set @dt = getdate()
        -- we will insert this generation in closed state. and exit makegeneration
        insert into dbo.MSmerge_genhistory with (rowlock)
            (guidsrc, genstatus, generation, art_nick, nicknames, coldate) 
        values (newid(), 1, 1, 0, @nickbin, @dt)
        if @@error<>0  
            set @procfailed = 1
        else
            set @procfailed = 0
        set identity_insert dbo.MSmerge_genhistory off
        goto EXIT_PROC
    end

    exec @retcode = sys.sp_MSmovegenzerochanges 
    if @retcode<>0 or @@error<>0 
    begin
        set @procfailed = 1
        goto EXIT_PROC
    end

    -- first get the max generation we want to close in this instance of makegeneration
    select @current_max_gen = max(generation) from dbo.MSmerge_genhistory with (rowlock)
    if @current_max_gen is NULL
    begin
        select @procfailed = 1
        goto EXIT_PROC
    end
    
    begin tran
    save tran sp_MSmakegeneration

    -- get exclusive update lock on all the generations we want to close
    update dbo.MSmerge_genhistory with (rowlock)
        set genstatus = 3
        where generation <= @current_max_gen and genstatus = 0
    if @@error<>0
    begin
        select @procfailed = 1
        goto EXIT_RELEASE_TRAN
    end

        update dbo.MSmerge_genhistory with (rowlock)
            set genstatus = 3,
                coldate = getdate(),
                nicknames = @nickbin
            where generation <= @current_max_gen and genstatus = 4 and 
                coldate not in (select login_time from sys.dm_exec_sessions) and
                subscriber_number not in (select s.subscriber_number from dbo.sysmergesubscriptions s
                                              inner join sys.dm_exec_sessions p on p.program_name = s.application_name collate database_default)
        if @@error<>0
        begin
            select @procfailed = 1
            goto EXIT_RELEASE_TRAN
        end
    
    -- we are only reading the min_gen_to_close here for optimizing queries. Since genhistory has a clustered
    -- index on generation by using min closed gen everywhere we can actually get a clustered index seek instead of
    -- a clustered index scan
    select @min_gen_to_close = min(generation) from dbo.MSmerge_genhistory with (rowlock) where genstatus = 3
    select @max_gen_to_close = max(generation) from dbo.MSmerge_genhistory with (rowlock) where genstatus = 3

    if @min_gen_to_close is NULL
        goto END_TRAN

    -- even though the changecounts should be accurate we will do an update of the changecounts here so that our further calculations
    -- can be accurate. The two update statements below update the changecount based on contents and tombstone count
    update gens1 with (rowlock)
        set changecount = isnull(gens.changecount, 0)
    from
        dbo.MSmerge_genhistory gens1 with (rowlock)
        left outer join
        (
            select g.generation, count(*) as changecount
            from MSmerge_genhistory g with (rowlock)
                inner join MSmerge_contents c with (rowlock, repeatableread) on c.generation = g.generation and g.genstatus=3
            where c.generation = g.generation and 
                  g.genstatus=3
                  group by g.generation
        ) as gens 
            on gens1.genstatus=3 and gens1.generation = gens.generation
    where gens1.genstatus=3
    if @@error<>0
    begin
        select @procfailed = 1
        goto EXIT_RELEASE_TRAN
    end

    update gens1 with (rowlock)
        set changecount = gens1.changecount + isnull(gens.changecount, 0)
    from
        dbo.MSmerge_genhistory gens1 with (rowlock)
        left outer join
        (
            select g.generation, count(*) as changecount
            from MSmerge_genhistory g  with (rowlock)
                inner join MSmerge_tombstone t  with (rowlock, repeatableread) on t.generation = g.generation and g.genstatus=3
            where t.generation = g.generation and 
                  g.genstatus=3
                  group by g.generation
        ) as gens 
            on gens1.genstatus=3 and gens1.generation = gens.generation
    where gens1.genstatus=3 
    if @@error<>0
    begin
        select @procfailed = 1
        goto EXIT_RELEASE_TRAN
    end

    if @max_gen_changecount_threshold > 0 and
        exists (select * from dbo.MSmerge_genhistory with (rowlock) where genstatus=3 and changecount > @max_gen_changecount_threshold)
    begin
        -- do leveling in a seperate transaction. We don't want to club leveling with closing of generations
        -- because we want contents leveling to happen in article order and tombstone leveling to happen in reverse
        -- article order. We can make the assumption that for a particular generation all the changes will either
        -- be in tombstone or contents. If not the triggers would have done the proper leveling anyways
        exec @retcode = sys.sp_MSleveltombstone
        if @retcode<>0 or @@error<>0 
        begin
            set @procfailed = 1
            goto EXIT_RELEASE_TRAN
        end

        exec @retcode = sys.sp_MSlevelcontents 
        if @retcode<>0 or @@error<>0 
        begin
            set @procfailed = 1
            goto EXIT_RELEASE_TRAN
        end
    end
    
    
    -- should we look for a generation with 0 artnick. We will do some special processing to split this generation's
    -- changes into per article generation changes. Let us not complete this splitting of changes in 0 artnick
    -- generation to valid artnick generations. This is because in old makegeneration we were neither leveling
    -- these generations nor explictly closing them. localize interrupted generations was closing them
    -- here we will definitely close them at the end of this transaction. But we will not level or coalese them.

    -- from this point on we will only work on the temporarily closed generations that have a valid artnick
    -- now pick one generation at a time and do the following:
    --  1. coalesce multiple generations if needed
    --  2. leveling of changes has been done already outside this transaction
    select top 1 @art_nick = nickname, @processing_order = processing_order from dbo.sysmergearticles
    order by processing_order, nickname
    while @art_nick is not null
    begin
        -- get the generation change threshold
        select @gen_change_threshold = min(isnull(generation_leveling_threshold,0)) from dbo.sysmergepublications
            where pubid in (select pubid from dbo.sysmergearticles where nickname = @art_nick)
        if @gen_change_threshold > 0
        begin
            select @min_changes_per_gen = @gen_change_threshold/10
            if (@min_changes_per_gen = 0)
                select @min_changes_per_gen = 1
            select @max_changes_per_gen = @gen_change_threshold * 2
            select @median_changes_per_gen = @gen_change_threshold

            set @bi_view_objid= (select top 1 before_upd_view_objid from dbo.sysmergearticles where nickname = @art_nick)
            if @bi_view_objid is not null
            begin
                set @cmd= 'update ' + @dbname + '.[dbo].' + quotename(object_name(@bi_view_objid)) 
                            + ' set generation=@target_gen where generation=@gen'
            end
            
            -- now coalesce generations that have fewer than min changes per generation.
            -- we will ignore zero change generations because at the end of the transaction we will delete them anyways
            select @gen = NULL
            select top 1 @gen = generation, @changes_in_gen = changecount from dbo.MSmerge_genhistory with (rowlock) 
                where genstatus = 3 and 
                      changecount < @min_changes_per_gen and 
                      changecount > 0 and 
                      art_nick = @art_nick and
                      subscriber_number = 0  -- this ensures that we coalesce only local generations and not localized generations
            while @gen is not NULL
            begin
                -- now check if there are generations with lower than the min changes per gen we want. If so we will coalesce all these gens
                select @target_gen = NULL
                select top 1 @target_gen = generation, @changes_in_target_gen = changecount from dbo.MSmerge_genhistory with (rowlock) 
                    where genstatus = 3 and 
                          changecount < @median_changes_per_gen and 
                          changecount > 0 and 
                          art_nick = @art_nick and 
                          generation <> @gen  and
                          subscriber_number = 0 -- this ensures that we coalesce only local generations and not localized generations
                if @target_gen is NULL
                begin
                    -- we have hit our last gen which has too few changes. So just leave it as it
                    break
                end

                update dbo.MSmerge_tombstone with (rowlock) set generation = @target_gen 
                    where generation = @gen and tablenick = @art_nick
                select @error = @@error, @tombstone_rows_moved = @@rowcount
                if @error<>0
                begin
                    select @procfailed = 1
                    goto EXIT_RELEASE_TRAN
                end
                select @changes_in_target_gen = @changes_in_target_gen + @tombstone_rows_moved
                select @changes_in_gen = @changes_in_gen - @tombstone_rows_moved

                update dbo.MSmerge_past_partition_mappings with (rowlock) set generation = @target_gen 
                    where generation = @gen and tablenick = @art_nick
                if @@error<>0
                begin
                    select @procfailed = 1
                    goto EXIT_RELEASE_TRAN
                end
                    
                update dbo.MSmerge_contents with (rowlock) set generation = @target_gen 
                where generation = @gen and tablenick = @art_nick
                select @error = @@error, @contents_rows_moved = @@rowcount
                if @error<>0
                begin
                    select @procfailed = 1
                    goto EXIT_RELEASE_TRAN
                end

                -- now update all other tables include before view that are using the old generation number
                if @bi_view_objid is not null
                begin
                    exec sys.sp_executesql @cmd, N'@gen bigint, @target_gen bigint', @gen=@gen, @target_gen=@target_gen
                    if @@ERROR <> 0 
                    begin
                        select @procfailed = 1
                        goto EXIT_RELEASE_TRAN
                    end
                end

                update dbo.MSmerge_contents with (rowlock) 
                    set partchangegen = @target_gen 
                where partchangegen = @gen and tablenick = @art_nick
                if @error<>0
                begin
                    select @procfailed = 1
                    goto EXIT_RELEASE_TRAN
                end

                update dbo.MSmerge_contents with (rowlock) 
                    set partchangegen = (-@target_gen )
                where partchangegen = (-@gen) and tablenick = @art_nick
                if @error<>0
                begin
                    select @procfailed = 1
                    goto EXIT_RELEASE_TRAN
                end

                update dbo.MSmerge_metadataaction_request with (rowlock) 
                    set generation = @target_gen 
                where generation = @gen and tablenick = @art_nick
                if @error<>0
                begin
                    select @procfailed = 1
                    goto EXIT_RELEASE_TRAN
                end

                select @changes_in_target_gen = @changes_in_target_gen + @contents_rows_moved
                select @changes_in_gen = @changes_in_gen - @contents_rows_moved

                -- detect possible infinite loop & exit - vsts 131099 & hotfix 50001356
                if (@tombstone_rows_moved + @contents_rows_moved = 0 )
                begin
                    -- there were no matching rows for this (generation, artnick) in tombstone or contents

                    if  (exists (select * from dbo.MSmerge_contents where generation=@gen and tablenick <> @art_nick) or 
                         exists (select * from dbo.MSmerge_tombstone where generation=@gen and tablenick <> @art_nick))
                    begin
                        -- if there exists matching rows for this generation but with a different artnick, 
                        -- change the generation for mismatched artnicks.
                        exec sp_MSadjustgenerations @gen, @changes_in_gen, @art_nick, @dbname, @nickbin
                    end

                    -- this breaks the infinite loop from happenning
                    select @changes_in_gen=0
                end


                update dbo.MSmerge_genhistory with (rowlock) set changecount = @changes_in_gen where generation = @gen
                if @@error<>0
                begin
                    select @procfailed = 1
                    goto EXIT_RELEASE_TRAN
                end
                
                update dbo.MSmerge_genhistory with (rowlock)  set changecount = @changes_in_target_gen where generation = @target_gen
                if @@error<>0
                begin
                    select @procfailed = 1
                    goto EXIT_RELEASE_TRAN
                end
                
                -- continue with the generation coalescing loop. The loop will make progress by increasing the changecount in light gens.
                select @gen = NULL
                select top 1 @gen = generation, @changes_in_gen = changecount from dbo.MSmerge_genhistory with (rowlock) 
                    where genstatus = 3 and 
                          changecount < @min_changes_per_gen and 
                          changecount > 0 and 
                          art_nick = @art_nick and
                          subscriber_number = 0 -- this ensures that we coalesce only local generations and not localized generations
            end
        end

        -- insert into generation partition mappings.
        insert into dbo.MSmerge_generation_partition_mappings with (rowlock) 
            (publication_number, partition_id, generation, changecount)
            select cpm.publication_number, cpm.partition_id, g.generation, count(*)
            from dbo.MSmerge_genhistory g with (rowlock)
                    inner join dbo.MSmerge_contents mc with (rowlock, repeatableread) 
                        on mc.generation = g.generation and 
                           mc.tablenick = @art_nick and 
                           mc.tablenick = g.art_nick and
                           g.genstatus = 3
                    inner join dbo.MSmerge_current_partition_mappings cpm with (rowlock, repeatableread) 
                        on cpm.tablenick = mc.tablenick and 
                           cpm.rowguid = mc.rowguid
            where g.art_nick = @art_nick
                and mc.tablenick = @art_nick
                and cpm.tablenick = @art_nick
                and g.genstatus = 3
            group by cpm.publication_number, cpm.partition_id, g.generation
        if @@error<>0
        begin
            select @procfailed = 1
            goto EXIT_RELEASE_TRAN
        end
                
        insert into dbo.MSmerge_generation_partition_mappings with (rowlock)
            (publication_number, partition_id, generation, changecount)
            select ppm.publication_number, ppm.partition_id, g.generation, count(*)
            from dbo.MSmerge_genhistory g with (rowlock)
                inner join dbo.MSmerge_past_partition_mappings ppm with (rowlock, repeatableread) 
                    on ppm.generation = g.generation and 
                       ppm.tablenick = g.art_nick
            where ppm.tablenick = @art_nick
                and g.art_nick = @art_nick
                and g.genstatus = 3
            group by ppm.publication_number, ppm.partition_id, g.generation
        if @@error<>0
        begin
            select @procfailed = 1
            goto EXIT_RELEASE_TRAN
        end
        
        -- continue the artnick loop
        -- set up for next time through the loop
        select @prev_art_nick = @art_nick, @prev_processing_order = @processing_order
        select @art_nick = NULL, @processing_order = NULL        
        
        select top 1 @art_nick = nickname, @processing_order = processing_order from dbo.sysmergearticles
        where (processing_order = @prev_processing_order and nickname > @prev_art_nick)
        or processing_order > @prev_processing_order
        order by processing_order, nickname        
    end    

    /*if object_id('MSmerge_genhistory_debug') is not NULL
    begin
        insert MSmerge_genhistory_debug (generation, art_nick, guidsrc, nicknames, description)
        select generation, art_nick, guidsrc, nicknames, 'before delete' from dbo.MSmerge_genhistory with (rowlock) 
        where genstatus=3 and changecount=0 and art_nick=@art_nick
    end*/


    -- delete all generations that have zero changes. even though we can just rely on changecount we 
    -- will just do a query to select contents and tombsone just to be sure.
    delete from dbo.MSmerge_genhistory with (rowlock) 
    from dbo.MSmerge_genhistory g with (rowlock)
    where genstatus = 3 and
          changecount = 0
        and not exists (select 1 from dbo.MSmerge_contents c with (rowlock, repeatableread) where c.generation = g.generation) 
        and not exists (select 1 from dbo.MSmerge_tombstone t with (rowlock, repeatableread) where t.generation = g.generation)
        and not exists (select 1 from dbo.MSmerge_past_partition_mappings ppm with (rowlock, repeatableread) where ppm.generation = g.generation)
        and not exists (select 1 from dbo.MSmerge_metadataaction_request mar with (rowlock, repeatableread) where mar.generation = g.generation)
    if @@error<>0
    begin
        select @procfailed = 1
        goto EXIT_RELEASE_TRAN
    end

    /*if object_id('MSmerge_genhistory_debug') is not NULL
    begin
        insert MSmerge_genhistory_debug (generation, art_nick, guidsrc, nicknames, description)
        select generation, art_nick, guidsrc, nicknames, 'after delete' from dbo.MSmerge_genhistory with (rowlock) 
        where genstatus=3 and changecount=0 and art_nick=@art_nick
    end*/
    
    update dbo.MSmerge_genhistory with (rowlock)
        set genstatus = 1,
            guidsrc = newid(),
            coldate = getdate()
        where genstatus = 3



END_TRAN:
      
    commit transaction

    update dbo.sysmergesubscriptions
    set last_makegeneration_datetime = getdate()
    where db_name = db_name()
       and UPPER(subscriber_server) collate database_default = UPPER(@@servername) collate database_default     

    select @procfailed = 0
    
    SET DEADLOCK_PRIORITY NORMAL

EXIT_RELEASE_TRAN:
    if (@procfailed = 1)
    begin
        rollback tran sp_MSmakegeneration
        commit tran
        return 1
    end


EXIT_PROC:
    if (@procfailed = 1)
        return (1)    
    else
        return (0)

GO
GRANT EXECUTE ON [sys].[sp_MSmakegeneration] TO [public] AS [dbo]
GO
