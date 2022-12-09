SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_dropmergearticle]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_dropmergearticle] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_dropmergearticle]
	@publication [sysname],
	@article [sysname],
	@ignore_distributor [bit],
	@reserved [bit],
	@force_invalidate_snapshot [bit],
	@force_reinit_subscription [bit],
	@ignore_merge_metadata [bit]
WITH EXECUTE AS CALLER
AS
set nocount on

    declare @artid                    uniqueidentifier
    declare @snapshot_ready            int
    declare @objid                    int
    declare @pubid                    uniqueidentifier
    declare @pubidstr                nvarchar(38)
    declare @retcode                int
    declare @qualified_name            nvarchar(270)
    declare @filterid                int
    declare @proc_name                sysname
    declare @implicit_transaction    int
    declare @close_cursor_at_commit int
    declare @sync_objid        int
    declare @view_type        int
    declare @type            tinyint
    declare @compatlevel int
    declare @SCHEMA_TYPE_DROPARTICLE int
    declare @automatic_reinitialization_policy bit
    declare @got_merge_admin_applock bit

    select @got_merge_admin_applock = 0
    
    select @close_cursor_at_commit = 0
    select @implicit_transaction = 0
    set @SCHEMA_TYPE_DROPARTICLE= 28
    /*
    ** Save setting values first before changing them
    */
    IF (@reserved = 0)
    BEGIN
        SELECT @implicit_transaction = @@options & 2
        SELECT @close_cursor_at_commit = @@options & 4
        SET IMPLICIT_TRANSACTIONS OFF
        SET CURSOR_CLOSE_ON_COMMIT OFF
    END
    
    /*
    ** Security Check
    */
    EXEC @retcode = sys.sp_MSreplcheck_publish
    IF @@ERROR <> 0 or @retcode <> 0
        return (1)

    /* make sure current database is enabled for merge replication */
    exec @retcode=sys.sp_MSCheckmergereplication
    if @@ERROR<>0 or @retcode<>0
        return (1)
        
    select @pubid = pubid, 
           @snapshot_ready=snapshot_ready, 
           @compatlevel = backward_comp_level,
           @automatic_reinitialization_policy = automatic_reinitialization_policy
        FROM dbo.sysmergepublications 
        WHERE name = @publication  and UPPER(publisher)=UPPER(publishingservername()) and publisher_db=db_name()
    if @pubid is NULL
    BEGIN
        RAISERROR (20026, 16, -1, @publication)
        RETURN (1)
    END

    if @snapshot_ready>0
    begin
        if @force_invalidate_snapshot = 0 and @snapshot_ready = 1
            begin
                raiserror(21379, 16, -1, @article, @publication)
                return (1)
            end
        update dbo.sysmergepublications set snapshot_ready=2 where pubid=@pubid
        if @@ERROR<>0
            return (1)
    end
    
    set @pubidstr = '''' + convert(nchar(36), @pubid) + ''''

    /*
    ** Parameter Check:     @article.
    ** If the @article is 'all', drop all articles for the specified
    ** publication (@publication).
    */
    if LOWER(@article) = 'all'
    BEGIN
        declare hC CURSOR LOCAL FAST_FORWARD FOR select DISTINCT name FROM dbo.sysmergeextendedarticlesview WHERE pubid=@pubid FOR READ ONLY
        
        OPEN hC
        FETCH hC INTO @article
        WHILE (@@fetch_status <> -1)
            BEGIN
                EXECUTE sys.sp_dropmergearticle @publication, @article,
                    @ignore_distributor = @ignore_distributor,
                    @reserved = 1, @ignore_merge_metadata = @ignore_merge_metadata
                FETCH hC INTO @article
            END
        CLOSE hC
        DEALLOCATE hC
        RETURN (0)
    END

    /*
    ** Parameter Check: @article.
    ** The @article name must conform to the rules for identifiers.
    */

    if @article IS NULL
    BEGIN
        RAISERROR (14043, 16, -1, '@article', 'sp_dropmergearticle')
        RETURN (1)
    END

    /*
    ** Parameter Check: @publication.
    ** The @publication name must conform to the rules for identifiers.
    */

    if @publication IS NULL
    BEGIN
        RAISERROR (14043, 16, -1, '@publication', 'sp_dropmergearticle')
        RETURN (1)
    END

    /*
    ** Ascertain the existence of the article.
    */
    select @type = NULL
    select @type = type ,
            @artid = artid,
            @objid = objid
      from dbo.sysmergeextendedarticlesview 
     where name = @article
       and pubid = @pubid
    if @type is NULL
    begin
        raiserror (20027, 16, -1, @article)
        return (1)
    end

    -- if all articles are to be dropped, ignore this checking.
    if @reserved=0 and exists (select * from dbo.sysmergesubsetfilters where pubid=@pubid and join_articlename=@article)
    begin
        raiserror(21421, 16, -1, @article)
        return (1)
    end

    -- if it is a table article and the publication could have down level subscribers do not allow the drop
    if (@compatlevel < 90) and @reserved = 0 and
       exists (select * from dbo.sysmergesubscriptions where pubid=@pubid and subid<>pubid and status=1) and
       not exists (select * from dbo.sysmergeschemaarticles where pubid = @pubid and name = @article)
    begin
        RAISERROR (21338, 16, -1, @article, @publication)
        RETURN (1)        
    end

    /*
    **    Delete article from dbo.sysmergearticles and clear publish bit in
    **    sys.objects.
    */

    begin tran 
    save TRAN dropmergearticle
    
        exec @retcode = sys.sp_MSgetmergeadminapplock @timeout = 0, -- no wait
                                                      @lockowner = N'Transaction'
        if @retcode<>0 or @@error<>0
        begin
            raiserror(20713, 16, -1, 'sp_dropmergearticle', @publication)
            goto FAILURE
        end

        select @got_merge_admin_applock = 1

        
        exec @retcode = sys.sp_MSdropmergearticle @pubid, @artid, @ignore_merge_metadata
        if @@ERROR <> 0 or @retcode <> 0
            goto FAILURE

        if @compatlevel >= 90
        begin
            -- post a schema change to drop the article on the subscriber
            declare @schemaversion int 
            declare @schemaguid uniqueidentifier
            declare @schematype int
            declare @schematext nvarchar(2000)
            declare @artidstr nvarchar(38)
            
            set @artidstr = '''' + convert(nchar(36), @artid) + ''''
           
            set @schemaguid = newid()
            -- in this schemachange perform article cleanup and drop the article as well if this is not a republisher
            -- put in SCHEMA_TYPE_DROPARTICLE
            set @schemaguid = newid()
            set @schematype = @SCHEMA_TYPE_DROPARTICLE 
            select @schematext = 'exec sp_MSdropmergearticle ' + @pubidstr + ', ' + @artidstr
            select @schemaversion = 1 + max(schemaversion) from dbo.sysmergeschemachange
            if @schemaversion is NULL
                select @schemaversion = 1
            exec @retcode=sys.sp_MSinsertschemachange @pubid, @artid, @schemaversion, @schemaguid, @schematype, @schematext
            if @@ERROR<>0 or @retcode<>0 goto FAILURE     
        end
        
        /*
        ** set the pub type to subset or full as appropriate
        */
        execute @retcode = sys.sp_MSsubsetpublication @publication
        if @@ERROR <> 0 or @retcode <> 0 
            goto FAILURE

        if @reserved=0
        begin
            -- now check if after this article has been removed the publication is still dynamically
            -- filtered if it was dynamically filtered before
            -- this is a lot of computation but I don't see a better way to do this
            declare @can_use_partition_groups bit
            declare @has_dynamic_filters bit 
            declare @dynamic_filters_function_list nvarchar(500) 
            declare @validate_subscriber_info nvarchar(500) 
            declare @uses_host_name bit 
            declare @uses_suser_sname bit 
            declare @dont_raise_error bit 
            declare @dynamic_filters bit
            declare @use_partition_groups smallint
            declare @partid_eval_proc nvarchar(258)

            select @dont_raise_error = 1
            select @dynamic_filters = dynamic_filters, 
                   @use_partition_groups = use_partition_groups, 
                   @partid_eval_proc = quotename(partition_id_eval_proc)
                from dbo.sysmergepublications where pubid = @pubid
                
            exec @retcode = sys.sp_MScheck_dynamic_filters @publication,
                                            @can_use_partition_groups output,
                                            @has_dynamic_filters output,
                                            @dynamic_filters_function_list output,
                                            @validate_subscriber_info output,
                                            @uses_host_name output,
                                            @uses_suser_sname output,
                                            @dont_raise_error
            if @@error<>0 or @retcode<>0
                goto FAILURE
                
            if @dynamic_filters = 1 and @has_dynamic_filters = 0
            begin
                if exists (select * from dbo.sysmergesubscriptions where pubid=@pubid and subid<>pubid and (status=1 or status=6))
                begin
                    if @force_reinit_subscription = 0
                    begin
                        raiserror(20697, 16, -1, @article, @publication)
                        goto FAILURE
                    end
                    else
                    begin
                        -- reinit all subscriptions
                        exec @retcode = sys.sp_MSreinitmergepublication 
                                                @publication = @publication,
                                                @upload_first = @automatic_reinitialization_policy
                                                
                        if @retcode<>0 or @@ERROR<>0
                            goto FAILURE
                    end
                end
                
                update dbo.sysmergepublications 
                    set dynamic_filters = 0, dynamic_filters_function_list = NULL
                    where pubid = @pubid
                if @@error<>0
                    goto FAILURE

                -- delete all schemachanges except for the ones just added.
                delete from dbo.sysmergeschemachange where pubid = @pubid and schematype not in (@SCHEMA_TYPE_DROPARTICLE)
                if @@error<>0
                    goto FAILURE
            end

            if @use_partition_groups in (1,2) and @can_use_partition_groups = 0
            begin
                if (object_id(@partid_eval_proc) is not NULL)
                begin
                    exec ('drop procedure ' + @partid_eval_proc)
                end
                update dbo.sysmergepublications 
                    set use_partition_groups = NULL,
                        partition_id_eval_proc = NULL
                        where pubid = @pubid
            end
        end
    
    exec sys.sp_MSreleasemergeadminapplock @lockowner = N'Transaction'
    COMMIT TRAN

    /*
    ** Set back original settings
    */    
    IF @reserved = 0
    BEGIN
        IF @implicit_transaction <>0 
            SET IMPLICIT_TRANSACTIONS ON
        IF @close_cursor_at_commit <>0 
            SET CURSOR_CLOSE_ON_COMMIT ON
    END
    
    RETURN (0)
FAILURE:
    RAISERROR (14047, 16, -1, @article)
    if @@TRANCOUNT > 0
    begin
        if @got_merge_admin_applock=1
            exec sys.sp_MSreleasemergeadminapplock @lockowner = N'Transaction'
        ROLLBACK TRANSACTION dropmergearticle
        COMMIT TRANSACTION
    end
    /*
    ** Set back original settings
    */    
    IF @reserved = 0
    BEGIN
        IF @implicit_transaction <>0 
            SET IMPLICIT_TRANSACTIONS ON
        IF @close_cursor_at_commit <>0 
            SET CURSOR_CLOSE_ON_COMMIT ON
    END
    RETURN (1)
GO
GRANT EXECUTE ON [sys].[sp_dropmergearticle] TO [public] AS [dbo]
GO
