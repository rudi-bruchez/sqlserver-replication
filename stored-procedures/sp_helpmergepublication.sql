SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_helpmergepublication]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_helpmergepublication] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_helpmergepublication]
	@publication [sysname],
	@found [int] OUTPUT,
	@publication_id [uniqueidentifier] OUTPUT,
	@reserved [nvarchar](20),
	@publisher [sysname],
	@publisher_db [sysname]
WITH EXECUTE AS CALLER
AS
declare @retcode int
    
    -- Security check
    exec @retcode= sys.sp_MSrepl_PAL_rolecheck
    if @retcode<>0 or @@error<>0 
        return 1

    -- fix the pal role for the publication. Calling this proc will do nothing if the 
    -- pal role already exists. Do this only if the current user calling this is a dbo 
    -- and tran count is = 0. We need to call this here because the snapshot agent calls
    -- this proc as the first thing. Before the snapshot can call sp_MSpublicationview
    -- we need the pal role to be present.
    if (@publication is not NULL) and (@publication <> '%') and (@reserved = N'fromSnapshot') and (is_member('db_owner') = 1) and (@@trancount = 0) 
    begin
        declare @role sysname
        declare @pubid uniqueidentifier

        if object_id('sysmergepublications') is not NULL
        begin
            select @pubid = pubid from dbo.sysmergepublications 
                where UPPER(publisher)=UPPER(publishingservername()) and publisher_db=db_name() and name = @publication
            if @pubid is not NULL
            begin        
                exec @retcode = sys.sp_MSrepl_FixPALRole @pubid, @role output
                if (@role is NULL or @retcode <> 0 or @@error <> 0)
                begin
                    -- add appropriate error message here
                    return 1
                end

                -- we also need to fix the pal role for other publications as well
                
                declare @pubidother uniqueidentifier
                declare pubs_cursor cursor LOCAL FAST_FORWARD
                for select pubid from dbo.sysmergepublications
                        where pubid <> @pubid 
                            and LOWER(publisher)  collate database_default = LOWER(publishingservername()) collate database_default 
                            and publisher_db = DB_NAME()
                
                for read only
                
                open pubs_cursor
                fetch pubs_cursor into @pubidother
                while (@@fetch_status <> -1)
                begin
                    exec @retcode = sys.sp_MSrepl_FixPALRole @pubidother, @role output
                    if (@role is NULL or @retcode <> 0 or @@error <> 0)
                    begin
                        return 1
                    end
                    fetch pubs_cursor into @pubidother
                end
                close pubs_cursor
                deallocate pubs_cursor
            end
        end
        -- do upgrade here if MSmerge_upgrade_in_progress table is present
        if object_id('MSmerge_upgrade_in_progress', 'U') is not NULL
        begin
            exec sys.sp_MScreate_all_article_repl_views
            if @@error <> 0
                return 1
        
            exec @retcode = sys.sp_MSmerge_autoident_upgrade
            if @retcode<>0 or @@error<>0
                return 1

            exec @retcode = sys.sp_MSmerge_metadataupgrade
            if @retcode<>0 or @@error<>0
                return 1

            exec @retcode = sys.sp_MSmerge_upgrade_subscriber @upgrade_metadata = 0
            if @retcode<>0 or @@error<>0
                return 1

            -- sp_MSmerge_upgrade_subscriber may have dropped this table so check again
            if object_id('MSmerge_upgrade_in_progress', 'U') is not NULL
            begin
                drop table dbo.MSmerge_upgrade_in_progress
            end
        end
    end


    -- When the merge agent calls sp_helpmergepublication on the publisher connection,
    -- we don't need row numbers and also don't need some other code that is in 
    -- sp_MShelpmergepub_withrownumbers. With multiple concurrent merge agents calling
    -- sp_helpmergepublication, sp_MShelpmergepub_withrownumbers can perform poorly 
    -- due to its use of temp table or table variable. Server is going to add RANK which
    -- will later allow us to combine these 2 procs into one. For the time being we need
    -- to call the faster sp_MShelpmergepub_withoutrownumbers if being called from the 
    -- merge agent.
    if 1 = sessionproperty('replication_agent') -- leave this here; it is not for security reasons!
        and @found is null
        and @publication_id is null
        and (@reserved is null or @reserved = 'internal')
        --and @publisher is null
        --and @publisher_db is null
    begin
        exec @retcode = sp_MShelpmergepub_withoutrownumbers 
                            @publication, @publisher, @publisher_db
    end
    else
    begin
        exec @retcode = sp_MShelpmergepub_withrownumbers 
                            @publication,
                            @found OUTPUT,
                            @publication_id OUTPUT,	
                            @reserved, 
                            @publisher, 
                            @publisher_db
    end

    return @retcode
GO
GRANT EXECUTE ON [sys].[sp_helpmergepublication] TO [public] AS [dbo]
GO
