SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MShelptranconflictcounts]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MShelptranconflictcounts] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MShelptranconflictcounts]
	@publication_name [sysname],
	@publisher [sysname],
	@publisher_db [sysname],
	@originator_id [nvarchar](32)
WITH EXECUTE AS CALLER
AS
begin
    set nocount on 

    declare @retcode int
            ,@pubid int
            ,@centralized_conflicts bit
            ,@article sysname
		,@quotedtablename nvarchar(1000)
		,@artid int
            ,@conflict_table nvarchar(1000)
            ,@cft_tabid int
            ,@spname sysname
            ,@cmd nvarchar(4000)
            ,@conflicts_count int
            ,@lpublisher sysname
            ,@lpublisher_db sysname
            ,@owner sysname
            ,@publication sysname
            ,@fcheckpal bit
			,@fulltablename nvarchar(1000) --qualified with owner
			,@options int = 0
			,@art_objid int = 0

    declare @result_list table ( article nvarchar(256) collate database_default, conflict_table sysname collate database_default null,  
        centralized_conflicts bit, conflict_count integer)
    create table #conflict_list ( artid sysname collate database_default, conflict_count int, sub_agent_id int )
    --
    -- Decide if we need PAL security check - If sysadmin or dbo - skip PAL check
    --
    select @fcheckpal = case when  ((is_srvrolemember('sysadmin') = 1) or (is_member ('db_owner') = 1)) 
                                               then 0 else 1 end
    --
    -- initialize
    --
    if ( @publication_name = '%' )
        select @publication_name = NULL
    if ( @publisher = '%' )
        select @publisher = NULL
    if ( @publisher_db = '%' )
        select @publisher_db = NULL
    -- 
    -- process publisher
    --
    if ( object_id('dbo.sysarticles') is not null)
    begin
        --
        -- Walk through each publication that allows queued or p2p operation
        --
        declare #hCPubCursor CURSOR LOCAL FAST_FORWARD for
            select name, pubid, centralized_conflicts, options
            from syspublications
            where ((allow_queued_tran = 1) or (options &0x8 = 0x8))
                and name = isnull(@publication_name, name)
                and db_name() = isnull(@publisher_db, db_name())
                and upper(publishingservername()) = upper(isnull(@publisher, publishingservername()))

        open #hCPubCursor
        fetch #hCPubCursor into @publication, @pubid, @centralized_conflicts, @options
        while ( @@fetch_status != -1 )
        begin
            --
            -- do PAL check if necessary and proceed if it passes
            --
            if (@fcheckpal = 1)
            begin
                --
                -- need to do PAL check for the publication
                --
                exec @retcode = sp_MSreplcheck_pull
                        @publication = @publication,
                        @raise_fatal_error = 0
                 if (@@error != 0) or (@retcode != 0)
                 begin
                    --
                    -- do not have access to this publication
                    -- fetch next publication and continue
                    -- 
                    fetch #hCPubCursor into @publication, @pubid, @centralized_conflicts
                    continue
                 end
            end
            --
            -- Walk through each article in this publication
            --
            declare #hCArtCursor CURSOR LOCAL FAST_FORWARD for
                select a.name, b.conflict_tableid, a.artid, a.objid, quotename(object_name(a.objid))
                from sysarticles a 
						 left join sysarticleupdates b on
                        a.artid = b.artid and
                        a.pubid = b.pubid
                where a.pubid = @pubid

            open #hCArtCursor
            fetch #hCArtCursor into @article, @cft_tabid, @artid, @art_objid, @quotedtablename
            while ( @@fetch_status != -1 )
            begin
				select @owner = QUOTENAME(schema_name(objectproperty(@art_objid, 'SchemaId')))

				--queued and p2p cannot coexists
				if (@options & 0x8 = 0)
				begin
					--
					-- get the owner qualified conflict table name
					--
					select @spname = 'sp_MSgettrancftsrcrow'
					select @conflict_table = QUOTENAME(schema_name(objectproperty(@cft_tabid, 'SchemaId'))) + N'.' + QUOTENAME(OBJECT_NAME(@cft_tabid))
					--
					-- Get all the conflict counts
					--
					select @cmd = 'select ' + cast(@artid as nvarchar(10)) +  
					    ', count(*) from ' + @conflict_table + 
					    ' where conflict_type in (1, 5, 7) and pubid = ' + 
					    cast(@pubid as nvarchar(10))
				end
				else
				begin
					exec sp_MSgetpeerconflictname @prefix=N'conflict', @tabid=@art_objid, @peerconflictname=@conflict_table output
					if @@error <> 0
						select @conflict_table = NULL
					select @conflict_table = N'[dbo].' + QUOTENAME(@conflict_table)

					--
					-- Get all the conflict counts
					--
					select @cmd = 'select ' + cast(@artid as nvarchar(10)) +  
					    ', count(*) from ' + @conflict_table + 
					    ' where __$is_winner = 0 '

				    select @spname = 'sp_MSgetpeerwinnerrow'
				end

                insert into #conflict_list ( artid, conflict_count )
                    exec ( @cmd )

                select @conflicts_count = isnull(conflict_count, 0)
                from #conflict_list
                where artid = @artid
                
                if (@conflicts_count > 0)
                begin
                    --
                    -- add a row to the #result_list
                    --
                    insert into @result_list ( article, conflict_table, centralized_conflicts, conflict_count )
                        select isnull(@owner + N'.', '') + @quotedtablename, @conflict_table, @centralized_conflicts, @conflicts_count
                end
                --
                -- fetch next row from hCArtCursor
                --
                fetch #hCArtCursor into @article, @cft_tabid, @artid, @art_objid, @quotedtablename
            end
            close #hCArtCursor
            deallocate #hCArtCursor
            --
            -- fetch next row from hCPubCursor
            --
            fetch #hCPubCursor into @publication, @pubid, @centralized_conflicts, @options
        end
        close #hCPubCursor
        deallocate #hCPubCursor
    end
    --
    -- process subscriber side
    --
    delete #conflict_list
    if ( object_id('dbo.MSsubscription_articles') is not null)
    begin
        --
        -- Walk through each subscription that allows queued operation
        --
        declare #hCPubCursor CURSOR LOCAL FAST_FORWARD for
            select id, 0, publisher, publisher_db, publication 
            from MSsubscription_agents 
            where update_mode in (2,3,4,5)
                and upper(publisher) = upper(isnull(@publisher, publisher))
                and publisher_db = isnull(@publisher_db, publisher_db)
                and publication = isnull(@publication_name, publication)

        open #hCPubCursor
        fetch #hCPubCursor into @pubid, @centralized_conflicts, @lpublisher, @lpublisher_db, @publication
        while ( @@fetch_status != -1 )
        begin
            --
            -- do PAL check if necessary and proceed if it passes
            --
            if (@fcheckpal = 1)
            begin
                --
                -- need to do PAL check for the publication
                --
                exec @retcode = sp_MSreplcheck_pull
                        @publication = @publication,
                        @raise_fatal_error = 0
                 if (@@error != 0) or (@retcode != 0)
                 begin
                    --
                    -- do not have access to this publication
                    -- fetch next publication and continue
                    -- 
                    fetch #hCPubCursor into @pubid, @centralized_conflicts, @lpublisher, @lpublisher_db, @publication
                    continue
                 end
            end
            --
            -- Walk through each article in this subscribed publication
            --
            declare #hCArtCursor CURSOR LOCAL FAST_FORWARD for
                select a.article, OBJECT_ID(a.cft_table), a.artid
                from MSsubscription_articles a join
                    MSsubscription_agents b on
                        a.agent_id = b.id
                where b.id = @pubid

            open #hCArtCursor
            fetch #hCArtCursor into @article, @cft_tabid, @artid
            while ( @@fetch_status != -1 )
            begin
                --
                -- get the owner qualified conflict table name
                --
                select @owner = QUOTENAME(schema_name(OBJECTPROPERTY(@cft_tabid, 'SchemaId')))
                select @conflict_table = @owner + N'.' + QUOTENAME(OBJECT_NAME(@cft_tabid))
                --
                -- Get all the conflict counts
                --
                select @cmd = 'select ' + cast(@artid as nvarchar(10)) +  
                    ', count(*), ' + cast(@pubid as nvarchar(10)) + 
                    ' from ' + @conflict_table + 
                    ' where conflict_type in (1, 5, 7) 
                        and origin_datasource = ' + QUOTENAME((@lpublisher + '.'  + @lpublisher_db), '''')
                    
                insert into #conflict_list ( artid, conflict_count, sub_agent_id )
                    exec ( @cmd )

                select @conflicts_count = isnull(conflict_count, 0)
                from #conflict_list
                where artid = @artid and sub_agent_id = @pubid
                
                if (@conflicts_count > 0)
                begin
                    --
                    -- add a row to the #result_list
                    --
                    insert into @result_list ( article, conflict_table, centralized_conflicts, conflict_count )
                        select @owner + N'.' + QUOTENAME(@article), @conflict_table, @centralized_conflicts, @conflicts_count
                end
                --
                -- fetch next row from hCArtCursor
                --
                fetch #hCArtCursor into @article, @cft_tabid, @artid
            end
            close #hCArtCursor
            deallocate #hCArtCursor
            --
            -- fetch next row from hCPubCursor
            --
            fetch #hCPubCursor into @pubid, @centralized_conflicts, @lpublisher, @lpublisher_db, @publication
        end
        close #hCPubCursor
        deallocate #hCPubCursor
    end
    --
    -- do a select for results
    --
    select  article,
            conflict_table,
            'source_proc' = @spname,
            centralized_conflicts,
            conflict_count
    from @result_list
    --
    -- all done
    --
    return (0)
end
GO
GRANT EXECUTE ON [sys].[sp_MShelptranconflictcounts] TO [public] AS [dbo]
GO
