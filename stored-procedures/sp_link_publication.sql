SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_link_publication]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_link_publication] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_link_publication]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@security_mode [int],
	@login [sysname],
	@password [sysname],
	@distributor [sysname]
WITH EXECUTE AS CALLER
AS
begin
    set nocount on
    declare @retcode int
                ,@publisherlink sysname
                ,@rpcproc nvarchar(4000)
                ,@islocalpub bit
                ,@existingsecuritymode int
                ,@contextuser sysname
                ,@fcreateduniquelink bit
                ,@fcreateduser bit
                ,@fprepcertonsub bit
                ,@fgrantcertontarget bit
                ,@netname sysname
                ,@certname sysname
                ,@trigcount int
                ,@palcheck_retcode int
                ,@regencmd nvarchar(1000)
                ,@dbname sysname
                ,@pubversion varbinary(16)
                ,@publisherlinkusertodrop sysname

    --
    --  Security Check
    --
    exec @retcode = sys.sp_MSreplcheck_subscribe
    if @@error <> 0 or @retcode <> 0
        return (1)
    --
    -- Parameter check: @security_mode
    --
    if @security_mode not in (0,1,2)
    begin
        raiserror(21055, 16, -1, '@security_mode','sp_link_publication')
        return (1)
    end
    --
    -- SQL Authenticated linked entry - login cannot be null
    --
    if (@security_mode = 0 and @login is null)
    begin
        raiserror(21055, 16, -1, '@login','@security_mode = 0')
        return (1)
    end
    --
    -- Create tables if necessary
    --
    if object_id('dbo.MSreplication_objects') is null or object_id('dbo.MSsubscription_properties') is null
    begin
        exec @retcode = sys.sp_MScreate_sub_tables_internal @tran_sub_table = 1
        if @@error <> 0 or @retcode <> 0
            return 1
        --raiserror(20588, 16, -1)
        --return 1
    end

    --
    -- Call cleanup scripts to remove the old linked server (if exists), related triggers
    --  and certificates/logins/users.
    --
    exec @retcode = sys.sp_unlink_publication_internal
        @publisher = @publisher
        ,@publisher_db = @publisher_db
        ,@publication = @publication
        ,@publisherlinkusertodrop = @publisherlinkusertodrop output

    if @@ERROR <> 0 or @retcode <> 0
        return 1

    -- 
    -- We can only drop the user, if there are no synctran triggers
    --  due to dependancy issues. We can't drop the triggers at this point
    --  since we could run into an issue when the sp errors out before the 
    --  triggers are created where DML would be allowed on the publication's tables.
    --  Thus we only attempt to drop the user when there are no sync triggers. 
    --
    select @trigcount = isnull(count(object_name),0)
        from dbo.MSreplication_objects 
        where upper(publisher) = @publisher
            and publisher_db = @publisher_db
            and publication = @publication
            and object_type = 'T'
    

    if @trigcount = 0 and @publisherlinkusertodrop is not null
    BEGIN
        exec @retcode = sys.sp_dropuser @name_in_db = @publisherlinkusertodrop
        if @@error <> 0 or @retcode <> 0
            return (1)
    END

    --
    -- initialize
    --
    select @publisher = upper(@publisher)
            ,@distributor = upper(@distributor)
            ,@password = case when (@password = N'') then null else @password end
            ,@publisher_db = isnull(@publisher_db, db_name())
            ,@islocalpub = case when (upper(@publisher) = upper(@@servername)) then 1 else 0 end
            ,@fcreateduniquelink = 0
            ,@fprepcertonsub = 0
            ,@fgrantcertontarget = 0
    --
    -- Check for an entry in MSsubscription_properties that 
    -- was created uniquely for this subscription by sp_link_publication
    -- should have the prefix as defined
    --
    select @publisherlink = publisherlink 
            ,@existingsecuritymode = publisher_security_mode
    from MSsubscription_properties 
    where upper(publisher) = @publisher
        and publisher_db =  @publisher_db
        and publication = @publication
    
    --
    -- process based on security_mode
    --
    if @security_mode in (0,1)
    begin
        --
        -- Standard or Integrated
        --
        if (@islocalpub = 1)
        begin
            --
            -- local publisher - we will not use linked server
            -- for security_modes 0 and 1. Set publisher link
            -- to servername for reference
            --
            select @publisherlink = @publisher
            if @security_mode = 0
            begin
                --
                -- Special processing for standard security                
                -- the user for publisher db for given login for SQL authentication
                -- will have a proxy user in subscriber db with db_owner privileges
                -- get the user in publisher db
                --
                if (ISNULL(IS_SRVROLEMEMBER('sysadmin'),@login) = 1)
                begin
                    --
                    -- special case for sysadmin users
                    -- map contextuser to dbo
                    --
                    select @contextuser = 'dbo'
                end
                else
                begin
                    select @rpcproc = 
                        N'select @p1 = a.name from ' + quotename(@publisher_db)
                            + N'.sys.database_principals as a join master.dbo.syslogins as b on a.sid = b.sid where b.loginname = @p2'
                    exec @retcode = sys.sp_executesql @stmt = @rpcproc
                        ,@params = N'@p1 sysname output, @p2 sysname'
                        ,@p1 = @contextuser output
                        ,@p2 = @login
                end
                --
                -- valid pubdb user should exist
                --
                if @contextuser is null
                begin
                    raiserror(21855, 16, 1, @login, @publisher_db)
                    return (1)
                end
                --
                -- for sysadmin logins and the case when the user for the publisher login does not exist on
                -- this subscriber db - we will use proxy 
                -- for other case when user for the publisher login exists on the subscriber db we will use it
                --
                if (lower(@contextuser) = 'dbo') or 
                    not exists (select * from sys.database_principals as a join master.dbo.syslogins as b 
                                    on a.sid = b.sid
                                    where a.name = @contextuser and b.loginname = @login)
                begin
                    --
                    -- we will use a proxy user on both publisher db and subscriber db to avoid SA escalation
                    --
                    exec @retcode = sys.sp_MSprocesspublisherlink @mode = 1, @islocalpub = @islocalpub, @securitymode = @security_mode
                    if @@error <> 0 or @retcode <> 0
                        return(1)
                    --
                    -- we will also create the proxy user on publishing db
                    --
                    select @rpcproc = quotename(@publisher_db) + N'.sys.sp_MSprocesspublisherlink'
                    exec @retcode = @rpcproc @mode = 1, @islocalpub = @islocalpub, @securitymode = @security_mode
                    if @@error <> 0 or @retcode <> 0
                        return(1)
                    select @contextuser = N'repllinkproxy'
                            ,@login = N'repllinkproxy' -- override user specified local login
                            ,@fcreateduser = 1
                end
            end -- @security_mode = 0
        end -- (@islocalpub = 1)
        else
        begin -- (@islocalpub = 0)
            --
            -- Remote publisher - we will create a unique linked server entry for this subscription
            -- if there is one existing we will drop and recreate it
            --
            select @publisherlink = sys.fn_MSrepllinkname(N'REPLLINK', @publisher, @publisher_db, @publication, db_name())
            --
            -- Refresh the linked entry
            --
            exec @retcode = sys.sp_MSprocesspublisherlink 1, @islocalpub, @security_mode, @publisherlink, @publisher, @login, @password
            if @@error <> 0 or @retcode <> 0
                return(1)
            --
            -- we have predefined user context for SQL authentication
            --
            select @contextuser = N'repllinkproxy'
                    ,@login = N'repllinkproxy' -- local login will always be this
                    ,@fcreateduniquelink = 1
                    ,@fcreateduser = 1
        end -- (@islocalpub = 0)
    end
    else
    begin
        --
        -- static linked server case
        --
        if (@existingsecuritymode in (0,1) and @islocalpub = 0)
        begin
            --
            -- we might have a linked entry that was created for standard/integrated mode 
            -- drop this linked entry
            --
            select @publisherlink = sys.fn_MSrepllinkname(N'REPLLINK', @publisher, @publisher_db, @publication, db_name())
            exec sys.sp_MSprocesspublisherlink 2, @islocalpub, @existingsecuritymode, @publisherlink, @publisher
        end
        --
        -- publisher should exist in sys.servers
        --
        select @publisherlink = name
            ,@netname = upper(data_source)
        from sys.servers 
        where upper(name) = @publisher
        if (@publisherlink is null)
        begin
            raiserror(20620, 16, -1, @publisher)
            return (1)
        end
        --
        -- Adjust publisher name as necessary
        --
        if (@netname != @publisher)
        begin
            select @publisher = @netname
        end
    end
   
    --
    -- Do PAL validation on local or remote publisher db
    -- Build a command string that can be executed on the context of 
    -- the security mode and on a given link if necessary.
    -- This also avoids direct usage of REVERT which 
    -- is not supported on 80 compatible databases
    --
    select @rpcproc = N'declare @cmd nvarchar(4000) ' 
                + N'declare @abc table( rc int ) ' 
                + N'select @cmd = N''declare @retcode int exec @retcode = ' 
                + sys.fn_replreplacesinglequote(quotename(@publisher_db)) 
                + N'.dbo.sp_MSreplcheck_pull @publication = N''''' 
                + replace(@publication, N'''', N'''''''''') 
                + N''''' select @retcode'' ' 
                + N'insert into @abc(rc) ' 
                + N'execute (@cmd) ' 
    --
    -- for security mode 0, execute in proxy login context
    --
    if (@security_mode = 0)
    begin
        select @rpcproc = @rpcproc 
                + N'as login = N'''  
                + sys.fn_replreplacesinglequote(@login) + N''' '
    end
    --
    -- For remote publisher specify the link where the execution needs to happen
    -- This validates the linked entry and ensures
    -- proper processing for resource SPs on publisher
    --
    if (@islocalpub = 0)
    begin
        select @rpcproc = @rpcproc 
                    + N'at ' 
                    + quotename(@publisherlink)
                    + N' select @palrc = rc from @abc '
    end
    --
    -- execute this command under proper user context
    -- and get PAL check return code
    --
    exec @retcode = sp_executesql 
                                     @stmt = @rpcproc
                                    ,@params = N'@palrc int output' 
                                    ,@palrc = @palcheck_retcode output
    if @@error <> 0 or @retcode <> 0 or @palcheck_retcode <> 0
        goto UNDO
  
 
    --
    -- RPC to get commands needed to regenerate subscriber triggers
    --
    create table #tab1 ( cmd nvarchar(4000) )
    select @dbname = db_name()
    
    --
    -- Check to see if initial sync is done, if not skip trigger regeneration
    --
    declare @num_dup_rows int
            ,@agent_id int
    select @agent_id = avg(id), @num_dup_rows = count(*) from MSsubscription_agents where
        UPPER(publisher) = UPPER(@publisher) and
        publisher_db = @publisher_db and
        -- we know that we have independent agents (enforced in
        --  sp_addpublication) so specify the publication name
        publication = @publication and
        -- We know the subscription must be updateble. This
        -- is to reduce the chance of dup rows.
        update_mode <> 0
       
    if @agent_id is not null and @num_dup_rows <= 1
    begin
        create table #ver (version varbinary(16))
        declare @cmd nvarchar(500)
        select @cmd = N'execute (N''select @@microsoftversion'')'
        if (@security_mode = 0)
            select @cmd = @cmd + N'as login = N''' + sys.fn_replreplacesinglequote(@login) + N''' ' 
        if (@islocalpub = 0)    
            select @cmd = @cmd + N' at ' + QUOTENAME(@publisherlink)
       
        insert into #ver exec sp_executesql @stmt=@cmd
        select @pubversion = version from #ver
        drop table #ver
        
        select @regencmd = ''
        
        if (@islocalpub != 0 or @pubversion > 0x09000577)
        begin
            if (@islocalpub = 0)
            begin
                select @regencmd = QUOTENAME(@publisherlink) + N'.'
            end
            
            select @regencmd = @regencmd 
                + QUOTENAME(@publisher_db)
                + N'.dbo.sp_script_synctran_commands N''' 
                + sys.fn_replreplacesinglequote(@publication) 
                + N''', N''all'', 1'
    
            if (@security_mode = 0)
                insert into #tab1 exec (@regencmd) as login = N'repllinkproxy'
            else
                insert into #tab1 exec (@regencmd)   
        end
        else -- not possible to fall through on a local case
        begin
            select @regencmd = QUOTENAME(@publisherlink)
                 + N'.' + QUOTENAME(@publisher_db)
                 + N'.dbo.sp_script_synctran_commands N''' 
                 + sys.fn_replreplacesinglequote(@publication) 
                 + N''', N''all'''
            
            if (@security_mode = 0)
                insert into #tab1 exec (@regencmd) as login = N'repllinkproxy'
            else
                insert into #tab1 exec (@regencmd)        
    
            delete from #tab1 WHERE cmd NOT LIKE N'if (@@microsoftversion >= 0x080002C0) begin exec sp_addsynctriggers%' COLLATE database_default
           
            declare @offset_length int
            select @offset_length = LEN(N'if (@@microsoftversion >= 0x080002C0) begin exec ') + 2
            update #tab1 set cmd = SUBSTRING(cmd, 0, @offset_length) + N'sys.' + SUBSTRING(cmd, @offset_length, LEN(cmd)-@offset_length-3) + N',1 end' 
            -- tack the extra parameter on the end, and add sys. in front of the SP name
        end
    end
    BEGIN TRAN
    --
    -- Now store the linked server information in MSsubscription_properties
    --
    if exists (select * from MSsubscription_properties 
                where upper(publisher) = @publisher
                and publisher_db =  @publisher_db
                and publication = @publication) 
    begin
        update MSsubscription_properties set
            publisher_login = null,
            publisher_password = null,
            publisher_security_mode = @security_mode,
            publisherlink = case when (@security_mode in (0,1)) then N'xxxx' else @publisherlink end,
            publisherlinkuser = case when (@security_mode in (0,1) and @contextuser = N'repllinkproxy') then N'xxxx' else @contextuser end,
            distributor = isnull(@distributor, distributor)
        where upper(publisher) = @publisher
        and publisher_db =  @publisher_db
        and publication = @publication
    end
    else
    begin
        insert into MSsubscription_properties (publisher, publisher_db, publication, publication_type,
            publisher_security_mode, distributor, distributor_security_mode, publisherlink, publisherlinkuser)
        values (@publisher, @publisher_db, @publication, 0, 
            @security_mode, ISNULL(@distributor, @publisher), 1, 
            case when (@security_mode in (0,1)) then N'xxxx' else @publisherlink end, 
            case when (@security_mode in (0,1) and @contextuser = N'repllinkproxy') then N'xxxx' else @contextuser end)
    end
    --
    -- Check for errors in update/insert
    --
    if @@error <> 0
    BEGIN
        rollback tran
        goto UNDO
    END

    --
    -- recreate trigger based on security mode
    -- get the trigger definition
    --

    exec @retcode = xp_execresultset N'select cmd from #tab1', @dbname 
    if (@retcode != 0 or @@error <> 0)
    begin
        rollback tran
        goto UNDO
    end

    drop table #tab1
    
    --
    -- get count of triggers
    --
    select @trigcount = isnull(count(object_name),0)
                from dbo.MSreplication_objects 
                where upper(publisher) = @publisher
                    and publisher_db = @publisher_db
                    and publication = @publication
                    and object_type = 'T' 

    --
    -- certificate signing stage 
    -- proceed only if we have triggers available
    --
    if (@security_mode = 0) and (@trigcount >= 3) and (@trigcount % 3 = 0)
    begin
        --
        -- Create a well known certificate on subdb
        --
        select @certname = N'REPLCERT_' + db_name() + cast(newid() as sysname)
        exec @retcode = sys.sp_MSrepltrigpreparecert @mode = 1
                                    ,@certname = @certname
                                    ,@publisher = @publisher
                                    ,@publisher_db = @publisher_db
                                    ,@publication = @publication
        if @@error != 0 or @retcode != 0
        begin
            rollback tran
            goto UNDO
        end
        select @fprepcertonsub = 1
        --
        -- grant privileges necessary
        --
        if (@islocalpub = 0)
        begin
            select @rpcproc = N'master.sys.sp_MSrepltrigcertgrant'
            exec @retcode = @rpcproc @mode = 1
                                ,@islocalpub = @islocalpub
                                ,@certname = @certname
                                ,@targetdb = N'master'
        end
        else
        begin
            select @rpcproc = quotename(@publisher_db) + N'.sys.sp_MSrepltrigcertgrant'
            exec @retcode = @rpcproc @mode = 1
                                ,@islocalpub = @islocalpub
                                ,@certname = @certname
                                ,@targetdb = @publisher_db
        end
        if @@error != 0 or @retcode != 0
        begin
            rollback tran
            goto UNDO
        end
        select @fgrantcertontarget = 1
    end --  if (@security_mode = 0) and (@trigcount >= 3) and (@trigcount % 3 = 0)

    commit tran
    --
    -- all done
    --
    return 0

