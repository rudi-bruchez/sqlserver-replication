SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_removesrvreplication]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_removesrvreplication] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_removesrvreplication]
WITH EXECUTE AS CALLER
AS
begin
/* 
 * unmark replication bits for all servers, databases; used by setup in vupgrade 
 * assumes override is on; db in single user mode
 * no need to check rowcounts affected by updates, may not be any repl dbs
 * failure label avoids repetition of errs if not in single user mode
*/

    set nocount on 

    -- setup attach overrides removedb option
    declare @dbname sysname,
            @srvname sysname,
            @procname nvarchar(320),
            @flush_proc nvarchar(300),
            @done_proc nvarchar(300)

    /*
    ** Security Check: require sysadmin
    */
    IF (ISNULL(IS_SRVROLEMEMBER('sysadmin'),0) = 0)
    BEGIN
        RAISERROR(21089,16,-1) 
        RETURN (1)
    END

    declare cur_db CURSOR LOCAL FAST_FORWARD for 
        select name from master.dbo.sysdatabases where name <> N'master' collate database_default
        for read only
    open cur_db
    fetch cur_db into @dbname
    while ( @@fetch_status <> -1 )
    begin
        exec sys.sp_MSremovedbreplication_internal @dbname
        -- clean up system tables
        select @procname = quotename(@dbname) + '.sys.sp_MSdrop_pub_tables'
        exec @procname
        select @procname = quotename(@dbname) + '.sys.sp_MSdrop_mergesystables @whattodrop=3'
        exec @procname
        fetch next from cur_db into @dbname
    end
    close cur_db
    deallocate cur_db

    declare cur_dball CURSOR LOCAL FAST_FORWARD for 
        select name from master.dbo.sysdatabases
        for read only
    open cur_dball
    fetch cur_dball into @dbname
    while ( @@fetch_status <> -1 )
    begin
        -- Consider: Lock database using EXEC %%CurrentDatabase().Lock()??
        -- rmak: Doesn't seem necessary nor is the right thing to do as
        -- %%CurrentDatabase().Lock locks only the current database (master)

        -- call repldone before removing the published bit
        IF CONVERT(sysname,DATABASEPROPERTYEX(@dbname,'status'))  = N'READ_WRITE'
			AND HAS_DBACCESS(@dbname) = 1
			AND DatabasePropertyEx(@dbname, N'IsPublished') = 1
			--if cdc is still enabled, don't call sp_repldone
			AND not exists(select * from sys.databases where db_id(@dbname) = database_id and is_cdc_enabled = 1)
        BEGIN
            SELECT @flush_proc = QUOTENAME(@dbname) + N'.sys.sp_replflush'
            SELECT @done_proc  = QUOTENAME(@dbname) + N'.sys.sp_repldone'
            EXEC @flush_proc
            EXEC @done_proc NULL, NULL, 0, 0, 1
            EXEC @flush_proc
        END	

        -- unmark db bits
        EXEC %%DatabaseEx(Name = @dbname).SetPublished(Value = 0)
        EXEC %%DatabaseEx(Name = @dbname).SetMergePublished(Value = 0)

		--drop sysreplservers
    	if (convert(sysname,DATABASEPROPERTYEX(@dbname,'status'))  = 'ONLINE')
		begin 
	       SELECT @procname = QUOTENAME(@dbname) + '.sys.sp_refreshreplsysservers'
	       EXEC @procname 
		end
        -- clean up old dist db bit
        EXEC %%DatabaseEx(Name = @dbname).SetDistributor(Value = 0)
        fetch next from cur_dball into @dbname
    end
    close cur_dball
    deallocate cur_dball

    -- unmark srv bits (srvstatus = @dsnbit no longer used by replication subscribers but by server )
    -- select name, srvstatus from dbo.sysservers where srvstatus & @srv_distbit = @srv_distbit
    declare cur_srv CURSOR LOCAL FAST_FORWARD for 
        select srvname from master.dbo.sysservers
        for read only
    open cur_srv
    fetch cur_srv into @srvname
    while ( @@fetch_status <> -1 )
    begin
        EXEC %%LinkedServer(Name = @srvname).Lock(Exclusive = 1)
        if @@error = 0
        begin
            EXEC %%LinkedServer(Name = @srvname).SetReplDist(Value = 0)
            EXEC %%LinkedServer(Name = @srvname).SetReplSub(Value = 0)
        end
        fetch next from cur_srv into @srvname
    end
    close cur_srv
    deallocate cur_srv

    return (0)
fail:
-- ad hoc updates not allowed and not single user
return (1)
end
GO
GRANT EXECUTE ON [sys].[sp_removesrvreplication] TO [public] AS [dbo]
GO
