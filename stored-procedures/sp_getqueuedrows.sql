SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_getqueuedrows]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_getqueuedrows] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_getqueuedrows]
	@tablename [sysname],
	@owner [sysname],
	@tranid [nvarchar](70)
WITH EXECUTE AS CALLER
AS
begin
    set nocount on
    declare @retcode int
        ,@dbname sysname
        ,@qualified_tabname nvarchar(1000)
        ,@tabid int
        ,@agent_id int
        ,@publisher sysname
        ,@publisher_db sysname
        ,@publication sysname
        ,@queue_id sysname
        ,@update_mode int
        ,@failover_id int
        ,@cmd nvarchar(4000)
        ,@queue_server sysname
        ,@indid int
        ,@indkey int
        ,@key sysname
        ,@colid int
        ,@typestring nvarchar(4000)
        ,@artcol int
        ,@xpinputstr nvarchar(4000)
        ,@selectcl nvarchar(4000)
        ,@joincl nvarchar(4000)
        ,@curuser sysname

    --
    -- prepare the fully qualified table
    --
    select @owner = case when (@owner IS NULL) then N'dbo' else @owner end
            ,@dbname = db_name()
            ,@curuser = user
    select @qualified_tabname = quotename(@dbname) + N'.' 
                    + quotename(@owner) + N'.' + quotename(@tablename)
    select @tabid = object_id(@qualified_tabname)
    if (@tabid IS NULL) or (@tabid = 0)
    begin
        -- error
        raiserror(21078, 16, 1, @qualified_tabname)
        return 1
    end

    --
    -- current user should have SELECT permission on the table
    --
    if (HAS_PERMS_BY_NAME(sys.fn_replreplacesinglequote(@qualified_tabname), 'OBJECT', 'SELECT')=0)
    begin
        -- error
        raiserror(21752, 16, 1, @curuser, @qualified_tabname)
        return 1
    end

    --
    -- make sure the table is participating in a active queued subscription
    --
    select @agent_id = agent_id 
    from dbo.MSsubscription_articles 
    where dest_table = @tablename and owner = @owner

    if (@agent_id IS NULL)
    begin
        -- error
        raiserror(21753, 16, 1, @qualified_tabname)
        return 1
    end

    --
    -- get the details for the subscription
    --
    select @publisher = publisher
            ,@publisher_db = publisher_db
            ,@publication = publication
            ,@update_mode = update_mode
            ,@queue_server = queue_server
            ,@queue_id = queue_id
            ,@failover_id = failover_mode
    from dbo.MSsubscription_agents where id = @agent_id
    if (@update_mode not in (2,3,4,5))
    begin
        -- error
        raiserror(21753, 16, 2, @qualified_tabname)
        return 1
    end
    
    --
    -- If we are in Immediate Failover mode - no queued messages
    --
    if (@update_mode in (3,5) and (@failover_id = 0))
    begin
        --
        -- do an empty select on the source table and return
        --
        select @cmd = N'declare @dummy_action nvarchar(10), @dummy_tranid nvarchar(70)
                    select action=@dummy_action, tranid=@dummy_tranid, * from ' + 
                    @qualified_tabname + N' where 1 = 2 '
        exec (@cmd)
        return 0
    end

    if (@update_mode in (2,3))
    begin
        --
        -- set queue prefix for MSMQ cases
        --
        select @queue_id = N'DIRECT=OS:' + @queue_server + N'\PRIVATE$\' + @queue_id
    end
    else
    begin
        --
        -- Check the queue table for SQLQ
        --
        if not exists (select * from dbo.MSreplication_queue
        where UPPER(publisher) = UPPER(@publisher) and
                publisher_db = @publisher_db and
                publication = @publication and
                tranid = case when @tranid IS NULL then tranid else @tranid end)
        begin
            --
            -- do an empty select on the source table and return
            --
            select @cmd = N'declare @dummy_action nvarchar(10), @dummy_tranid nvarchar(70)
                    select action=@dummy_action, tranid=@dummy_tranid, * from ' + 
                    @qualified_tabname + N' where 1 = 2 '
            exec (@cmd)
            return 0
        end
    end

    --
    -- Now find the PK columns for this table
    --
    select @indkey = 1
        ,@artcol = 0
        ,@xpinputstr = N''
        ,@selectcl = N''
        ,@joincl = N''
        ,@retcode = 0

    select @indid = i.indid 
    from dbo.sysindexes i 
    where ((i.status & 2048) != 0) and (i.id = @tabid)
    if (@indid is null)
    begin
        raiserror(21750, 16, -1, @qualified_tabname)
        return 1
    end
    
    --
    -- create an enumeration of all the columns that are part of PK
    --
    create table #pkcoltab(pkindex int identity, keyname sysname collate database_default not null)
    while (@indkey <= 16)
    begin
        select @key = index_col( @qualified_tabname, @indid, @indkey )
        if (@key is null)
            break
        else
            insert into #pkcoltab(keyname) values(@key)

        select @indkey = @indkey + 1
    end

    --
    -- initialize the commands that we need to build
    --
    if exists (select * from sys.objects where name = 'tempcrtcmd' and schema_id = schema_id())
        drop table tempcrtcmd
    create table tempcrtcmd (c1 int identity NOT NULL, procedure_text nvarchar(4000) NULL)
    
    select @cmd = N'create table tempqjointab (action nvarchar(10), tranid nvarchar(70) '
    insert into tempcrtcmd(procedure_text) values(@cmd)

    --
    -- now walk through each article col and if it is
    -- a part of PK, then check find the column position of the key
    -- corresponding to any article column is set
    --
    DECLARE #hCColid CURSOR LOCAL FAST_FORWARD FOR 
        select column_id, [name] from sys.columns 
        where object_id = @tabid order by column_id asc

    OPEN #hCColid
    FETCH #hCColid INTO @colid, @key
    WHILE (@@fetch_status != -1)
    begin
        exec sys.sp_MSget_type @tabid, @colid, NULL, @typestring output
        if ((@typestring IS NOT NULL) and (@typestring != N'timestamp'))
        begin
            --
            -- this column is part of the article
            --
            select @artcol = @artcol + 1
            if exists (select * from #pkcoltab where keyname = @key)
            begin
                --
                -- this column is part of PK (offset and precision, scale)
                -- prepare the input string for XP
                -- prepare the create join table command
                -- prepare the join and select clause for the result
                --
                select @xpinputstr = @xpinputstr + N';' + cast(@artcol as nvarchar) 
                if (@typestring = N'bigint')
                    select @xpinputstr = @xpinputstr + N'(19,0)'
                else if (@typestring like N'decimal%') or (@typestring like N'numeric%')
                begin
                    declare @startpos int
                            ,@endpos  int

                    select @startpos = charindex(N'(', @typestring, 1)
                    select @endpos = charindex(N')', @typestring, @startpos)
                    select @xpinputstr = @xpinputstr + substring(@typestring, @startpos, (@endpos - @startpos + 1))
                end
                select @cmd = N',' + quotename(@key) + N' ' + @typestring
                insert into tempcrtcmd(procedure_text) values(@cmd)
                select @selectcl = @selectcl + N', b.' + quotename(@key)
                
                if (@joincl = N'')
                    begin
                    select @joincl = @joincl + N'a.' + quotename(@key) + N' = b.' + quotename(@key)
                end
                else
                begin
                    select @joincl = @joincl + N'and a.' + quotename(@key) + N' = b.' + quotename(@key)
                end             
            end
            else
            begin
                --
                -- this column is not part of PK
                -- build the select clause for this column
                --
                select @selectcl = @selectcl + N', a.' + quotename(@key)
            end
        end     

        --
        -- get the next column
        --
        FETCH #hCColid INTO @colid, @key
    end
    CLOSE #hCColid
    DEALLOCATE #hCColid
    drop table #pkcoltab

    --
    -- create the join table now
    --
    select @cmd = N') '
    insert into tempcrtcmd(procedure_text) values(@cmd)
    if exists (select * from sys.objects where name = N'tempqjointab' and schema_id = schema_id())
        drop table tempqjointab
    select @cmd = 'select procedure_text from dbo.tempcrtcmd order by c1'
    exec @retcode = sys.xp_execresultset @cmd, @dbname
    if (@retcode != 0)
        goto cleanup

    --
    -- populate the join table now
    --
    if (@update_mode in (2,3))
    begin
        --
        -- MSMQ case : one call to the xp should populate the join table
        --
        insert into tempqjointab
            exec sys.xp_readpkfromqueue @tablename, @queue_id, @xpinputstr, @tranid
    end
    else
    begin
        --
        -- SQLQ case : select the data for this subscription and call the
        -- xp for each row in the cursor to populate the join table
        --
        declare @spancount int
                ,@data varbinary(8000)
                ,@state bit
        
        declare #hcurQInfo cursor local FAST_FORWARD FOR
        select data, cmdstate, tranid
        from dbo.MSreplication_queue
        where UPPER(publisher) = UPPER(@publisher) and
                publisher_db = @publisher_db and
                publication = @publication and
                tranid = case when @tranid IS NULL then tranid else @tranid end and
                commandtype = 1
        order by orderkey
        FOR READ ONLY

        select @spancount = 0
        open #hcurQInfo
        fetch #hcurQInfo into @data, @state, @tranid
        while (@@FETCH_STATUS = 0)
        begin
            declare @qbdata0 varbinary(8000)
                    ,@qbdata1 varbinary(8000)

            if (@state = 1)
            begin
                --
                -- command spanning more than a row
                -- we will allow spanning upto 2 rows
                --
                if (@spancount = 0)
                    select @qbdata0 = @data
                else
                begin
                    raiserror(21754, 16, 1)
                    close #hcurQInfo
                    deallocate #hcurQInfo
                    select @retcode = 1
                    goto cleanup
                end
                select @spancount = @spancount + 1
            end
            else
            begin
                --
                -- final row for the command
                --
                if (@spancount = 0)
                    select @qbdata0 = @data             
                else if (@spancount = 1)
                    select @qbdata1 = @data
                else
                begin
                    raiserror(21754, 16, 2)
                    close #hcurQInfo
                    deallocate #hcurQInfo
                    select @retcode = 1
                    goto cleanup
                end

                --
                -- call the xp to populate the join table
                --
                insert into tempqjointab
                    exec sys.xp_readpkfromvarbin @tablename, @xpinputstr, @tranid, @spancount, @qbdata0, @qbdata1

                --
                -- reset the span count
                --
                select @spancount = 0
            end

            --
            -- fetch the next row
            --
            fetch #hcurQInfo into @data, @state, @tranid
        end
        close #hcurQInfo
        deallocate #hcurQInfo
    end

    --
    -- Now perform the join
    --
    select @cmd = N'select b.action, b.tranid ' + @selectcl 
        + N'from ' + @qualified_tabname + N' a right join tempqjointab b on (' + @joincl + N') '
    exec (@cmd)
    
    --
    -- all done
    --
cleanup:    
    if exists (select * from sys.objects where name = N'tempqjointab' and schema_id = schema_id())
        drop table tempqjointab
    if exists (select * from sys.objects where name = N'tempcrtcmd' and schema_id = schema_id())
        drop table tempcrtcmd
    return @retcode
end
GO
GRANT EXECUTE ON [sys].[sp_getqueuedrows] TO [public] AS [dbo]
GO
