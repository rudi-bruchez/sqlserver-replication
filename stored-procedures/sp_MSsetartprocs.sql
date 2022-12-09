SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSsetartprocs]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSsetartprocs] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSsetartprocs]
	@publication [sysname],
	@article [sysname],
	@force_flag [int],
	@pubid [uniqueidentifier]
WITH EXECUTE AS CALLER
AS
declare @ownername sysname
    declare @objectname sysname
    declare @conflict_proc sysname
    declare @conflict_table sysname
    declare @snapshot_ready int
    declare @ins_procname sysname
    declare @sel_procname sysname
    declare @del_procname sysname
    declare @sel_metadata_procname sysname
    declare @upd_procname sysname
    declare @ins_batch_procname sysname
    declare @upd_batch_procname sysname
    declare @view_selprocname nvarchar(290)
    declare @viewname sysname
    declare @artid uniqueidentifier
    declare @objid int
    declare @retcode smallint
    declare @dbname sysname
    declare @generate_downlevel_procs bit

    declare @procsuffix nvarchar(100)
    declare @sync_objid int
    declare @qual_conflict_table nvarchar(300)

 
    set nocount on
    /*
    ** Check to see if current publication has permission
    */
    exec @retcode=sys.sp_MSreplcheck_publish
    if @retcode<>0 or @@ERROR<>0 return (1)
    
    if object_id('sysmergepublications') is NULL
    begin
        RAISERROR(20054 , 16, -1)
        return (1)
    end
    
    if @pubid is NULL
    begin
        if @force_flag = 1
        begin
            -- don't qualify that must be publisher when we are forcing remake at subscribers
            select @pubid = pubid, @snapshot_ready=snapshot_ready 
                from dbo.sysmergepublications 
                where name = @publication and 
                pubid in (select pubid from dbo.sysmergearticles where name=@article)
        end
        else
        begin
            select @pubid = pubid, @snapshot_ready=snapshot_ready 
                from dbo.sysmergepublications 
                where name = @publication and 
                upper(publisher collate SQL_Latin1_General_CP1_CS_AS) = upper(publishingservername() collate SQL_Latin1_General_CP1_CS_AS) and 
                publisher_db=db_name()
        end
    end
    else
    begin
        select @snapshot_ready=snapshot_ready 
            from dbo.sysmergepublications 
            where pubid = @pubid
    end

    select @artid= artid, @objid = objid, @conflict_table= conflict_table
            FROM dbo.sysmergearticles WHERE name = @article AND pubid = @pubid

    if @artid IS NULL
    BEGIN
        RAISERROR (20027, 16, -1, @article)
        RETURN (1)
    END

    select @generate_downlevel_procs = 0
    if (sys.fn_MSmerge_islocalpubid(@pubid) = 1)
    begin
        if exists (select 1 from dbo.sysmergepublications where pubid = @pubid and backward_comp_level<90)
            select @generate_downlevel_procs = 1
    end

    -- get owner name, and table name
    select @objectname = name, @ownername = SCHEMA_NAME(schema_id)  from sys.objects where object_id = @objid 

    select @procsuffix = sys.fn_MSmerge_getartprocsuffix(@artid, @pubid)

    -- Conflict insert proc is common to both regular and lightweight subscribers
    -- to be consistent with upgrade code by checking snapshot_ready>0
    select @qual_conflict_table = 'dbo.' + @conflict_table
    if @snapshot_ready>0 and @conflict_table is not NULL and object_id(@qual_conflict_table) is not NULL
        select @conflict_proc = 'MSmerge_cft_sp_' + @procsuffix
    else
        select @conflict_proc = NULL
        

    /* Drop the article procs if they preexist */
    exec @retcode = sys.sp_MSdroparticleprocs @pubid, @artid, 0 -- don't update proc names
    if @@ERROR<>0 OR @retcode<>0 goto FAILURE

    -- do this first. This is needed since we want to do the update of sysmergearticles at the end
    if @generate_downlevel_procs = 1
    begin
        declare @ins_procname_bc sysname
        declare @upd_procname_bc sysname
        declare @sel_procname_bc sysname

        /* Downlevel agents will use sp_ins_ prefix for the proc names */
        select @ins_procname_bc = 'sp_ins_' + @procsuffix
        select @upd_procname_bc = 'sp_upd_' + @procsuffix
        select @sel_procname_bc = 'sp_sel_' + @procsuffix

        exec @retcode=sys.sp_MScreateandsetarticleprocs
                @pubid = @pubid,
                @artid = @artid,
                @objectname = @objectname,
                @ownername = @ownername,
                @ins_procname = @ins_procname_bc,
                @ins_batch_procname = NULL,
                @upd_procname = @upd_procname_bc,
                @upd_batch_procname = NULL,
                @sel_procname = @sel_procname_bc,
                @del_procname = NULL,
                @sel_metadata_procname = NULL,
                @view_selprocname = NULL,
                @conflict_proc = NULL,
                @generate_downlevel_procs = 1,
                @update_symergearticles = 0
        if @retcode<>0 or @@ERROR<>0 goto FAILURE
    end

    select @ins_procname = 'MSmerge_ins_sp_' + @procsuffix
    select @upd_procname = 'MSmerge_upd_sp_' + @procsuffix

    -- Don't generate the batch insert and update procs if the article has a xml
    -- column. XML column needs streaming and we don't do batch updates and inserts when we have
    -- to do streaming.
    select @sync_objid = sync_objid from dbo.sysmergearticles where artid = @artid and pubid=@pubid
    select @ins_batch_procname = NULL
    select @upd_batch_procname = NULL
    if not exists (select * from sys.columns where object_id = @sync_objid and system_type_id = 241) 
    begin
       select @ins_batch_procname = @ins_procname + '_batch'
       select @upd_batch_procname = @upd_procname + '_batch'
    end

    select @sel_procname = 'MSmerge_sel_sp_' + @procsuffix
    select @del_procname = 'MSmerge_del_sp_' + @procsuffix
    select @sel_metadata_procname = 'MSmerge_sel_sp_' + @procsuffix + '_metadata'
    set @view_selprocname = 'MSmerge_sel_' + @procsuffix

    -- create the procs passing in the proc names
    exec @retcode=sys.sp_MScreateandsetarticleprocs
            @pubid = @pubid,
            @artid = @artid,
            @objectname = @objectname,
            @ownername = @ownername,
            @ins_procname = @ins_procname,
            @ins_batch_procname     = @ins_batch_procname,
            @upd_procname = @upd_procname,
            @upd_batch_procname     = @upd_batch_procname,
            @sel_procname = @sel_procname,
            @del_procname = @del_procname,
            @sel_metadata_procname = @sel_metadata_procname,
            @view_selprocname = @view_selprocname,
            @conflict_proc = @conflict_proc,
            @generate_downlevel_procs = 0
    if @retcode<>0 or @@ERROR<>0 goto FAILURE


    return 0

FAILURE:
    RAISERROR(20636, 16, -1, @article)
    return 1
    
GO
GRANT EXECUTE ON [sys].[sp_MSsetartprocs] TO [public] AS [dbo]
GO
