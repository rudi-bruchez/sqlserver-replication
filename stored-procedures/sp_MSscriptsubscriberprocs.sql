SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSscriptsubscriberprocs]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSscriptsubscriberprocs] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSscriptsubscriberprocs]
	@publication [sysname],
	@article [sysname]
WITH EXECUTE AS CALLER
AS
declare @retcode        smallint
    declare @command        nvarchar(4000)
    declare @objid          int
    declare @objectname     sysname
    declare @ownername      nvarchar(140)
    declare @destowner      nvarchar(140)
    declare @procsuffix     sysname
    declare @ins_procname   sysname
    declare @ins_batch_procname sysname
    declare @upd_procname   sysname
    declare @upd_batch_procname sysname
    declare @sel_procname sysname
    declare @sel_metadata_procname sysname
    declare @del_procname sysname
    declare @conflict_proc sysname
    declare @recreateallprocs bit
    declare @pubid uniqueidentifier
    declare @artid uniqueidentifier
    declare @upload_options tinyint
    declare @conflict_table nvarchar(140)
    declare @generate_batch_procs bit
    declare @sync_objid int
    declare @script_conflict_proc bit

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

    select @pubid = pubid
        from dbo.sysmergepublications 
        where name = @publication and 
        upper(publisher collate SQL_Latin1_General_CP1_CS_AS) = upper(publishingservername() collate SQL_Latin1_General_CP1_CS_AS) and 
        publisher_db=db_name()
    if @pubid is NULL
    BEGIN
        RAISERROR (20026, 16, -1, @publication)
        RETURN (1)
    END

    select @artid= artid, @objid = objid, @destowner = destination_owner, 
           @upload_options = upload_options, @conflict_table = conflict_table,
           @sync_objid = sync_objid
            FROM dbo.sysmergearticles WHERE name = @article AND pubid = @pubid
    if @artid IS NULL
    BEGIN
        RAISERROR (20027, 16, -1, @article)
        RETURN (1)
    END

    -- Don't generate the batch insert and update procs if the article has a xml
    -- column. XML column needs streaming and we don't do batch updates and inserts when we have
    -- to do streaming.
    if exists (select * from sys.columns where object_id = @sync_objid and system_type_id = 241) 
        select @generate_batch_procs = 0
    else
        select @generate_batch_procs = 1

    select @ownername = schema_name(schema_id), @objectname=name from sys.objects where object_id=@objid
    if @objectname IS NULL
    BEGIN
        RAISERROR (20027, 16, -1, @article)
        RETURN (1)
    END
    
    select @procsuffix = sys.fn_MSmerge_getartprocsuffix(@artid, @pubid)

    if @ownername <> @destowner or (@upload_options = 1 or @upload_options = 2)
        select @recreateallprocs = 1
    else
        select @recreateallprocs = 0    

    -- In my initial perf testing I did not see much of a difference between calling sp_helptext and recreating the proc. Hence I am going
    -- to hard code this to call the proc creation procedures once more.
    select @recreateallprocs = 1
    
    select @command = '-- these are subscriber side procs
SET ANSI_NULLS ON
SET QUOTED_IDENTIFIER ON
'
    select @command

    select @ins_procname = 'MSmerge_ins_sp_' + @procsuffix
    select @ins_batch_procname = 'MSmerge_ins_sp_' + @procsuffix + '_batch'
    select @upd_procname = 'MSmerge_upd_sp_' + @procsuffix
    select @upd_batch_procname = 'MSmerge_upd_sp_' + @procsuffix + '_batch'
    select @del_procname = 'MSmerge_del_sp_' + @procsuffix
    select @sel_procname = 'MSmerge_sel_sp_' + @procsuffix 
    select @sel_metadata_procname = 'MSmerge_sel_sp_' + @procsuffix + '_metadata'
    select @conflict_proc = 'MSmerge_cft_sp_' + @procsuffix

    -- if the conflict proc exists script it. The conflict proc will not exist if the user 
    -- has chosen a creation script and the schema options are set to 0x00000.
    if object_id(@conflict_proc) is not NULL
        set @script_conflict_proc = 1
    else
        set @script_conflict_proc = 0

    -- add code in the script to drop all the procedures first
    select @command = '
-- drop all the procedures first
if object_id(''' + @ins_procname + ''',''P'') is not NULL
    drop procedure ' + @ins_procname + '
if object_id(''' + @ins_batch_procname + ''',''P'') is not NULL
    drop procedure ' + @ins_batch_procname + '
if object_id(''' + @upd_procname + ''',''P'') is not NULL
    drop procedure ' + @upd_procname + '
if object_id(''' + @upd_batch_procname + ''',''P'') is not NULL
    drop procedure ' + @upd_batch_procname + '
