SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSmakearticleprocs]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSmakearticleprocs] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSmakearticleprocs]
	@pubid [uniqueidentifier],
	@artid [uniqueidentifier],
	@recreate_conflict_proc [bit]
WITH EXECUTE AS CALLER
AS
declare @ownername      sysname
    declare @objectname     sysname
    declare @ins_procname   sysname
    declare @sel_procname   sysname
    declare @sel_metadata_procname sysname
    declare @upd_procname   sysname
    declare @del_procname   sysname
    declare @ins_batch_procname sysname
    declare @upd_batch_procname sysname
    declare @trigname       sysname
    declare @objid          int
    declare @dbname         sysname
    declare @command        nvarchar(1000)
    declare @article        sysname
    declare @sync_objid     int
    declare @conflict_proc sysname
    
    -- to be called after article is set up in a subscriber
    declare @retcode smallint
    declare @procsuffix nvarchar(100)
    declare @isheavyweight bit

    /*
    ** Check for subscribing permission
    */
    exec @retcode=sys.sp_MSreplcheck_subscribe
    if @retcode<>0 or @@ERROR<>0 return (1)

    select @objid = max(objid) from dbo.sysmergearticles where artid = @artid
    -- get owner name, and table name
    select @objectname = name, @ownername = SCHEMA_NAME(schema_id)
        from sys.objects where object_id = @objid

    -- get the  insert and update proc names from sys articles
    select @article = name, @ins_procname = insert_proc, @upd_procname = update_proc, @sel_procname = select_proc,
        @sel_metadata_procname = metadata_select_proc, @del_procname = delete_proc
        from dbo.sysmergearticles where pubid = @pubid and artid = @artid


    if exists (select * from dbo.sysmergesubscriptions 
           where pubid=@pubid and subscription_type = 3 -- lightweight subscription
                and pubid in (select pubid from dbo.sysmergearticles 
                                    where name=@article and lightweight=1)) 
    begin
        set @isheavyweight = 0
    end
    else
    begin
        set @isheavyweight = 1
    end

    -- @isheavyweight should now be either 0 or 1.
    if @isheavyweight IS NULL
    BEGIN
        RAISERROR (21055, 16, -1, '@pubid', 'sp_MSmakeartprocs')
        RETURN (1)
    END

    -- drop the ins/upd/sel procs which have names like sp_ins_*
    select @procsuffix = sys.fn_MSmerge_getartprocsuffix(@artid, @pubid)

    if 1=@isheavyweight
    begin
		--
		-- Potential SQL trunction if we don't check the proc name here.  122 = sizeof(sysname) - LEN('_BATCH') 
		--
		if LEN(@ins_procname) > 122 OR LEN(@upd_procname) > 122
		begin
			goto FAILURE
		end

        select @ins_batch_procname =  @ins_procname + '_batch'
        select @upd_batch_procname =  @upd_procname + '_batch'
        
        if object_id(@ins_procname) is not NULL
        begin
            select @command = 'drop proc ' + quotename(@ins_procname)
            exec (@command)
            if @@ERROR<>0 
                return (1)
        end

        if object_id(@ins_batch_procname) is not NULL
        begin
            select @command = 'drop proc ' + quotename(@ins_batch_procname)
            exec (@command)
            if @@ERROR<>0 
                goto FAILURE
        end

        if object_id(@upd_procname) is not NULL
        begin
            select @command = 'drop proc ' + quotename(@upd_procname)
            exec (@command)
            if @@ERROR<>0
                goto FAILURE
        end

        if object_id(@upd_batch_procname) is not NULL
        begin
            select @command = 'drop proc ' + quotename(@upd_batch_procname)
            exec (@command)
            if @@ERROR<>0 
                goto FAILURE
        end

        if object_id(@sel_procname) is not NULL
        begin
            select @command = 'drop proc ' + quotename(@sel_procname)
            exec (@command)
            if @@ERROR<>0
                goto FAILURE
        end

        -- the following is needed because we are not gettting values for these from sp_MShelpmergearticles and
        -- hence for the first time when this proc is called on the subscriber these will be NULL
        if @sel_metadata_procname is NULL
            select @sel_metadata_procname = 'MSmerge_sel_sp_' + @procsuffix + '_metadata'

        if @del_procname is NULL
            select @del_procname = 'MSmerge_del_sp_' + @procsuffix 

        if @recreate_conflict_proc = 1
        begin
            if @conflict_proc is NULL
                select @conflict_proc = 'MSmerge_cft_sp_' + @procsuffix
        end
        else
            select @conflict_proc = NULL
            
        if object_id(@sel_metadata_procname) is not NULL
        begin
            select @command = 'drop proc ' + quotename(@sel_metadata_procname)
            exec (@command)
            if @@ERROR<>0
                goto FAILURE
        end

        if object_id(@del_procname) is not NULL
        begin
            select @command = 'drop proc ' + quotename(@del_procname)
            exec (@command)
            if @@ERROR<>0
                goto FAILURE
        end

        if object_id(@conflict_proc) is not NULL
        begin
            select @command = 'drop proc ' + quotename(@conflict_proc)
            exec (@command)
            if @@ERROR<>0
                goto FAILURE
        end

        -- Don't generate the batch insert and update procs if the article has a xml
        -- column. XML column needs streaming and we don't do batch updates and inserts when we have
        -- to do streaming.
        select @sync_objid = sync_objid from dbo.sysmergearticles where artid = @artid and pubid=@pubid
        if exists (select * from sys.columns where object_id = @sync_objid and system_type_id = 241) 
        begin   
            select @ins_batch_procname = NULL
            select @upd_batch_procname = NULL
        end
             
        -- create the procs passing in the proc names
        exec @retcode=sys.sp_MScreateandsetarticleprocs
                    @pubid = @pubid,
                    @artid = @artid,
                    @objectname = @objectname,
                    @ownername = @ownername,
                    @ins_procname = @ins_procname,
                    @ins_batch_procname = @ins_batch_procname,
                    @upd_procname = @upd_procname,
                    @upd_batch_procname     = @upd_batch_procname,
                    @sel_procname = @sel_procname,
                    @del_procname = @del_procname,
                    @sel_metadata_procname = @sel_metadata_procname,
                    @view_selprocname = NULL,
                    @conflict_proc = @conflict_proc,
                    @generate_downlevel_procs = 0
        if @retcode<>0 or @@ERROR<>0 goto FAILURE
    end -- 1=@isheavyweight
    else
    begin
        select @conflict_proc = 'MSmerge_cft_sp_' + @procsuffix
        
        exec @retcode= sys.sp_MSdroplightweightarticleprocs @pubid=@pubid, @artid=@artid
        if @@error<>0 or @retcode<>0 goto FAILURE

        exec @retcode= sys.sp_MScreatelightweightarticleprocs @pubid=@pubid, @artid=@artid, @conflict_proc= @conflict_proc
        if @@error<>0 or @retcode<>0 goto FAILURE
    end

    return (0)

FAILURE:
    RAISERROR(20636, 16, -1, @article)
    return 1
    
GO
GRANT EXECUTE ON [sys].[sp_MSmakearticleprocs] TO [public] AS [dbo]
GO
