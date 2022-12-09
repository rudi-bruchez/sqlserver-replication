SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSadd_compensating_cmd]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSadd_compensating_cmd] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSadd_compensating_cmd]
	@orig_srv [sysname],
	@orig_db [sysname],
	@command [nvarchar](max),
	@article_id [int],
	@publication_id [int],
	@cmdstate [bit],
	@mode [int],
	@setprefix [bit]
WITH EXECUTE AS CALLER
AS
BEGIN
    set nocount on
    --
    -- variable declarations for all modes
    --
    declare     
            @retcode            int,
            @command_id         int,                -- command sequence
            @partial_cmd         int,                -- partial command flag
            @curlen            int,                -- current length to read
            @start_index        int,                -- index to start reading
            @max_fragment    int,                -- max binary fragment
            @full_command        nvarchar(max),    -- qualified command
            @readsize            int,                -- read length chars or bytes based on mode
            @mode_postpublog     int,
            @mode_insdistcmd     int,
    --
    -- variable declarations specific to mode = 1
    --
            @partial_cmdbit        bit,                -- partial command flag
            @xact_seqno        varbinary(16),
            @publisher_id         int,                -- publisher ID
            @publisher_db        sysname,         -- publisher Db
            @distributor        sysname,            -- distribution server
            @distribdb            sysname,            -- distribution db
            @charsize            int,                -- char size
            @binary_cmd        varbinary(1024),    -- Binary converted command
            @distproc            nvarchar(300)        -- RPC string
    --
    -- Security Check
    --
    exec @retcode = sys.sp_MSreplcheck_publish
    if ((@@ERROR != 0) or (@retcode != 0))
        return(1)
    --
    -- Initialize
    --
    select @mode_postpublog = 0
            ,@mode_insdistcmd = 1
    --
    -- check @mode
    --
    if (@mode NOT in (@mode_postpublog,@mode_insdistcmd))
        return(1)
    --
    -- check @article_id, @publication_id
    --
    if (@article_id < 1 or @publication_id < 1)
        return(1)
    --
    -- We will not post final partial empty(may contain space) command 
    -- since logreader skips empty commands and this causes distribution 
    -- agent to get confused when it selects the commands to read.
    -- If this partial command happens to be the final partial command which 
    -- has a single space - then add a comment
    --
    if  ((len(@command) = 0) and (@cmdstate = 0))
        select @command = N'/*c*/'
    --
    -- process based on @mode
    --
    --I don't see this proc ever been called with this mode, it's always called with 0 which means postpublog
    --check with Kaushik and see if we can remove this block of code
    if (@mode = @mode_insdistcmd)
    begin
        select @publisher_db = db_name()
                ,@publisher_id = srvid 
        from master.dbo.sysservers 
        where UPPER(srvname) = UPPER(publishingservername()) collate database_default
        --
        -- Get distribution server information for remote RPC calls
        --
        EXECUTE @retcode = sys.sp_MSrepl_getdistributorinfo @rpcsrvname = @distributor OUTPUT,
                                @distribdb  = @distribdb OUTPUT
        if ((@@ERROR != 0) or (@retcode != 0))
            return(1)
        --
        -- Get the new xact_seqno
        --
        create table #new_xact_seqno ( seqno varbinary(16) NOT NULL )
        select @distproc = QUOTENAME(RTRIM(@distributor)) + '.' + QUOTENAME(@distribdb) +'.dbo.sp_MSget_new_xact_seqno'
        insert into #new_xact_seqno
            EXECUTE @retcode = @distproc
                    @publisher_id = @publisher_id,
                    @publisher_db = @publisher_db,
                    @len = 14
        if ((@@ERROR != 0) or (@retcode != 0))
            return(1)
        select @xact_seqno = seqno from #new_xact_seqno    
        select @distproc = QUOTENAME(RTRIM(@distributor)) + '.' + QUOTENAME(@distribdb) +'.dbo.sp_MSadd_repl_command'
    end
    --
    -- Do the command insertion in a tran
    --
    select @full_command = case when (@setprefix = 1) then 
                                        QUOTENAME(@orig_srv) + QUOTENAME(@orig_db) + @command
                                        else @command end
    begin tran sp_MSadd_compensating_cmd
    --
    -- process the command
    -- for @mode_postpublog : just call sp_replpostcmd and that will do the job
    -- for @mode_insdistcmd : break the command into 1024 sized commands and add
    --
    if (@mode = @mode_postpublog)
    begin
        select  @partial_cmd = CASE when (@cmdstate = 1) then 1 else 0 END
        exec @retcode = sys.sp_replpostcmd 
                            @partial_cmd,
                            @publication_id, 
                            @article_id, 
                            12,
                            @full_command
        if (@@ERROR != 0 or @retcode != 0)
            GOTO UNDO
    end
    else if (@mode = @mode_insdistcmd)
    begin
        select @command_id = 0,
                @start_index = 1,
                @max_fragment = 1024,
                @charsize = 2,
                @curlen = LEN(@full_command),
                @readsize = DATALENGTH(@full_command)

        while (@readsize > 0)
        begin
            -- set command id
            select @command_id = @command_id + 1

            -- Check if we have to process partial command
            if (@readsize > @max_fragment)
            begin
                --
                -- we have partial command to send
                --
                select @curlen = @max_fragment / @charsize
                select @partial_cmdbit = 1,
                        @binary_cmd = CAST(
                                SUBSTRING(@full_command, @start_index, @curlen)
                                AS varbinary(1024)),
                        @readsize = @readsize - @max_fragment

                select @start_index = @start_index + @curlen
                select @curlen = @readsize / @charsize
            end
            else
            begin
                --
                -- last fragment to send - end of command
                -- check for command state - if state is PARTIAL_CMD (1)
                -- then set the partial bit even though this is the last fragment
                --
                select @partial_cmdbit = CASE when (@cmdstate = 1) then 1 else 0 END,
                        @binary_cmd = CAST(
                                SUBSTRING(@full_command, @start_index, @curlen) 
                                AS varbinary(1024)),
                        @readsize = 0
            end
            --
            -- Add the command to the distributor
            --
            EXECUTE @retcode = @distproc
                    @publisher_id = @publisher_id, 
                    @publisher_db = @publisher_db, 
                    @xact_seqno = @xact_seqno,
                    @type = 12, 
                    @article_id = @article_id, 
                    @command_id = @command_id, 
                    @partial_command = @partial_cmdbit, 
                    @command = @binary_cmd
            if (@@ERROR != 0 or @retcode != 0)
                GOTO UNDO
        end -- end of while loop
    end     -- end of if (@mode = @mode_insdistcmd)
    --
    -- Command(s) added successfully - End Tran
    --
    commit tran sp_MSadd_compensating_cmd
    return (0)

UNDO:
    --
    -- Error - Rollback
    --
    IF (@@TRANCOUNT > 0)
    begin
        ROLLBACK TRAN sp_MSadd_compensating_cmd
        if (@@TRANCOUNT > 0)
            COMMIT TRAN   
    end
    return (1)    
END
GO
GRANT EXECUTE ON [sys].[sp_MSadd_compensating_cmd] TO [public] AS [dbo]
GO
