SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_restoredbreplication]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_restoredbreplication] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_restoredbreplication]
	@srv_orig [sysname],
	@db_orig [sysname],
	@keep_replication [int],
	@perform_upgrade [bit],
	@recoveryforklsn [varbinary](16)
WITH EXECUTE AS CALLER
AS
/*
 * used by restore process to strip out replication settings if restoring to non-originating
 * server/db or system otherwise not capable of keeping replication working
 * WARNING : procs called here run internal to server and must be owner qualified
*/
begin
	declare @retcode int

	select @retcode = 0

	/*
    ** Security Check: RESTORE statement requires sysadmin, dbcreator, or 
    **                 dbo (THE dbo, not just any member of the db_owner 
    **                 role.)               
    */
    if (ISNULL(IS_SRVROLEMEMBER('sysadmin'),0) = 0) 
       and (ISNULL(IS_SRVROLEMEMBER('dbcreator'),0) = 0)
       and (ISNULL(IS_MEMBER('db_owner'),0) = 0)
    begin
        raiserror(18799, 16, -1) 
        return 1
    end
    
	--
	-- Only attempt to run restore code on REPLICATION scenarios.
	-- this helps us avoid failures when msdb or other dbs are 
	-- offline and a user is attempting to restore a non-repl db
	--
	
	-- 1. Transactional Publisher
	if object_id(N'syspublications', N'U') is not null 
		or object_id(N'syspublications', N'V') is not null 
	-- 2. Merge Publisher
		or object_id(N'sysmergepublications', N'U') is not null
	-- 3. Distributor
		or (object_id(N'MSrepl_commands', N'U') is not null 
    		and object_id(N'MSrepl_transactions', N'U') is not null
    		and object_id(N'MSsnapshot_history', N'U') is not null
    		and object_id(N'MSlogreader_history', N'U') is not null
    		and object_id(N'MSdistribution_history', N'U') is not null
    		and object_id(N'MSmerge_history', N'U') is not null)
    -- 4. Transactional Subscriber 
    	or object_id(N'MSreplication_subscriptions', 'U') is not null
    -- 5. Merge Subscriber 
    	or object_id(N'MSmerge_replinfo', 'U') is not null
    begin
  		exec @retcode = sys.sp_MSrestoredbreplication @srv_orig = @srv_orig, 
													    @db_orig = @db_orig,
													    @keep_replication = @keep_replication,
													    @perform_upgrade = @perform_upgrade,
													    @recoveryforklsn = @recoveryforklsn
   end
   --backup set does not contain replication system tables, but sys.objects or sys.columns are not in clean state
    --due to whatever failure occurred before, let's clean these bits here so not to block user from dropping the object
    --truncating the log, large text or textptr based operation 
    else 
    begin
        --
        -- cleanup the objects that are still marked by replication bits
        --
        -- clear category field if we are not going to keep replication
		declare @db_curr sysname,
                @flush_proc nvarchar(300),
                @done_proc  nvarchar(300) 
		select @db_curr = db_name() 
        
        -- call repldone before removing the published bit
        IF CONVERT(sysname,DATABASEPROPERTYEX(@db_curr,'status'))  = N'READ_WRITE'
			AND HAS_DBACCESS(@db_curr) = 1
			AND DatabasePropertyEx(@db_curr, N'IsPublished') = 1
			--if cdc is still enabled, don't call sp_repldone
			AND not exists(select * from sys.databases where db_id(@db_curr) = database_id and is_cdc_enabled = 1)
        BEGIN
            SELECT @flush_proc = QUOTENAME(@db_curr) + N'.sys.sp_replflush'
            SELECT @done_proc  = QUOTENAME(@db_curr) + N'.sys.sp_repldone'
            EXEC @flush_proc
            EXEC @done_proc NULL, NULL, 0, 0, 1
            EXEC @flush_proc
        END	

        EXEC %%DatabaseEx(Name = @db_curr).SetPublished(Value = 0)
		EXEC %%DatabaseEx(Name = @db_curr).SetMergePublished(Value = 0)
		EXEC %%DatabaseEx(Name = @db_curr).SetDistributor(Value = 0)
		exec @retcode = sys.sp_MScleandbobjectsforreplication
		if @retcode <> 0 or @@error <> 0
            return (1)
    end												    
	return @retcode
end
GO
GRANT EXECUTE ON [sys].[sp_restoredbreplication] TO [public] AS [dbo]
GO
