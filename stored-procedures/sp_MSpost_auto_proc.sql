SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSpost_auto_proc]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSpost_auto_proc] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSpost_auto_proc]
	@pubid [int],
	@artid [int],
	@procmapid [int],
	@pubname [sysname],
	@artname [sysname],
	@publisher [sysname],
	@dbname [sysname],
	@for_p2p_ddl [bit],
	@format [int],
	@has_ts [bit],
	@has_ident [bit],
	@alter [bit]
WITH EXECUTE AS CALLER
AS
begin
    declare @proctext nvarchar(max)
                ,@retcode int
                ,@procname nvarchar(256)

    declare @sql_cmd_type int
                ,@k_scriptcustominsproc tinyint
                ,@k_scriptcustomdelproc tinyint
                ,@k_scriptcustomupdproc tinyint
                ,@k_getsynctrancmds tinyint
                ,@k_scriptsubcftable tinyint
                ,@k_scriptinsproccore tinyint
                ,@k_scriptdelproccore tinyint
                ,@snapshot_bit int

    set nocount on
    select @retcode = 0
            ,@sql_cmd_type = 11 -- make it a sql_altertable type so the same logic in coresub.cpp can handle both 'alter table' and regen procs
            ,@k_scriptcustominsproc = 1
            ,@k_scriptcustomdelproc = 2
            ,@k_scriptcustomupdproc = 3
            ,@k_getsynctrancmds = 4
            ,@k_scriptsubcftable = 5
            ,@k_scriptinsproccore = 6
            ,@k_scriptdelproccore = 7
            ,@snapshot_bit = 0x80000000


    /*
    ** Security Check
    */
    exec @retcode = sys.sp_MSreplcheck_publish
    if @@ERROR <> 0 or @retcode <> 0
        return(1)
    --
    -- validate @procmapid
    --
    if (@procmapid in (@k_scriptcustominsproc, @k_scriptcustomdelproc, 
                @k_scriptcustomupdproc, @k_getsynctrancmds, @k_scriptsubcftable,
                @k_scriptinsproccore, @k_scriptdelproccore))
    begin
        select @procname = case 
            when (@procmapid = @k_scriptcustominsproc) then N'sys.sp_MSscriptcustominsproc'
            when (@procmapid = @k_scriptcustomdelproc) then N'sys.sp_MSscriptcustomdelproc'
            when (@procmapid = @k_scriptcustomupdproc) then N'sys.sp_MSscriptcustomupdproc'
            when (@procmapid = @k_getsynctrancmds) then N'sys.sp_MSarticle_synctran_commands'
            when (@procmapid = @k_scriptsubcftable) then N'sys.sp_scriptsubconflicttable'
            --when (@procmapid = @k_scriptinsproccore) then N'sys.sp_scriptinsproccore'
            when (@procmapid = @k_scriptinsproccore) then N'sys.sp_scriptdropinsreconciliationproc_sqlclr'
            --when (@procmapid = @k_scriptdelproccore) then N'sys.sp_scriptdelproccore'
            when (@procmapid = @k_scriptdelproccore) then N'sys.sp_scriptdropdelreconciliationproc_sqlclr'
            end
    end
    else
    begin
        raiserror(15021, 16, -1, '@procmapid')
        return 1
    end

    -- save the generation code
    create table #temptext (colidx int identity, col nvarchar(max) collate database_default)
    if @procmapid = 6   -- sys.sp_scriptinsproccore, called to cleanup CCS reconcil procs only 
    begin
        insert #temptext (col) exec @procname @artid = @artid
                                    ,@mode = 3  -- droponly 
                                    ,@publishertype = 1  --mssqlserver
                                    ,@format = @format
		select @sql_cmd_type = @sql_cmd_type
	end                             
    else if @procmapid = 7   -- sp_scriptdelproccore, called to cleanup CCS reconcil procs only 
    begin
        insert #temptext (col) exec @procname @artid = @artid
                                    ,@mode = 3  -- droponly 
                                    ,@publishertype = 1  --mssqlserver
                                    ,@format = @format
		select @sql_cmd_type = @sql_cmd_type
	end                             
    else if @procmapid in (1, 2, 3)  -- custom procs
        insert #temptext (col) exec @procname @artid = @artid, @usesqlclr = 1, @inDDLrepl = 1
    else if @procmapid = 5  -- cft tables
	    insert #temptext (col) exec @procname @publication = @pubname 
                                        ,@article = @artname 
                                        ,@alter = 1
                                        ,@usesqlclr = 1
    else if @procmapid = 4  -- sync triggers on subscriber
        insert #temptext (col) exec @procname @publication = @pubname
										,@article = @artname
										,@command_only = 1
										,@publisher = @publisher
										,@publisher_db = @dbname
										,@has_ts = @has_ts
										,@has_ident = @has_ident
										,@alter = @alter -- ddl calls this guy with @alter set to 1, upgrade calls it with 0
                                        ,@usesqlclr = 1 
    else
    begin
        raiserror(15021, 16, -1, '@procmapid')
        return 1
    end

    -- if this is for the Peer-To-Peer auto-gen proc case caused by 
    -- ddl being applied via the distribution agent then we will want
    -- to post these commands as a special type so we are aware that 
    -- we will need to perform special error handling in the dist agent
    if @for_p2p_ddl = 1
    begin
        select @sql_cmd_type = 44 -- REPL_PEERTOPEERAUTOPROC
    end
    -- post to the log
    declare #trancolumn CURSOR LOCAL FAST_FORWARD for 
        select col from #temptext order by colidx
    open #trancolumn
    fetch #trancolumn into @proctext
    while (@@fetch_status <> -1)
    BEGIN
        if(@proctext = N'go') -- post the drop as one command
        begin
            exec @retcode = sys.sp_replpostcmd 0, @pubid, @artid, @sql_cmd_type, N' -- '
            if(@retcode <> 0) or (@@error <> 0)
                return 1
        end
        else
        begin
            select @proctext = @proctext + N' '
            exec @retcode = sys.sp_replpostcmd 1, @pubid, @artid, @sql_cmd_type, @proctext
            if(@retcode <> 0) or (@@error <> 0)
                return 1
        end
        fetch #trancolumn into @proctext
    END
    exec @retcode = sys.sp_replpostcmd 0, @pubid, @artid, @sql_cmd_type, N' --'
    if(@retcode <> 0) or (@@error <> 0)
        return 1
    close #trancolumn
    deallocate #trancolumn
    return 0
end
GO
GRANT EXECUTE ON [sys].[sp_MSpost_auto_proc] TO [public] AS [dbo]
GO
