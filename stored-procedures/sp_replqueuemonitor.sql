SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_replqueuemonitor]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_replqueuemonitor] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_replqueuemonitor]
	@publisher [sysname],
	@publisherdb [sysname],
	@publication [sysname],
	@tranid [sysname],
	@queuetype [tinyint]
WITH EXECUTE AS CALLER
AS
begin
    set nocount on
    declare @retcode int
            ,@queue_server sysname
            ,@queue_id sysname
            ,@data varbinary(8000)
            ,@datalen int
            ,@commandtype int
            ,@cmdstate bit
            ,@mesglen int
            ,@command nvarchar(4000)
            ,@partialindex int
            ,@rowlen int
            ,@comandlen int

    declare @k_mesg_partial_state bit
            ,@k_mesg_complete_state bit
            ,@k_mesg_tran_cmd int
            ,@k_max_rowlen int
            ,@k_queuetype_all tinyint
            ,@k_queuetype_msmq tinyint
            ,@k_queuetype_sql tinyint

    /*
    ** Security Check.
    */
    exec @retcode = sys.sp_MSreplcheck_subscribe
    if @@ERROR <> 0 or @retcode <> 0
        return(1)

    create table #mesgs (mesgid int identity PRIMARY KEY, queuetype tinyint default 1, publisher sysname collate database_default, publisher_db sysname collate database_default, publication sysname collate database_default, 
                            tranid sysname collate database_default, commandlen int, command nvarchar(max))

    --
    -- Check if need to look for subscriptions
    --
    if exists (select * from sys.objects where name = 'MSsubscription_agents')
    begin
        --
        -- Are there any qualifying subscriptions
        --
        if exists (select * from dbo.MSsubscription_agents where
                publisher = case when @publisher is NULL then publisher else UPPER(@publisher) end AND
                publisher_db = case when @publisherdb is NULL then publisher_db else @publisherdb end AND
                publication = case when @publication is NULL then publication else @publication end )
        begin
            --
            -- initialize
            --
            select  @k_queuetype_all = 0
                    ,@k_queuetype_msmq = 1
                    ,@k_queuetype_sql = 2
                    
            --
            -- MSMQ based
            --
            if (@queuetype in (@k_queuetype_all, @k_queuetype_msmq) and
                exists (select * from dbo.MSsubscription_agents where
                    publisher = case when @publisher is NULL then publisher else UPPER(@publisher) end AND
                    publisher_db = case when @publisherdb is NULL then publisher_db else @publisherdb end AND
                    publication = case when @publication is NULL then publication else @publication end  AND
                    update_mode IN (2,3) AND
                    queue_id != N'mssqlqueue'))
            begin
                --
                -- enumerate each queue
                --
                create table #queues (publisher sysname collate database_default, publisher_db sysname collate database_default, publication sysname collate database_default, queue_id sysname collate database_default)
                declare #htempcursor cursor local for
                    select publisher, publisher_db, publication, queue_server, queue_id 
                    from dbo.MSsubscription_agents 
                    where
                        publisher = case when @publisher is NULL then publisher else UPPER(@publisher) end AND
                        publisher_db = case when @publisherdb is NULL then publisher_db else @publisherdb end AND
                        publication = case when @publication is NULL then publication else @publication end  AND
                        update_mode IN (2,3) AND
                        queue_id != N'mssqlqueue'

                open #htempcursor
                fetch #htempcursor into @publisher, @publisherdb, @publication, @queue_server, @queue_id
                while (@@fetch_status = 0)
                begin
                    --
                    -- add the queue server prefix
                    --
                    select @queue_id = N'DIRECT=OS:' + @queue_server + N'\PRIVATE$\' + @queue_id
                    
                    --
                    -- Display all the messages in this queue
                    --
                    insert into #mesgs (publisher, publisher_db, publication, tranid, commandlen, command)
                        exec @retcode = sys.xp_displayqueuemesgs @publisher, @publisherdb, @publication, @queue_id, @tranid
                    if (@retcode != 0 or @@error != 0)
                        return 1

                    --
                    -- fetch next row
                    --
                    fetch #htempcursor into @publisher, @publisherdb, @publication, @queue_server, @queue_id
                end
                close #htempcursor
                deallocate #htempcursor
    
                --
                -- All MSMQ Queues processed
                --
                drop table #queues
            end
            
            --
            -- SQL Queued based
            --
            if (@queuetype in (@k_queuetype_all, @k_queuetype_sql) and
                exists (select * from dbo.MSsubscription_agents where
                    publisher = case when @publisher is NULL then publisher else UPPER(@publisher) end AND
                    publisher_db = case when @publisherdb is NULL then publisher_db else @publisherdb end AND
                    publication = case when @publication is NULL then publication else @publication end  AND
                    update_mode IN (4,5) AND
                    queue_id in( N'mssqlqueue', N'mssqlqueuev2')))
            begin
                --
                -- check if we have a queue
                --
                if exists (select * from sys.objects where name = 'MSreplication_queue')
                begin
                    --
                    -- initialize
                    --
                    select @mesglen = 0
                            ,@partialindex = 0
                            ,@k_mesg_partial_state = 1
                            ,@k_mesg_complete_state = 0
                            ,@k_mesg_tran_cmd = 1
                            ,@k_max_rowlen = 8000
                    
                    --
                    -- select the messages that qualify
                    --
                                            
                    declare #htempcursor cursor local for
                        select publisher, publisher_db, publication, tranid, datalen, data, commandtype, cmdstate
                        from dbo.MSreplication_queue 
                        where
                            publisher = case when @publisher is NULL then publisher else UPPER(@publisher) end AND
                            publisher_db = case when @publisherdb is NULL then publisher_db else @publisherdb end AND
                            publication = case when @publication is NULL then publication else @publication end  AND
                            tranid = case when @tranid IS NULL then tranid else @tranid end
                    open #htempcursor
                    fetch #htempcursor into @publisher, @publisherdb, @publication, @tranid, @datalen, @data, @commandtype, @cmdstate
                    while (@@fetch_status = 0)
                    begin
                        --
                        -- check the message state
                        --
                        if (@cmdstate = @k_mesg_partial_state)
                            select @partialindex = @partialindex + 1
                        select @mesglen = @mesglen + @datalen

                        --
                        -- process the body only for command type messages
                        -- and if the command spans multiple rows, then
                        -- display only the first row
                        --
                        if ((@commandtype = @k_mesg_tran_cmd) and
                            ((@cmdstate = @k_mesg_complete_state and @partialindex = 0) or
                            (@cmdstate = @k_mesg_partial_state and @partialindex = 1)))
                        begin
                            --
                            -- decode the command
                            --
                            exec @retcode = sys.xp_decodequeuecmd @data, @command OUTPUT
                            if (@retcode != 0 or @@error != 0)
                                return 1
                        end
                        
                        --
                        -- Are processing the final row for this command
                        --
                        if (@cmdstate = @k_mesg_complete_state)
                        begin
                            --
                            -- reset partial index
                            --
                            if (@partialindex > 0)
                                select @partialindex = 0

                            if (@command IS NOT NULL)
                            begin
                                --
                                -- check if the command needs to truncated to fit the max rowsize
                                --
                                select @rowlen = 4 + DATALENGTH(@k_queuetype_sql) + 
                                                 DATALENGTH(@publisher) + DATALENGTH(@publisherdb) +
                                                 DATALENGTH(@publication) + DATALENGTH(@tranid) + 
                                                 DATALENGTH(@mesglen)
                                        ,@comandlen = DATALENGTH(@command)
                                if (@rowlen + @comandlen > @k_max_rowlen)
                                begin
                                    select @comandlen = @k_max_rowlen - @rowlen
                                    select @comandlen = @comandlen / 2
                                    select @command = SUBSTRING(@command, 1, @comandlen)
                                end
                                
                                insert into #mesgs (queuetype, publisher, publisher_db, publication, tranid, commandlen, command)
                                values (@k_queuetype_sql, @publisher, @publisherdb, @publication, @tranid, @mesglen, @command)
                                if (@retcode != 0 or @@error != 0)
                                    return 1

                                select @command = NULL
                            end

                            --
                            -- reset command len
                            --
                            if (@mesglen > 0)
                                select @mesglen = 0
                        end
                        
                        --
                        -- fetch next row
                        --
                        fetch #htempcursor into @publisher, @publisherdb, @publication, @tranid, @datalen, @data, @commandtype, @cmdstate
                    end
                    close #htempcursor
                    deallocate #htempcursor
                end 
    
                --
                -- All SQL Queues processed
                --
            end
        end
    end
    
    --
    -- return result
    --
    select  queue = case when queuetype = @k_queuetype_msmq then N'MSMQ'
                        when queuetype = @k_queuetype_sql then N'SQLQ' end 
            ,publisher
            ,publisher_db
            ,publication
            ,tranid
            ,commandlen
            ,command 
    from #mesgs
    order by mesgid
    
    --
    -- All done
    --
    drop table #mesgs
    return 0
end
GO
GRANT EXECUTE ON [sys].[sp_replqueuemonitor] TO [public] AS [dbo]
GO
