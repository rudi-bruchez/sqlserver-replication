SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_addsynctriggers]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_addsynctriggers] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_addsynctriggers]
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
	@distributor [sysname],
	@pubversion [int],
	@dump_cmds [bit]
WITH EXECUTE AS CALLER
AS
BEGIN
    set nocount on

    declare @db                        sysname
                ,@trigname                sysname
                ,@ins_trig                sysname
                ,@upd_trig                sysname
                ,@del_trig                sysname
                ,@dbname                sysname
                ,@ccols                    int
                ,@cnt                    int
                ,@retcode                int
                ,@cmd                    nvarchar(4000)
                ,@merge_pub_object_bit    int
                ,@object_id                int
                ,@constraint_name        sysname
                ,@quoted_name            nvarchar(540)
                ,@qualname                nvarchar(540)
                ,@loctrancount             int
                ,@ftscolnull bit
                ,@fidentcolnull bit
                ,@pubsecuritymode int
                ,@publogin sysname
                ,@pubencpassword nvarchar(524)
                ,@publisherlink sysname
                ,@updatemode int
                ,@old_id int 
                ,@old_name sysname
                ,@parent_obj int

    select     @merge_pub_object_bit     = 128
                ,@fidentcolnull = case when (@identity_col in ('null', 'NULL')) then 1 else 0 end
                ,@ftscolnull = case when (@ts_col in ('null', 'NULL')) then 1 else 0 end
                ,@quoted_name = N'msrepl_tran_version'

    --  Security Check
    EXEC @retcode = sys.sp_MSreplcheck_subscribe
    IF @@ERROR <> 0 or @retcode <> 0
        RETURN(1)
    --
    -- validate @pubversion
    --
    if (@pubversion is null)
        select @pubversion = 1
    if (@pubversion not in (1,2))
        return 1
    
    if @dump_cmds = 1
    begin
        select @qualname = case when (lower(@sub_table_owner) = N'null') 
            then QUOTENAME(@sub_table) 
            else QUOTENAME(@sub_table_owner) + N'.' + QUOTENAME(@sub_table) end
        if object_id(@qualname) is null
            return (0)
    end
    --
    -- Dist Agent executes this sproc with 'implicit transasctions on'.
    -- We take care of our own transactions boundaries to get out of tran 
    --
    set implicit_transactions off
    select @loctrancount = @@trancount
    while @@trancount > 0 commit tran

    -- check valid server and database setting
    -- 1. nested trigger have to be on
    if exists (select * from master.dbo.sysconfigures where config = 115 and value = 0)
    begin
        raiserror(21081, 16, 1)
        return (1)
    end

    -- 2. db option: recursive trigger have to be off
    if DATABASEPROPERTYEX(db_name(), N'IsRecursiveTriggersEnabled') <> 0
    begin
        raiserror(21082, 16, 1)
        return (1)
    end    

    -- 2. db compatibility level have to be 7.0
    if exists (select * from master.dbo.sysdatabases where dbid = db_id() and cmptlevel < 70)
    begin
        raiserror(21083, 16, 1)
        return (1)
    end    
    --
    -- qualify the destination table
    --
    select @qualname = case when (lower(@sub_table_owner) = N'null') 
                                then QUOTENAME(@sub_table) 
                                else QUOTENAME(@sub_table_owner) + N'.' + QUOTENAME(@sub_table) end
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
        ROLLBACK TRANSACTION
        raiserror(20507, 16, 1, @qualname, 'sp_addsynctriggers')
        return (1)
    end    
    -- Add default version guid column
    -- The default constraint is transfered with snapshot already for native publication.
    -- Need to detect to see if default constraint already there.
    if @dump_cmds = 0
    begin
        if not exists (select * 
            from sysconstraints as con join sys.columns as col 
                on con.colid = col.column_id
                    and con.id = col.object_id
                    and OBJECTPROPERTY ( con.constid , 'IsDefaultCnst' ) = 1 -- default
                    and col.object_id = @object_id 
                and col.name = @quoted_name)
        begin 
            select @constraint_name = 'MSrepl_tran_version_default_' + convert(nvarchar(10), @object_id)
            exec ('alter table ' + @qualname + 
                ' add constraint ' + @constraint_name + 
                ' default newid() for ' + @quoted_name )
            if @@error <> 0
            begin
                ROLLBACK TRANSACTION
                return (1)
            end
        end
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
            where UPPER(b.publisher) = UPPER(@publisher)
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
    --
    -- Create the replication metadata tables for updating subscribers
    --
    if @dump_cmds = 0
    begin
        if (LOWER(@cftproc) = 'null')
        begin
            exec @retcode = sys.sp_MScreate_sub_tables_internal
                        @tran_sub_table = 1,
                        @property_table = 1,
                        @sqlqueue_table = 0
        end
        else
        begin
            exec @retcode = sys.sp_MScreate_sub_tables_internal
                        @tran_sub_table = 1,
                        @property_table = 1,
                        @sqlqueue_table = 1
        end
        if @@ERROR <> 0 or @retcode <> 0
        begin
            ROLLBACK TRANSACTION
            return (1)
        end
    end
    --
    -- Processing for Publisher RPC info in MSsubscription properties
    --
    select @publogin = sp.publisher_login 
            ,@pubencpassword = sp.publisher_password
            ,@pubsecuritymode = sp.publisher_security_mode
            ,@publisherlink = sp.publisherlink
            ,@updatemode = sa.update_mode
    from MSsubscription_properties as sp join MSsubscription_agents as sa
        on upper(sp.publisher) = upper(sa.publisher)
            and sp.publisher_db = sa.publisher_db
            and sp.publication = sa.publication
    where upper(sa.publisher) = upper(@publisher)
        and sa.publisher_db =  @publisher_db
        and sa.publication = @publication
    --
    -- Process only for Immediate updating cases
    --
    if (@updatemode in (1,3,5) and @dump_cmds = 0) 
    begin
        --
        -- if there is an old entry - refresh it
        --
        if (@pubsecuritymode is not null)
        begin
            --
            -- we have an entry with publisher link information
            --
            if (@pubsecuritymode in (0,2) and @publisherlink is null)
            begin
                --
                -- Shiloh format -we need to refresh
                -- unencrypt the password
                --
                if (@pubencpassword is not null)
                begin
                    exec @retcode = sys.sp_MSrepldecrypt @pubencpassword output
                    IF @@error <> 0 OR @retcode <> 0
                    begin
                        ROLLBACK TRANSACTION
                        return (1)
                    end
                end
                --
                -- Refresh the link information
                --
                exec @retcode = sys.sp_link_publication
                            @publisher = @publisher,
                            @publisher_db = @publisher_db,
                            @publication = @publication,
                            @security_mode = @pubsecuritymode,
                            @login = @publogin,
                            @password = @pubencpassword,
                            @distributor = @distributor
                if @@ERROR <> 0 or @retcode <> 0
                begin
                    ROLLBACK TRANSACTION
                    return (1)
                end
            end
        end -- @pubsecuritymode is not null
    end -- @updatemode in (1,3,5)
    --
    -- table should not be part of merge replication
    --
    if exists (select * from sys.tables where 
            is_merge_published = 1 and
            object_id = @object_id)
    begin
        ROLLBACK TRANSACTION
        raiserror(21063, 16, 1, @qualname)
        return (1)
    end
    
    --
    -- Drop all replication triggers on the source object
    -- We should drop all because we don't support updatable subscriptions to 
    -- multiple publications on same dest table.
    --
    declare #object_cursor CURSOR LOCAL FAST_FORWARD for 
        select o.object_name, st.object_id 
            from dbo.MSreplication_objects o 
                join sys.triggers st 
                    on o.object_name = st.name
                    and st.parent_id = @object_id 
                    and o.object_type = 'T'

    OPEN #object_cursor
    FETCH #object_cursor INTO @old_name, @old_id
    WHILE (@@fetch_status <> -1)
    BEGIN
        -- Cleanup identity range table
        select @parent_obj = 0
        select @parent_obj = parent_object_id from sys.objects where object_id = @old_id
        -- for @dump_cmds = 0, we're only regening triggers, so we don't clear out the identity range table
        if object_id(N'dbo.MSsub_identity_range') is not null and @dump_cmds = 0 
            delete dbo.MSsub_identity_range where objid = @parent_obj

        -- Drop the trigger
        exec @retcode = sys.sp_MSdrop_object 
            @object_id = @old_id
        if @retcode <> 0 or @@error <> 0
            goto UNDO
        delete from dbo.MSreplication_objects where object_name=@old_name
        FETCH #object_cursor INTO @old_name, @old_id
    END
    CLOSE #object_cursor
    DEALLOCATE #object_cursor

    --
    -- Generate trigger names
    -- sp_addsynctriggerscore depends on these trigger name prefix, both to change both if need to
    --
    select @trigname = RTRIM(SUBSTRING(@sub_table,1,110))
    select @ins_trig = N'trg_MSsync_ins_' + @trigname
            ,@upd_trig = N'trg_MSsync_upd_' + @trigname
            ,@del_trig = N'trg_MSsync_del_' + @trigname
    --
    -- check uniqueness of names and revert to ugly guid-based name if friendly name already exists
    --
    if object_id(@ins_trig, 'TR') is not NULL
        or object_id(@upd_trig, 'TR') is not NULL
        or object_id(@del_trig, 'TR') is not NULL
    begin
        declare @guid_name nvarchar(36)
        select @guid_name =  convert (nvarchar(36), newid())
        select @ins_trig = N'trg_MSsync_ins_' + @guid_name
                ,@upd_trig = N'trg_MSsync_upd_' + @guid_name
                ,@del_trig = N'trg_MSsync_del_' + @guid_name
    end
    -- last cleanup before calling sp_addsynctriggerscore
    -- remove trigger entries from MSreplication_objects that do not exist any more
    delete dbo.MSreplication_objects 
    where (object_name in (@ins_trig,@upd_trig,@del_trig)
            -- this allows us to do a name comparsision without schema qualification
            or object_name not in (select name from sys.triggers)) 
        and object_type = N'T'
    if @@error <> 0
        goto UNDO
    --
    -- call the the core proc to create triggers, this only happens during snapshot
    -- afterwhich DDL will just post the core proc along
    --
    exec @retcode = sys.sp_addsynctriggerscore @sub_table  = @sub_table
                                ,@sub_table_owner = @sub_table_owner
                                ,@publisher = @publisher
                                ,@publisher_db = @publisher_db
                                ,@publication = @publication
                                ,@ins_proc = @ins_proc
                                ,@upd_proc = @upd_proc
                                ,@del_proc = @del_proc
                                ,@cftproc = @cftproc
                                ,@proc_owner = @proc_owner
                                ,@identity_col = @identity_col
                                ,@ts_col = @ts_col
                                ,@filter_clause = @filter_clause
                                ,@primary_key_bitmap = @primary_key_bitmap
                                ,@identity_support = @identity_support
                                ,@independent_agent = @independent_agent
                                ,@pubversion = @pubversion
                                ,@ins_trig = @ins_trig
                                ,@upd_trig = @upd_trig
                                ,@del_trig = @del_trig
                                ,@dump_cmds = @dump_cmds
                                --omit @alter to use the default (0 -- creation mode)
    if @retcode <> 0 or @@error <> 0
        goto UNDO
    --
    -- Mark the table for warnings in BCP
    --
    EXEC %%Relation(ID = @object_id).SetSyncTranSubscribe(Value = 1)
    --
    -- commit tran
    --
    commit tran
    --
    -- Ignore errors.
    --
    exec sys.sp_MSsub_cleanup_orphans
    --
    -- restore the trancount if necessary
    --
    if (@loctrancount > 0)
    begin
        while (@@trancount < @loctrancount)
            begin tran
    end
    --
    -- all done
    --
    return (0)
UNDO:
    if @@trancount <> 0
        rollback tran
    return(1)
END
GO
GRANT EXECUTE ON [sys].[sp_addsynctriggers] TO [public] AS [dbo]
GO