if object_id(''' + @del_procname + ''',''P'') is not NULL
    drop procedure ' + @del_procname + '
if object_id(''' + @sel_procname + ''',''P'') is not NULL
    drop procedure ' + @sel_procname + '
if object_id(''' + @sel_metadata_procname + ''',''P'') is not NULL
    drop procedure ' + @sel_metadata_procname + '
if object_id(''' + @conflict_proc + ''',''P'') is not NULL
    drop procedure ' + @conflict_proc + '
'
    select @command


    exec @retcode = sys.sp_MSmakeinsertproc @objectname, @ownername, @ins_procname, @pubid, @artid, @generate_downlevel_procs = 0, @generate_subscriber_proc = 1, @destination_owner = @destowner
    if @@ERROR<>0 OR @retcode <>0 goto FAILURE

    exec @retcode = sys.sp_MSmakeupdateproc @objectname, @ownername, @upd_procname, @pubid, @artid, @generate_downlevel_procs = 0, @generate_subscriber_proc = 1, @destination_owner = @destowner
    if @@ERROR<>0 OR @retcode <>0 goto FAILURE

    exec @retcode = sys.sp_MSmakedeleteproc @objectname, @ownername, @del_procname, @pubid, @artid, @generate_subscriber_proc = 1, @destination_owner = @destowner
    if @@ERROR<>0 OR @retcode <>0 goto FAILURE

    if @generate_batch_procs = 1
    begin
        exec @retcode = sys.sp_MSmakebatchinsertproc @objectname, @ownername, @ins_batch_procname, @pubid, @artid, @generate_subscriber_proc = 1, @destination_owner = @destowner
        if @@ERROR<>0 OR @retcode <>0 goto FAILURE

        exec @retcode = sys.sp_MSmakebatchupdateproc @objectname, @ownername, @upd_batch_procname, @pubid, @artid, @generate_subscriber_proc = 1, @destination_owner = @destowner
        if @@ERROR<>0 OR @retcode <>0 goto FAILURE

    end

    exec @retcode = sys.sp_MSmakeselectproc @objectname, @ownername, @sel_procname, @pubid, @artid, @generate_downlevel_procs = 0, @generate_subscriber_proc = 1, @destination_owner = @destowner
    if @@ERROR<>0 OR @retcode <>0 goto FAILURE

    if @recreateallprocs = 1
    begin
        exec @retcode = sys.sp_MSmakemetadataselectproc @objectname, @ownername, @sel_metadata_procname, @pubid, @artid, @generate_subscriber_proc = 1, @destination_owner = @destowner
        if @@ERROR<>0 OR @retcode <>0 goto FAILURE

        if (@script_conflict_proc = 1 and @upload_options <> 1 and @upload_options <> 2)
        begin
            exec @retcode = sys.sp_MSmakeconflictinsertproc @conflict_table, 'dbo', @conflict_proc, @objid, @pubid, @generate_subscriber_proc = 1
            if @@ERROR<>0 OR @retcode <>0 goto FAILURE

        end
    end
    else
    begin
        exec @retcode = sys.sp_helptext @sel_metadata_procname
        if @@ERROR<>0 OR @retcode <>0 goto FAILURE

        if (@script_conflict_proc = 1 and @upload_options <> 1 and @upload_options <> 2)
        begin
            -- the conflict insert proc should look identical on pub and sub. So instead of creating it just read using sp_helptext
            exec @retcode = sys.sp_helptext @conflict_proc
            if @@ERROR<>0 OR @retcode <>0 goto FAILURE

        end
    end

    select '
update dbo.sysmergearticles 
    set insert_proc = ''' + @ins_procname + ''',
        select_proc = ''' + @sel_procname + ''',
        metadata_select_proc = ''' + @sel_metadata_procname + ''',
        update_proc = ''' + @upd_procname + ''',
        ins_conflict_proc = ''' + @conflict_proc + ''',
        delete_proc = ''' + @del_procname + '''
    where artid = ''' + convert(nvarchar(40), @artid) + ''' and pubid = ''' + convert(nvarchar(40),@pubid) + ''''

    -- This proc was added in yukon sp1 so try to execute it only if it exists on the
    -- subscriber.
	select @command = '
	if object_id(''sp_MSpostapplyscript_forsubscriberprocs'',''P'') is not NULL
		exec sys.sp_MSpostapplyscript_forsubscriberprocs @procsuffix = ''' + sys.fn_replreplacesinglequote(@procsuffix) + ''''
	select @command

    return 0

FAILURE:
    raiserror(21692, 16, -1, @article, @publication)
    return 1    
GO
GRANT EXECUTE ON [sys].[sp_MSscriptsubscriberprocs] TO [public] AS [dbo]
GO
