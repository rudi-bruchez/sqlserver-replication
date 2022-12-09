SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MScheck_subscription_partition]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MScheck_subscription_partition] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MScheck_subscription_partition]
	@pubid [uniqueidentifier],
	@subid [uniqueidentifier],
	@subscriber [sysname],
	@subscriber_db [sysname],
	@valid [bit] OUTPUT,
	@force_delete_other [bit] OUTPUT,
	@subscriber_deleted [sysname] OUTPUT,
	@subscriberdb_deleted [sysname] OUTPUT
WITH EXECUTE AS CALLER
AS
declare @subdb_table sysname
    declare @subserver_table sysname
    declare @subid_table sysname
    declare @retcode int
    declare @partition_id int
    declare @force_delete_other_input bit
    declare @subnickname  varbinary(6)

    select @valid = 0
    select @force_delete_other_input = @force_delete_other
    select @force_delete_other = 0
    
    if @pubid is NULL
    begin
        raiserror (14043, 11, -1, '@pubid', 'sp_MScheck_subscription_partition')
        return (1)
    end
    
    exec @retcode = sys.sp_MSrepl_PAL_rolecheck @pubid = @pubid
    if @@error<>0 or @retcode<>0
        return 1

    -- if the given publication does not contain any subcsription based articles do nothing
    if not exists (select * from dbo.sysmergepartitioninfo where pubid = @pubid and partition_options = 3)
    begin
        select @valid = 1
        return 0
    end

    -- get the partition id for the current subscriber. For security reasons we want to compute the partition id
    -- of the current subscriber instead of getting the partition_id as a parameter.
    exec @retcode = sys.sp_MSget_current_subscriber_partition_id @pubid, @partition_id output
    if @@error<>0 or @retcode<>0 or @partition_id is NULL or @partition_id = -1
        return 0

    select @retcode = 0
    
    begin tran
    
    select @subdb_table = db_name, @subserver_table = subscriber_server 
        from dbo.sysmergesubscriptions with (updlock, holdlock)
        where pubid = @pubid and partition_id = @partition_id
    if @subdb_table is NULL
    begin
        select @valid = 1
        goto DONE
    end

    exec sys.sp_MSget_server_portinfo 
        @name = @subscriber, 
        @srvname = @subscriber OUTPUT

    if (@subdb_table <> @subscriber_db) or (UPPER(@subserver_table) <> UPPER(@subscriber))
        select @valid = 0
    else
        select @valid = 1

    if @valid = 0 and @force_delete_other_input = 1
    begin
        select @subid_table = subid from dbo.sysmergesubscriptions where pubid=@pubid and subscriber_server = @subserver_table and db_name = @subdb_table
        if @subid_table is NULL
            goto ERROR

        delete from dbo.sysmergesubscriptions where pubid=@pubid and subscriber_server = @subserver_table and db_name = @subdb_table
        if @@error<>0
            goto ERROR

        delete from dbo.MSmerge_replinfo where repid=@subid_table
        if @@error<>0
            goto ERROR

        if not exists (select 1 from dbo.sysmergesubscriptions 
                        where pubid=@pubid and UPPER(subscriber_server) collate database_default = UPPER(@subscriber) collate database_default 
                           and db_name = @subscriber_db)
        begin
            select @subnickname = max(replnickname) from dbo.sysmergesubscriptions 
               where UPPER(subscriber_server) collate database_default = UPPER(@subscriber) collate database_default 
                    and db_name = @subscriber_db
                    and status <> 7 -- REPLICA_STATUS_BeforeRestore
                    
            -- Generate a new replica nickname from the @subid 
            if (@subnickname is null)
            begin
                EXECUTE @retcode = sys.sp_MSgenreplnickname 
                                            @srcguid= @subid, 
                                            @replnick= @subnickname output
                if @@ERROR<>0 or @retcode<>0 goto ERROR
            end
            
            insert into dbo.sysmergesubscriptions 
                        (subid, subscriber_server, db_name, pubid, partition_id, replnickname, replicastate, 
                        subscriber_type, subscription_type, priority, sync_type, replica_version, status)
                values (@subid, @subscriber, @subscriber_db, @pubid, @partition_id, @subnickname, newid(), 
                        3, 2, 0, 1, 90, 0  -- this has to be an anonymous subscriber, even if these are wrong sp_MSaddinitialsubscription will later correct it.
                        )
            if @@error<>0
                goto ERROR
            insert into dbo.MSmerge_replinfo(repid, login_name) values (@subid, suser_sname(suser_sid())) 
            if @@error<>0
                goto ERROR
        end
        else
        begin
            update dbo.sysmergesubscriptions set partition_id = @partition_id 
                where pubid=@pubid and UPPER(subscriber_server) = UPPER(@subscriber) and db_name = @subscriber_db
            if @@error<>0
                goto ERROR
        end
        select @force_delete_other = 1, @valid = 1, @subscriber_deleted = @subserver_table, @subscriberdb_deleted = @subdb_table
    end

DONE:
    commit tran
    return 0

ERROR:
    rollback tran
    return 1 
GO
GRANT EXECUTE ON [sys].[sp_MScheck_subscription_partition] TO [public] AS [dbo]
GO
