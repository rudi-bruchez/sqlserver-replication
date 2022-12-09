SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSscript_sync_del_proc]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSscript_sync_del_proc] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSscript_sync_del_proc]
	@publication [sysname],
	@article [sysname],
	@procname [sysname],
	@alter [bit]
WITH EXECUTE AS CALLER
AS
BEGIN
    declare @source_objid int
    declare @colname sysname
    declare @indid int
    declare @cmd          nvarchar(4000)
    declare @outvars      nvarchar(4000)
    declare @rc           int
    declare @error_cmd  tinyint
    declare @queued_pub bit
    declare @artid int

    set nocount on
    --
    -- security check -- dbo+ to script create or alter
    --
    exec @rc = sys.sp_MSreplcheck_publish
	if @@error <> 0 or @rc <> 0
    begin
	    return (1)
    end
    --
    -- Create temp table
    --
    create table #proctext ( c1 int identity NOT NULL, procedure_text nvarchar(4000) collate database_default null)
    select @queued_pub = allow_queued_tran from syspublications where name = @publication
    --
    -- proc definition
    --
    exec @rc = sys.sp_MSscript_beginproc @publication, @article, @procname, @source_objid output, @artid output, @alter
    if @@error <> 0 or @rc <> 0
        return
    --
    -- construct parameter list
    --
    exec sys.sp_MSscript_params @source_objid, @artid, N'_old', 0, null
    --
    -- add other parameters and start body of proc
    --
    exec sys.sp_MSscript_procbodystart @queued_pub 
    --
    -- script the security and execution mode  and subscription validation checks
    --
    exec sys.sp_MSscript_ExecutionMode_stmt @publication, @article, 1
    --
    -- Work around for case where article has 1 col that is not user-modfied (identity, timestamp)
    -- *** Do we need to check this here - 
    -- *** we should be checking this when creating subscription
    -- 
    exec @rc = sys.sp_MStable_not_modifiable @source_objid, @artid
    if @rc = 1
        select @error_cmd = 1
    else
    begin
        exec @indid = sys.sp_MStable_has_unique_index @source_objid 
        if (@outvars is not null and @indid = 0)
            -- no insert/update allowed if timestamp/identity col and no unique index
            select @error_cmd = 1
        else
            select @error_cmd = 0       
    end

    if (@error_cmd = 0)
    begin
        --
        -- script delete statemnt
        --
        exec sys.sp_MSscript_delete_statement @publication, @article, @source_objid, @artid, @queued_pub
        --
        -- script queued specific stuff
        --
        if (@queued_pub = 1)
        begin
            --
            -- script the conflict resolution logic common to all resolution policies
            --
            exec sp_MSscriptdelconflictfinder @publication, @article, @source_objid
            --
            -- script Conflict resolution block for Publisher Wins case
            --
            exec sys.sp_MSscript_delete_pubwins @publication, @article, @source_objid
            --
            -- script Conflict resolution block for Subscriber Wins case
            --
            exec sys.sp_MSscript_delete_subwins @publication, @article, @source_objid, @artid
        end
        --
        -- script closing 
        --
        exec sys.sp_MSscript_endproc @source_objid, 'del', @artid, @outvars, @queued_pub
    end
    else
    begin
        --
        -- Generate error command and finish
        --
        insert into #proctext(procedure_text) values( N'
    exec sys.sp_MSreplraiserror 20516
END
')
    end
    --
    -- send fragments to client
    --
    select procedure_text from #proctext order by c1 asc
    --
    -- all done
    --
    return 0
END
GO
GRANT EXECUTE ON [sys].[sp_MSscript_sync_del_proc] TO [public] AS [dbo]
GO
