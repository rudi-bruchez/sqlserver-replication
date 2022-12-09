SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_addsynctriggerscore]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_addsynctriggerscore] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_addsynctriggerscore]
	@sub_table [sysname],
	@sub_table_owner [sysname],
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@ins_proc [sysname],
	@upd_proc [sysname],
	@del_proc [sysname],
	@cftproc [sysname],
	@proc_owner [sysname],
	@identity_col [sysname],
	@ts_col [sysname],
	@filter_clause [nvarchar](4000),
	@primary_key_bitmap [varbinary](4000),
	@identity_support [bit],
	@independent_agent [bit],
	@pubversion [int],
	@ins_trig [sysname],
	@upd_trig [sysname],
	@del_trig [sysname],
	@alter [bit],
	@dump_cmds [bit]
WITH EXECUTE AS CALLER
AS
BEGIN
    set nocount on

    declare @dbname                sysname
                ,@retcode                int
                ,@cmd                    nvarchar(max)
                ,@bitmap_str                varchar(8000)
                ,@object_id int
                ,@constraint_name        sysname
                ,@qualname            nvarchar(540)
                ,@quoted_name            nvarchar(540)
                ,@ftscolnull bit
                ,@fidentcolnull bit
                ,@qual_ins_trig            nvarchar(540)
                ,@qual_upd_trig            nvarchar(540)
                ,@qual_del_trig            nvarchar(540)
                ,@fprepcertonsub bit
                ,@fgrantcertontarget bit
                ,@certname sysname
                ,@contextuser sysname
                ,@pubsecuritymode int
                ,@updatemode int
                ,@islocalpub bit
                ,@fupdatetrigmetadata bit

    select     @fidentcolnull = case when (@identity_col in ('null', 'NULL')) then 1 else 0 end
                ,@ftscolnull = case when (@ts_col in ('null', 'NULL')) then 1 else 0 end
                ,@fprepcertonsub = 0
                ,@fgrantcertontarget = 0
                ,@islocalpub = case when (upper(@publisher) = upper(publishingservername())) then 1 else 0 end
                ,@fupdatetrigmetadata = 0

    --  Security Check
    EXEC @retcode = sys.sp_MSreplcheck_subscribe
    IF @@ERROR <> 0 or @retcode <> 0
        RETURN(1)
    --
    -- Initialize
    --
    select @updatemode = update_mode
    from dbo.MSsubscription_agents
    where upper(publisher) = upper(@publisher)
        and publisher_db =  @publisher_db
        and publication = @publication
    --
    -- Check if we need to proceed
    --
    if (@updatemode = 0)
    begin
        --
        -- this subscription is a read only subscription
        --
        return 0
    end
    --
    -- qualify the destination table
    --
    if lower(@sub_table_owner) = N'null'
        select @qualname = QUOTENAME(@sub_table)        
    else
        select @qualname = QUOTENAME(@sub_table_owner) + N'.' + QUOTENAME(@sub_table)

    --
    -- begin transaction for the processing
    --
    BEGIN TRANSACTION
    -- Verify that table exists 
    select @object_id = object_id (@qualname)
    if not (@object_id is null)
    begin
        EXEC %%Object(MultiName = @qualname).LockMatchID(ID = @object_id, Exclusive = 1, BindInternal = 0)
        --EXEC %%Object(MultiName = @qualname).LockExclusiveMatchID(ID = @object_id)
        if @@error <> 0
            select @object_id = null
    end

    if @object_id is null
    begin
        -- Save point not supported in distributed txn, explicitly or escalated
        raiserror(20507, 16, 1, @qualname, 'sp_altersynctriggerscore')
        goto UNDO
    end    
    --
    -- determine if we should pass @cftproc to scripting of synctran trigger
    -- Check if the subscription needs scripting for queued replication. 
    -- For publishers that are pre 80SP3 - cftproc should not be null
    -- that takes care of it. For publisher that 80SP3 or later - we need
    -- to validate the article information
    --
    -- Check the version of the publisher
    --
    if ((@pubversion = 2) and not (@cftproc is null or lower(@cftproc) = 'null'))
    begin
        --
        -- Publisher is 80SP3 or later
        -- @cftproc should exist and article information should exist
        -- for this subscription
        --
        if not exists (select artid 
            from (dbo.MSsubscription_articles as a join dbo.MSsubscription_agents as b
                    on a.agent_id = b.id)
            where upper(b.publisher) = upper(@publisher)
                and b.publisher_db = @publisher_db
                and b.publication = @publication
                and a.dest_table = object_name(@object_id))
        begin
            --
            -- There is no article information
            -- disable queued specific scripting 
            --
            select @cftproc = 'null'
        end
    end    

    if @dump_cmds = 0
    begin
        --
        -- For legacy synctran if timestamp column is being replicated as varbinary
        -- Add default to the column 
        --
        if (@ftscolnull = 0) and OBJECTPROPERTY(@object_id, 'tablehastimestamp') <> 1
        begin
            select @constraint_name = 'MSrepl_synctran_ts_default_' + convert(nvarchar(10), @object_id)
            if not exists (select * from sys.objects where name = @constraint_name)
            begin
                select @quoted_name = quotename(@ts_col)
                exec ('alter table ' + @qualname + 
                        ' add constraint ' + @constraint_name + 
                        ' default 0 for ' + @quoted_name )
                if @@error <> 0
                    goto UNDO
            end
        end
        --
        -- For legacy synctran if identity column is being replicated as base type
        -- Add default to the column 
        --
        if (@fidentcolnull = 0) and OBJECTPROPERTY(@object_id, 'tablehasidentity') <> 1
        begin
            select @constraint_name = 'MSrepl_synctran_identity_default_' + convert(nvarchar(10), @object_id)
            if not exists(select * from sys.objects where name = @constraint_name)
            begin
                select @quoted_name = quotename(@identity_col)
                exec ('alter table ' + @qualname + 
                        ' add constraint ' + @constraint_name + 
                        ' default 0 for ' + @quoted_name )
                if @@error <> 0
                    goto UNDO
            end
       end
    end
    --
    -- Get agent_id
    --

    -- First try to get the agent id initialized by the distribution agent
    declare @agent_id int
                ,@login_time datetime
    select @login_time = login_time from sys.sysprocesses where spid = @@spid

    select @agent_id = id from MSsubscription_agents where
        spid = @@spid and
        login_time = @login_time

    -- If row not found, the current call is not from a distribution agent. Uses
    -- are creating trigger manually using the script generated by
    -- sp_script_synctran_triggers.
    -- Get the row using the publication name. However, it is possible that there are
    -- more than one qualifed rows with different subscription_type, for example
    -- pull and push subscriptions to share agent publications or subscriptions that has
    -- not been cleaned up.
    if @agent_id is null
    begin
        declare @num_dup_rows int
        select @agent_id = avg(id), @num_dup_rows = count(*) from MSsubscription_agents where
            UPPER(publisher) = UPPER(@publisher) and
            publisher_db = @publisher_db and
            publication = case @independent_agent 
                when 0 then N'ALL'
                else @publication
                end and
            -- We know the subscription must be updateble. This
            -- is to reduce the chance of dup rows.
            update_mode <> 0

        if @num_dup_rows > 1
        begin
            -- Raise subscription already exist error
            -- This should rarely happen.
            RAISERROR (14058, 16, -1)
            goto UNDO
        end

        if @agent_id is null
        begin
            raiserror(20588, 16, -1)
            goto UNDO
        end
    end
    --
    --coming from sp_addsynctriggers, these trigger names should be not null
    --use the names directly as triggers have not been created yet
    --otherwise coming from DDL trigger, they should be null, in which case
    --query names from metadata
    --
    if (@ins_trig is null or @del_trig is null or @upd_trig is null)
    begin
        select @ins_trig = sys.fn_synctrigger(@object_id
                                                                ,@publication
                                                                ,N'trg_MSsync_ins_%')
        if @@error <> 0
        goto UNDO

        select @del_trig = sys.fn_synctrigger(@object_id 
                                                                ,@publication
                                                                ,N'trg_MSsync_del_%')
        if @@error <> 0
        goto UNDO

        select @upd_trig = sys.fn_synctrigger(@object_id 
                                                                ,@publication
                                                                ,N'trg_MSsync_upd_%')

        if @@error <> 0
        goto UNDO        
    end
    else
    begin
        --
        -- this call is coming from sp_addsynctriggers
        -- we need to update metadata
        --
        select @fupdatetrigmetadata = 1
    end
    exec @retcode = sys.xp_varbintohexstr @primary_key_bitmap, @bitmap_str output
    if @retcode <> 0 or @@error <> 0
        goto UNDO

    --
    -- Create/ or alter insert trigger
    --
    select @dbname = db_name()
    select @cmd = 'sys.sp_MSscript_sync_ins_trig ' + 
        convert( nvarchar, @object_id )  + ', N' + 
        quotename(@publisher, '''')     + ', N' + 
        quotename(@publisher_db, '''')  + ', N' + 
        quotename(@publication, '''')   + ', N' + 
        quotename(@ins_trig, '''')      + ', N' + 
        quotename(@ins_proc, '''')      + ', N' + 
        quotename(@proc_owner, '''')    + ', N' + 
        quotename(@cftproc, '''')       + ', ' + 
        convert(nvarchar(10), @agent_id) + ', N' + 
        quotename(@identity_col, '''')  + ', N' + 
        quotename(@ts_col, '''')        
    if @filter_clause in ('NULL', 'null')
        select @cmd = @cmd + ', null' 
    else 
        select @cmd = @cmd + ', N''' + replace (@filter_clause,'''','''''')  + ''''
    -- Set primary key bitmap and pubversion
    select @cmd = @cmd + ', ' + @bitmap_str +  ', ' + cast(@pubversion as nvarchar(10))
                    + ', ' + cast(@alter as nvarchar(1))

    exec @retcode = sys.xp_execresultset @cmd, @dbname
    IF @@ERROR <> 0 or @retcode <> 0
        goto UNDO
    --
    -- Create/or alter update trigger
    --
    select @cmd = 'sys.sp_MSscript_sync_upd_trig ' + 
        convert( nvarchar, @object_id )  + ', N' + 
        quotename(@publisher, '''')     + ', N' + 
        quotename(@publisher_db, '''')  + ', N' + 
        quotename(@publication, '''')   + ', N' + 
        quotename(@upd_trig, '''')      + ', N' + 
        quotename(@upd_proc, '''')      + ', N' + 
        quotename(@proc_owner, '''')    + ', N' + 
        quotename(@cftproc, '''')       + ', ' + 
        convert(nvarchar(10), @agent_id) + ', N' + 
        quotename(@identity_col, '''')  + ', N' + 
        quotename(@ts_col, '''')        
    if @filter_clause in ('NULL', 'null')
        select @cmd = @cmd + ', null' 
    else 
        select @cmd = @cmd + ', N''' + replace (@filter_clause,'''','''''')  + ''''
    -- Set primary key bitmap and pubversion
    select @cmd = @cmd + ', ' + @bitmap_str +  ', ' + cast(@pubversion as nvarchar(10))
                + ', ' + cast(@alter as nvarchar(1))

    exec @retcode = sys.xp_execresultset @cmd, @dbname
    IF @@ERROR <> 0 or @retcode <> 0
    goto UNDO
    --
    -- Create/ or alter delete trigger
    --
    select @cmd = 'sys.sp_MSscript_sync_del_trig ' + 
        convert( nvarchar, @object_id )  + ', N' + 
        quotename(@publisher, '''')     + ', N' + 
        quotename(@publisher_db, '''')  + ', N' + 
        quotename(@publication, '''')   + ', N' + 
        quotename(@del_trig, '''')      + ', N' + 
        quotename(@del_proc, '''')      + ', N' + 
        quotename(@proc_owner, '''')    + ', N' + 
        quotename(@cftproc, '''')       + ', ' + 
        convert(nvarchar(10), @agent_id) + ', N' + 
        quotename(@identity_col, '''')  + ', N' + 
        quotename(@ts_col, '''')        
    if @filter_clause in ('NULL', 'null')
        select @cmd = @cmd + ', null' 
    else 
        select @cmd = @cmd + ', N''' + replace (@filter_clause,'''','''''')  + ''''    
    -- Set primary key bitmap and pubversion
    select @cmd = @cmd + ', ' + @bitmap_str +  ', ' + cast(@pubversion as nvarchar(10)) 
            + ', ' + cast(@alter as nvarchar(1))

    exec @retcode = sys.xp_execresultset @cmd, @dbname
    IF @@ERROR <> 0 or @retcode <> 0
        goto UNDO

    --
    -- Set up identity range table
    --
    if @identity_support <> 0 and @dump_cmds = 0 -- for regening triggers only, we don't touch identity ranges
    begin
        if not exists (select * from sys.objects where name = 'MSsub_identity_range')
        begin
            create table dbo.MSsub_identity_range (
            objid int not null,
            range bigint not null,
            last_seed bigint not null,
            threshold int not null)
            IF @@ERROR <> 0
                goto UNDO

            CREATE UNIQUE CLUSTERED INDEX ucMSsub_identity_range ON dbo.MSsub_identity_range (objid)

            exec dbo.sp_MS_marksystemobject 'MSsub_identity_range'
            IF @@ERROR <> 0
                goto UNDO
        end
        if not exists (select * from MSsub_identity_range where objid = @object_id)
        begin
            -- add zero at the beginning.
            insert into MSsub_identity_range (objid, range, last_seed, threshold) values
            (@object_id, 0, 0, 0)
            IF @@ERROR <> 0
                goto UNDO
        end
    end
    --
    -- Get qual names for triggers created
    --
    if lower(@sub_table_owner) = N'null'
    begin
        select @qual_ins_trig = QUOTENAME(@ins_trig)
                ,@qual_upd_trig = QUOTENAME(@upd_trig)
                ,@qual_del_trig = QUOTENAME(@del_trig)
    end
    else
    begin
        select @qual_ins_trig = QUOTENAME(@sub_table_owner) + N'.' + QUOTENAME(@ins_trig)
                ,@qual_upd_trig = QUOTENAME(@sub_table_owner) + N'.' + QUOTENAME(@upd_trig)
                ,@qual_del_trig = QUOTENAME(@sub_table_owner) + N'.' + QUOTENAME(@del_trig)
    end
    --
    -- Set trigger firing order for insert
    --
    exec sys.sp_settriggerorder @triggername = @qual_ins_trig, @order = 'first', @stmttype = 'insert'
    exec sys.sp_settriggerorder @triggername = @qual_upd_trig, @order = 'first', @stmttype = 'update'
    exec sys.sp_settriggerorder @triggername = @qual_del_trig, @order = 'first', @stmttype = 'delete'
    IF @@ERROR <> 0
        goto UNDO
    --
    -- Mark procedures as system procs 
    --
    exec dbo.sp_MS_marksystemobject @qual_ins_trig
    exec dbo.sp_MS_marksystemobject @qual_upd_trig
    exec dbo.sp_MS_marksystemobject @qual_del_trig
    IF @@ERROR <> 0
        goto UNDO
    --
    -- update metadata if needed
    --
    if (@fupdatetrigmetadata = 1)
    begin
        insert into MSreplication_objects(publisher, publisher_db, publication, object_name, object_type)
            values(@publisher, @publisher_db, @publication, @ins_trig, 'T')
        IF @@ERROR <> 0
            goto UNDO
        insert into MSreplication_objects(publisher, publisher_db, publication, object_name, object_type)
            values(@publisher, @publisher_db, @publication, @upd_trig, 'T')
        IF @@ERROR <> 0
            goto UNDO
        insert into MSreplication_objects(publisher, publisher_db, publication, object_name, object_type)
            values(@publisher, @publisher_db, @publication, @del_trig, 'T')
        IF @@ERROR <> 0
            goto UNDO    
    end

    -- if we're regenerating triggers as part of sp_link_publication
    --   we don't yet sign them, instead we wait until all triggers for
    --   all articles are created and sign them all at once
    if @dump_cmds = 1 
    begin
        commit tran
        return (0)
    end

    --
    -- Certify the triggers if needed
    -- if we have immediate updating, publisher link security mode 0, 
    -- then certify
    --
    select @contextuser = case when (publisher_security_mode in (0,1) and publisherlinkuser = N'xxxx') 
                            then N'repllinkproxy' else publisherlinkuser end
            ,@pubsecuritymode = publisher_security_mode
    from MSsubscription_properties 
    where upper(publisher) = upper(@publisher)
        and publisher_db =  @publisher_db
        and publication = @publication
    if (@updatemode in (1,3,5)) and @pubsecuritymode = 0 and @contextuser is not null
    begin
        --
        -- the context user should not be a sysadmin
        --
        if exists (select * from sys.database_principals as dp join master.dbo.syslogins as s on dp.sid = s.sid
                        where dp.name = @contextuser and (ISNULL(IS_SRVROLEMEMBER('sysadmin',s.name),0) != 1))
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
                goto UNDO
            select @fprepcertonsub = 1
            --
            -- grant privileges necessary
            --
            if (@islocalpub = 0)
            begin
                select @cmd = N'master.sys.sp_MSrepltrigcertgrant'
                exec @retcode = @cmd @mode = 1
                                    ,@islocalpub = @islocalpub
                                    ,@certname = @certname
                                    ,@targetdb = N'master'
            end
            else
            begin
                select @cmd = quotename(@publisher_db) + N'.sys.sp_MSrepltrigcertgrant'
                exec @retcode = @cmd @mode = 1
                                    ,@islocalpub = @islocalpub
                                    ,@certname = @certname
                                    ,@targetdb = @publisher_db
            end
            if @@error != 0 or @retcode != 0
                goto UNDO
            select @fgrantcertontarget = 1
        end
    end
    --
    -- commit tran
    --
    commit tran
    --
    -- all done
    --
    return (0)
UNDO:
    if (@fgrantcertontarget = 1)
    begin
        if (@islocalpub = 0)
        begin
            select @cmd = N'master.sys.sp_MSrepltrigcertgrant'
            exec @cmd @mode = 2
                                ,@islocalpub = @islocalpub
                                ,@certname = @certname
                                ,@targetdb = N'master'
        end
        else
        begin
            select @cmd = quotename(@publisher_db) + N'.sys.sp_MSrepltrigcertgrant'
            exec @cmd @mode = 2
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

    rollback tran sp_addsynctriggerscore
    commit tran
    return 1

END
GO
GRANT EXECUTE ON [sys].[sp_addsynctriggerscore] TO [public] AS [dbo]
GO