UNDO:
    --
    -- clean up certificates if they are created, granted on target
    -- drop the link if it has been created
    -- drop local user if created for local publisher
    --
    if (@fgrantcertontarget = 1)
    begin
        if (@islocalpub = 0)
        begin
            select @rpcproc = N'master.sys.sp_MSrepltrigcertgrant'
            exec @rpcproc @mode = 2
                                ,@islocalpub = @islocalpub
                                ,@certname = @certname
                                ,@targetdb = N'master'
        end
        else
        begin
            select @rpcproc = quotename(@publisher_db) + N'.sys.sp_MSrepltrigcertgrant'
            exec @rpcproc @mode = 2
                                ,@islocalpub = @islocalpub
                                ,@certname = @certname
                                ,@targetdb = @publisher_db
        end
    end
    if (@fprepcertonsub = 1)
    begin
        exec sys.sp_MSrepltrigpreparecert @mode = 2
                                    ,@certname = @certname
                                    ,@publisher = @publisher
                                    ,@publisher_db = @publisher_db
                                    ,@publication = @publication
    end
    if (@fcreateduniquelink = 1)
    begin
        exec @retcode = sys.sp_MSprocesspublisherlink @mode = 2
                        ,@islocalpub = @islocalpub, @securitymode = @security_mode
                        ,@linkname = @publisherlink, @remserver = @publisher
    end
    if (@fcreateduser = 1)
    begin
        exec sys.sp_dropuser @name_in_db = @contextuser
    end
    --
    -- return error
    --
    return 1
end
GO
GRANT EXECUTE ON [sys].[sp_link_publication] TO [public] AS [dbo]
GO
