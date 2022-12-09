SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_replrestart]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_replrestart] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_replrestart]
WITH EXECUTE AS CALLER
AS
SET NOCOUNT ON

    /*
    ** Declarations.
    */
    declare @retcode int
        ,@lsn binary(10)
        ,@dist_lsn binary(10)
        ,@distributor sysname
        ,@distribdb sysname
        ,@distproc nvarchar(4000)
        ,@dbname sysname
        ,@publisher sysname
    /*
    ** Initializations
    */
    select @retcode = 0
    select @dbname = db_name()

    /*
    ** Security
    */
    exec @retcode = sys.sp_MSreplcheck_publish
    if @@ERROR <> 0 or @retcode <> 0
        return(1)

    -- Make sure the database is published.
    IF (SELECT category & 1
          FROM master.dbo.sysdatabases
         WHERE name = @dbname collate database_default) = 0
    BEGIN
        RAISERROR (14013, 16, -1)
        RETURN (1)
    END

    -- Make sure that the log reader is not running
    -- Use 0 so that it will not hold the repl proc structure (the lock).
    exec @retcode = sys.sp_replcmds 0
    if @@ERROR <> 0 or @retcode <> 0
    begin
        RAISERROR (20610, 16, -1, 'sp_replrestart')
        return(1)
    end

    /*
    ** Get distribution server information for remote RPC call.
    */

    EXEC @retcode = sys.sp_MSrepl_getdistributorinfo @rpcsrvname = @distributor OUTPUT,
                                       @distribdb = @distribdb OUTPUT

    IF @@ERROR <> 0 OR  @retcode <> 0
    BEGIN
        RAISERROR (14071, 16, -1)
        RETURN (1)
    END

    -- Get max dist lsn
    SELECT @distproc = QUOTENAME(RTRIM(@distributor)) + '.' + QUOTENAME(@distribdb) + '.dbo.sp_MSget_last_transaction'
    			,@publisher = publishingservername()
    EXECUTE @retcode = @distproc 
        @publisher = @publisher,
        @publisher_db = @dbname,
        @max_xact_seqno = @dist_lsn output
    IF @@ERROR <> 0 or @retcode <> 0
        return 1

    if @dist_lsn is null
        set @dist_lsn = 0x0

    begin tran
	save tran sp_replrestart

    -- To safeguard the case when the logreader is started after the check later
    -- use a tran to prevent the logreader from picking up the new lsns
    while 1 = 1
    begin
        -- Get publisher's lsn
        EXEC @retcode = sys.sp_replincrementlsn_internal @lsn OUTPUT
        IF @@ERROR <> 0 or @retcode <> 0
            goto UNDO

        if @lsn >= @dist_lsn
            break
    end

	--on the other hand, after publisher db is restored, if users retrieves what's been delivered to subscriber already
	--and use it to bring publisher up to more current state, after such *compensation* publisher log may be ahead of @dist_lsn
	--in which case we should manully update MSrepl_transactions table so that it does not scan the compensating portion of log
	if(@lsn > @dist_lsn)
	begin
	    SELECT @distproc = QUOTENAME(RTRIM(@distributor)) + '.' + QUOTENAME(@distribdb) + '.sys.sp_MSreset_transaction'
	    EXECUTE @retcode = @distproc 
	        @publisher = @publisher,
	        @publisher_db = @dbname,
	        @xact_seqno = @lsn
	    IF @@ERROR <> 0 or @retcode <> 0
	        GOTO UNDO

	end

    /* Mark the new starting point of the replication.*/
    exec @retcode = sys.sp_repldone NULL, NULL, 0, 0, 1
    IF @@ERROR <> 0 or @retcode <> 0
        GOTO UNDO

    /* release our hold on the db as logreader */
    EXEC @retcode = sys.sp_replflush
    IF @@ERROR <> 0 or @retcode <> 0
        GOTO UNDO

    commit tran
    return 0

UNDO:
    if @@trancount <> 0
    begin
        rollback tran sp_replrestart
        commit tran
    end
    return 1
GO
GRANT EXECUTE ON [sys].[sp_replrestart] TO [public] AS [dbo]
GO
