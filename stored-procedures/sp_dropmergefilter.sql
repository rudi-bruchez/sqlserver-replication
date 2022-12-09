SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_dropmergefilter]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_dropmergefilter] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_dropmergefilter]
	@publication [sysname],
	@article [sysname],
	@filtername [sysname],
	@force_invalidate_snapshot [bit],
	@force_reinit_subscription [bit]
WITH EXECUTE AS CALLER
AS
set nocount on

    declare @pubid                  uniqueidentifier                
    declare @artid                  uniqueidentifier
    declare @join_objid             int
    declare @retcode                int
    declare @join_filterid          int
    declare @db_name                sysname
    declare @allow_anonymous        int
    declare @snapshot_ready         tinyint
    declare @filter_type            tinyint
    declare @procname nvarchar(260)
	declare @quoted_procname nvarchar(260)
    declare @compatlevel int
    declare @automatic_reinitialization_policy bit
    declare @regenerate_triggers bit
    declare @got_merge_admin_applock bit

    select @got_merge_admin_applock = 0

    /* make sure current database is enabled for merge replication */
    exec @retcode=sys.sp_MSCheckmergereplication
    if @@ERROR<>0 or @retcode<>0
        return (1)

    /* 
    ** Security Check.
    */
    exec @retcode=sys.sp_MSreplcheck_publish
    if @@ERROR <> 0 or @retcode <> 0
        return (1)

    select @regenerate_triggers = 0
    /*
    ** Parameter Check: @publication.
    ** The @publication id cannot be NULL and must conform to the rules
    ** for identifiers.
    */

    if @publication is NULL
    begin
        raiserror (14003, 16, -1)
        return (1)
    end

    /*
    ** Get the pubid, and check if this publication exists.
    */
    select @pubid = pubid, 
           @snapshot_ready = snapshot_ready, 
           @allow_anonymous = allow_anonymous,
           @compatlevel = backward_comp_level,
           @automatic_reinitialization_policy = automatic_reinitialization_policy
        from dbo.sysmergepublications 
        where name = @publication and UPPER(publisher)=UPPER(publishingservername()) and publisher_db=db_name()
    if @pubid is NULL
    begin
        raiserror (20026, 16, -1, @publication )
        return (1)
    end

    select @db_name = db_name from dbo.sysmergesubscriptions
        where (pubid=@pubid) and (subid=@pubid) 
    IF @db_name <> db_name()
    BEGIN
        RAISERROR (20047, 16, -1)
        RETURN (1)
    END

    /*
    ** Parameter Check: @article.
    ** Check to see that the @article is valid, and if it exists
    */
    if @article is NULL
    begin
        raiserror (20045, 16, -1)
        return (1)
    end

    select @artid = artid from dbo.sysmergearticles where name = @article and pubid = @pubid  
    if @artid is NULL
    begin
        raiserror (20027, 16, -1, @article)
        return (1)
    end

    select @join_filterid = join_filterid, @filter_type = filter_type from dbo.sysmergesubsetfilters
        where pubid = @pubid AND artid= @artid AND filtername=@filtername  
    if @join_filterid is NULL
    begin
        raiserror (20685, 16, -1, @filtername)
        return (1)
    end

    begin tran
    save tran dropmergefilter
    
    exec @retcode = sys.sp_MSgetmergeadminapplock @timeout = 0, -- no wait
                                                  @lockowner = N'Transaction'
    if @retcode<>0 or @@error<>0
    begin
        raiserror(20713, 16, -1, 'sp_dropmergefilter', @publication)
        goto FAILURE            
    end

    select @got_merge_admin_applock = 1

    if @snapshot_ready>0
    begin
        if @force_invalidate_snapshot = 0 and @snapshot_ready = 1
        begin
            raiserror(21382, 16, -1, @filtername)
            goto FAILURE
        end
        select @regenerate_triggers = 1
        update dbo.sysmergepublications set snapshot_ready=2,
            use_partition_groups = case when use_partition_groups = 1 then 2 else use_partition_groups end
            where pubid=@pubid
        if @@ERROR<>0
            goto FAILURE
            
        /*
        if @filter_type & 2 = 2
        begin
            exec @retcode = sys.sp_MSreinitmergepublication 
                                    @publication = @publication,
                                    @upload_first = @automatic_reinitialization_policy
            if @retcode<>0 or @@ERROR<>0 goto FAILURE
        end
        */
    end

    if @snapshot_ready>0 and 
       ((@allow_anonymous = 1 and @compatlevel < 90) or 
         exists (select * from dbo.sysmergesubscriptions where pubid=@pubid and subid<>pubid and status=1))
    BEGIN
        if @force_reinit_subscription = 0
        begin
            RAISERROR (21372, 16, -1, @filtername, @publication)
            goto FAILURE
        end
        else
        begin
            exec @retcode = sys.sp_MSreinitmergepublication 
                                    @publication = @publication,
                                    @upload_first = @automatic_reinitialization_policy
            if @retcode<>0 or @@ERROR<>0 goto FAILURE
        end
    END

    -- remove the expand proc for this filter before deleting from sysmergesubsetfilters
    select @procname = quotename(expand_proc) from dbo.sysmergesubsetfilters where join_filterid = @join_filterid
    if @procname is not NULL
    begin
        exec ('drop proc ' + @procname)
    end

    --drop expand proc and nullify the expand_proc column in sysmergepartitioninfo 
    select @procname = expand_proc
    from dbo.sysmergepartitioninfo
    where pubid=@pubid 
            and artid = ( select top(1) art.artid from dbo.sysmergearticles art, dbo.sysmergesubsetfilters filter 
                                where art.name = filter.join_articlename and filter.pubid=@pubid and filter.artid=@artid)
    if @procname is not NULL
    begin
		select @quoted_procname = quotename(@procname)
        exec ('drop proc ' + @quoted_procname)                       
        update dbo.sysmergepartitioninfo 
        set expand_proc = null     
        where expand_proc = @procname
    end                                                      

    /*
    **    Remove the join filter from dbo.sysmergesubsetfilters
    */
    delete from dbo.sysmergesubsetfilters
        where join_filterid = @join_filterid
    if @@error <> 0
    begin
        goto FAILURE
    end

    /*
    ** set the pub type to subset or full as appropriate
    */
    exec @retcode=sys.sp_MSsubsetpublication @publication
    if @@ERROR <> 0 or @retcode<>0
    begin
        goto FAILURE
    end

    if (@regenerate_triggers = 1)
    begin
        exec @retcode = sys.sp_MSpublicationview @publication = @publication, @force_flag = 1
        if @@ERROR<>0 or @retcode <>0
            goto FAILURE

        exec @retcode = sp_MSregenerate_mergetriggers @publication = @publication
        if @@ERROR<>0 or @retcode<>0
            goto FAILURE
    end

    exec sys.sp_MSreleasemergeadminapplock @lockowner = N'Transaction'
    commit tran
    return(0)
    
FAILURE:
    if @got_merge_admin_applock=1
        exec sys.sp_MSreleasemergeadminapplock @lockowner = N'Transaction'
    rollback tran dropmergefilter
    commit tran
    RAISERROR (20039, 16, -1, @article, @publication)
    return (1)
GO
GRANT EXECUTE ON [sys].[sp_dropmergefilter] TO [public] AS [dbo]
GO
