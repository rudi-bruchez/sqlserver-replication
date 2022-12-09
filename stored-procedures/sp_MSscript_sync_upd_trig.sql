SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSscript_sync_upd_trig]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSscript_sync_upd_trig] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSscript_sync_upd_trig]
	@objid [int],
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@trigname [sysname],
	@procname [sysname],
	@proc_owner [sysname],
	@cftproc [sysname],
	@agent_id [int],
	@identity_col [sysname],
	@ts_col [sysname],
	@filter_clause [nvarchar](4000),
	@primary_key_bitmap [varbinary](4000),
	@pubversion [int],
	@falter [bit]
WITH EXECUTE AS CALLER
AS
BEGIN
    declare @colname      sysname
        ,@cmd          nvarchar(4000)
        ,@ins_cmd      nvarchar(4000)
        ,@outvars      nvarchar(4000)
        ,@rc           int
        ,@qualname     nvarchar(517)
        ,@fisqueued       bit

    set nocount on
    --
    -- security check
    --
    exec @rc = sys.sp_MSreplcheck_subscribe
    if @@error <> 0 or @rc <> 0
        return (1)
    exec sys.sp_MSget_qualified_name @objid, @qualname OUTPUT
    if (LOWER(@cftproc) = N'null')
    begin
        select @fisqueued =  0
            ,@cftproc = NULL
    end
    else 
        select @fisqueued =  1

    if @ts_col in ('null','NULL')
        select @ts_col = null

    if @identity_col in ('null','NULL')
        select @identity_col = null

    -- Create temp table
    create table #proctext ( c1 int identity NOT NULL, procedure_text nvarchar(4000) collate database_default null)

    -- 1st preamble common to all synctran procs
    exec sys.sp_MSscript_begintrig1 @publisher, @publisher_db, @publication, @trigname, @objid, @procname, @filter_clause, 'upd', @fisqueued, @falter, @agent_id

    -- 2nd preamble common to all synctran procs
    exec sys.sp_MSscript_begintrig2 @publisher, @publisher_db, @publication, @objid, 'upd',@agent_id, @fisqueued

    -- script single row handling
    exec @rc = sys.sp_MSscript_singlerow_trigger @objid,@publisher, @publisher_db, @publication, @procname, @proc_owner, 
            @cftproc, @identity_col, @ts_col, 'upd', @primary_key_bitmap, @pubversion

    -- script multi-row handling
    exec @rc = sys.sp_MSscript_multirow_trigger @objid,@publisher, @publisher_db, @publication, @procname, @proc_owner, 
    @cftproc, @identity_col, @ts_col, 'upd', @primary_key_bitmap, @pubversion

    -- script end of trigger
    exec sys.sp_MSscript_endtrig 

    -- send fragments to client
    select procedure_text from #proctext order by c1 asc
END
GO
GRANT EXECUTE ON [sys].[sp_MSscript_sync_upd_trig] TO [public] AS [dbo]
GO
